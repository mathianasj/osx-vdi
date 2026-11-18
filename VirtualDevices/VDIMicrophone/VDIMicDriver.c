/*
 * VDI Microphone — AudioServerPlugIn driver.
 * Two-device architecture: public input-only microphone + hidden output-only writer.
 * Based on CamMicLink's proven pattern for macOS Tahoe HAL compatibility.
 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <syslog.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>

#pragma mark - Constants

#define kPlugIn_BundleID        "com.osx-vdi.microphone"
#define kInputDevice_Name       "VDI Microphone"
#define kWriterDevice_Name      "VDI Microphone Writer"
#define kInputDevice_UID        "VDIMicrophone_UID"
#define kWriterDevice_UID       "VDIMicrophone_Writer_UID"
#define kDevice_ModelUID        "VDIMicrophone_ModelUID"
#define kManufacturer           "OSX VDI"
#define kSampleRate             48000.0
#define kBitsPerChannel         32
#define kBytesPerFrame          4
#define kChannelsPerFrame       1
#define kZeroTimeStampPeriod    512
#define kShmName                "/vdi-shm-vdi-microphone"
#define kShmHeaderSize          64

enum {
    kObjectID_PlugIn         = kAudioObjectPlugInObject,
    kObjectID_InputDevice    = 2,
    kObjectID_InputStream    = 3,
    kObjectID_WriterDevice   = 4,
    kObjectID_WriterStream   = 5,
};

static Boolean isDevice(AudioObjectID id) { return id == kObjectID_InputDevice || id == kObjectID_WriterDevice; }
static Boolean isStream(AudioObjectID id) { return id == kObjectID_InputStream || id == kObjectID_WriterStream; }
static AudioObjectID streamForDevice(AudioObjectID id) { return id == kObjectID_InputDevice ? kObjectID_InputStream : kObjectID_WriterStream; }
static AudioObjectID deviceForStream(AudioObjectID id) { return id == kObjectID_InputStream ? kObjectID_InputDevice : kObjectID_WriterDevice; }

static Boolean populatedScope(AudioObjectID devID, AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal ||
           (devID == kObjectID_InputDevice && scope == kAudioObjectPropertyScopeInput) ||
           (devID == kObjectID_WriterDevice && scope == kAudioObjectPropertyScopeOutput);
}

#pragma mark - State

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gInputDeviceRunning = 0;
static UInt32 gWriterDeviceRunning = 0;
static UInt32 gInputStreamIsActive = 1;
static UInt32 gWriterStreamIsActive = 1;
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;

static int gShmFd = -1;
static void *gShmPtr = NULL;
static size_t gShmSize = kShmHeaderSize + (48000 * 2 * 4);
static UInt64 gReadOffset = 0;
static Boolean gReadInitialized = false;
#define kPreBufferBytes     (UInt64)(48000 * 4 * 50 / 1000)

static UInt64 gAnchorHostTime = 0;
static UInt64 gIOCycleCount = 0;
static UInt64 gClockSeed = 1;
static mach_timebase_info_data_t gTimebaseInfo = {0, 0};
static Float64 gTonePhase = 0.0;
static Boolean gTestToneEnabled = false;

#pragma mark - File Logging

static FILE *gLogFile = NULL;
static pthread_mutex_t gLogMutex = PTHREAD_MUTEX_INITIALIZER;

static void driverLog(const char *fmt, ...) {
    pthread_mutex_lock(&gLogMutex);
    if (gLogFile == NULL) {
        gLogFile = fopen("/tmp/vdi-mic-driver.log", "w");
        if (gLogFile) { fprintf(gLogFile, "=== VDIMicDriver started ===\n"); fflush(gLogFile); }
    }
    if (gLogFile) {
        va_list args;
        va_start(args, fmt);
        vfprintf(gLogFile, fmt, args);
        va_end(args);
        fprintf(gLogFile, "\n");
        fflush(gLogFile);
    }
    pthread_mutex_unlock(&gLogMutex);
}

#pragma mark - Shared Memory

static Boolean OpenSharedMemory(void) {
    if (gShmPtr != NULL) return true;
    gShmFd = shm_open(kShmName, O_RDWR, 0);
    if (gShmFd < 0) {
        driverLog("shm_open FAILED: errno=%d (%s)", errno, strerror(errno));
        return false;
    }
    gShmPtr = mmap(NULL, gShmSize, PROT_READ | PROT_WRITE, MAP_SHARED, gShmFd, 0);
    if (gShmPtr == MAP_FAILED) {
        close(gShmFd); gShmFd = -1; gShmPtr = NULL;
        return false;
    }
    driverLog("shm opened OK: fd=%d ptr=%p size=%zu", gShmFd, gShmPtr, gShmSize);
    return true;
}

static void CloseSharedMemory(void) {
    if (gShmPtr != NULL) { munmap(gShmPtr, gShmSize); gShmPtr = NULL; }
    if (gShmFd >= 0) { close(gShmFd); gShmFd = -1; }
}

#pragma mark - COM Interface

static HRESULT VDIMic_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    CFUUIDRef driverInterfaceID = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
        0xEE, 0xA5, 0x77, 0x3D, 0xCC, 0x43, 0x49, 0xF1,
        0x8E, 0x00, 0x8F, 0x96, 0xE7, 0xD2, 0x3B, 0x17);
    if (CFEqual(interfaceID, driverInterfaceID) || CFEqual(interfaceID, IUnknownUUID)) {
        *outInterface = inDriver;
        CFRelease(interfaceID);
        return kAudioHardwareNoError;
    }
    CFRelease(interfaceID);
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG VDIMic_AddRef(void *d) { return 1; }
static ULONG VDIMic_Release(void *d) { return 1; }

static OSStatus VDIMic_Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef h) {
    gHost = h;
    mach_timebase_info(&gTimebaseInfo);
    gAnchorHostTime = mach_absolute_time();
    driverLog("Initialize: host=%p", (void *)h);
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                                     const AudioServerPlugInClientInfo *client, AudioObjectID *out) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus VDIMic_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VDIMic_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id,
                                        const AudioServerPlugInClientInfo *client) {
    driverLog("AddDeviceClient: device=%u client=%u pid=%d", id, client->mClientID, client->mProcessID);
    return kAudioHardwareNoError;
}
static OSStatus VDIMic_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id,
                                           const AudioServerPlugInClientInfo *client) {
    return kAudioHardwareNoError;
}
static OSStatus VDIMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id,
                                                         UInt64 action, void *info) {
    return kAudioHardwareNoError;
}
static OSStatus VDIMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id,
                                                       UInt64 action, void *info) {
    return kAudioHardwareNoError;
}

#pragma mark - Format Helper

static AudioStreamBasicDescription makeFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame * kChannelsPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame * kChannelsPerFrame;
    f.mChannelsPerFrame = kChannelsPerFrame;
    f.mBitsPerChannel = kBitsPerChannel;
    return f;
}

#pragma mark - Property Support

static Boolean VDIMic_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID id,
                                   pid_t pid, const AudioObjectPropertyAddress *a) {
    AudioObjectPropertyScope scope = a->mScope;
    Boolean global = (scope == kAudioObjectPropertyScopeGlobal);

    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
            return global;
        case kAudioObjectPropertyCustomPropertyInfoList:
            return global;
    }

    if (id == kObjectID_PlugIn && global) {
        switch (a->mSelector) {
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle:
            case kAudioPlugInPropertyBoxList:
            case kAudioPlugInPropertyTranslateUIDToBox:
            case kAudioPlugInPropertyClockDeviceList:
            case kAudioPlugInPropertyTranslateUIDToClockDevice:
                return true;
        }
    }

    if (isDevice(id)) {
        switch (a->mSelector) {
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyClockIsStable:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioObjectPropertyControlList:
                return global;
            case kAudioDevicePropertyStreams:
                return true;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                return global || (isDevice(id) && (scope == kAudioObjectPropertyScopeInput || scope == kAudioObjectPropertyScopeOutput));
        }
    }

    if (isStream(id) && global) {
        switch (a->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
        }
    }

    return false;
}

static OSStatus VDIMic_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id,
                                           pid_t pid, const AudioObjectPropertyAddress *a,
                                           Boolean *out) {
    *out = false;
    if (isDevice(id) && a->mSelector == kAudioDevicePropertyNominalSampleRate)
        *out = true;
    if (isStream(id)) {
        switch (a->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *out = true;
                break;
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id,
                                            pid_t pid, const AudioObjectPropertyAddress *a,
                                            UInt32 qSize, const void *qData, UInt32 *outSize) {
    switch (id) {
        case kObjectID_PlugIn:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyResourceBundle:
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    *outSize = 2 * sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyTranslateUIDToBox:
                case kAudioPlugInPropertyTranslateUIDToClockDevice:
                    *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyBoxList:
                case kAudioPlugInPropertyClockDeviceList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outSize = 0; return noErr;
            }
            break;

        case kObjectID_InputDevice:
        case kObjectID_WriterDevice:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyStreams:
                    *outSize = populatedScope(id, a->mScope) ? sizeof(AudioObjectID) : 0;
                    return noErr;
                case kAudioObjectPropertyOwnedObjects:
                    *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioDevicePropertyRelatedDevices:
                    *outSize = 2 * sizeof(AudioObjectID); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyClockIsStable:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyLatency:
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyNominalSampleRate:
                    *outSize = sizeof(Float64); return noErr;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outSize = sizeof(AudioValueRange); return noErr;
                case kAudioObjectPropertyControlList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outSize = 0; return noErr;
            }
            break;

        case kObjectID_InputStream:
        case kObjectID_WriterStream:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outSize = sizeof(AudioStreamBasicDescription); return noErr;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outSize = sizeof(AudioStreamRangedDescription); return noErr;
                case kAudioObjectPropertyCustomPropertyInfoList:
                case kAudioObjectPropertyName:
                    *outSize = sizeof(CFStringRef); return noErr;
            }
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VDIMic_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id,
                                        pid_t pid, const AudioObjectPropertyAddress *a,
                                        UInt32 qSize, const void *qData,
                                        UInt32 inSize, UInt32 *outSize, void *outData) {
    switch (id) {
        case kObjectID_PlugIn:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioPlugInClassID;
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:
                    *((CFStringRef *)outData) = CFSTR("VDI Microphone Plugin");
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyManufacturer:
                    *((CFStringRef *)outData) = CFSTR(kManufacturer);
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList: {
                    AudioObjectID *ids = (AudioObjectID *)outData;
                    ids[0] = kObjectID_InputDevice;
                    ids[1] = kObjectID_WriterDevice;
                    *outSize = 2 * sizeof(AudioObjectID); return noErr;
                }
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    CFStringRef uid = *((CFStringRef *)qData);
                    if (CFStringCompare(uid, CFSTR(kInputDevice_UID), 0) == kCFCompareEqualTo)
                        *((AudioObjectID *)outData) = kObjectID_InputDevice;
                    else if (CFStringCompare(uid, CFSTR(kWriterDevice_UID), 0) == kCFCompareEqualTo)
                        *((AudioObjectID *)outData) = kObjectID_WriterDevice;
                    else
                        *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    *outSize = sizeof(AudioObjectID); return noErr;
                }
                case kAudioPlugInPropertyTranslateUIDToBox:
                case kAudioPlugInPropertyTranslateUIDToClockDevice:
                    *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyResourceBundle:
                    *((CFStringRef *)outData) = CFSTR("");
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioPlugInPropertyBoxList:
                case kAudioPlugInPropertyClockDeviceList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outSize = 0; return noErr;
            }
            break;

        case kObjectID_InputDevice:
        case kObjectID_WriterDevice:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioDeviceClassID;
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kObjectID_PlugIn;
                    *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:
                    *((CFStringRef *)outData) = (id == kObjectID_InputDevice) ? CFSTR(kInputDevice_Name) : CFSTR(kWriterDevice_Name);
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyManufacturer:
                    *((CFStringRef *)outData) = CFSTR(kManufacturer);
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyDeviceUID:
                    *((CFStringRef *)outData) = (id == kObjectID_InputDevice) ? CFSTR(kInputDevice_UID) : CFSTR(kWriterDevice_UID);
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyModelUID:
                    *((CFStringRef *)outData) = CFSTR(kDevice_ModelUID);
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyTransportType:
                    *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyRelatedDevices: {
                    AudioObjectID *ids = (AudioObjectID *)outData;
                    ids[0] = kObjectID_InputDevice;
                    ids[1] = kObjectID_WriterDevice;
                    *outSize = 2 * sizeof(AudioObjectID); return noErr;
                }
                case kAudioDevicePropertyClockDomain:
                    *((UInt32 *)outData) = 0;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyStreams:
                    if (populatedScope(id, a->mScope)) {
                        *((AudioObjectID *)outData) = streamForDevice(id);
                        *outSize = sizeof(AudioObjectID);
                    } else {
                        *outSize = 0;
                    }
                    return noErr;
                case kAudioObjectPropertyOwnedObjects:
                    *((AudioObjectID *)outData) = streamForDevice(id);
                    *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    *((UInt32 *)outData) = (id == kObjectID_InputDevice && a->mScope == kAudioObjectPropertyScopeInput) ? 1 : 0;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    *((UInt32 *)outData) = 0;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyClockIsStable:
                    *((UInt32 *)outData) = 1;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyIsHidden:
                    *((UInt32 *)outData) = (id == kObjectID_WriterDevice) ? 1 : 0;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsRunning:
                    *((UInt32 *)outData) = (id == kObjectID_InputDevice) ? gInputDeviceRunning : gWriterDeviceRunning;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyNominalSampleRate:
                    *((Float64 *)outData) = kSampleRate;
                    *outSize = sizeof(Float64); return noErr;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange *r = (AudioValueRange *)outData;
                    r->mMinimum = kSampleRate; r->mMaximum = kSampleRate;
                    *outSize = sizeof(AudioValueRange); return noErr;
                }
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *((UInt32 *)outData) = kZeroTimeStampPeriod;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyLatency:
                    *((UInt32 *)outData) = 0;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioObjectPropertyControlList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outSize = 0; return noErr;
            }
            break;

        case kObjectID_InputStream:
        case kObjectID_WriterStream:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioStreamClassID;
                    *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = deviceForStream(id);
                    *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:
                    *((CFStringRef *)outData) = (id == kObjectID_InputStream) ? CFSTR("Microphone Input") : CFSTR("Writer Output");
                    *outSize = sizeof(CFStringRef); return noErr;
                case kAudioStreamPropertyIsActive:
                    *((UInt32 *)outData) = (id == kObjectID_InputStream) ? gInputStreamIsActive : gWriterStreamIsActive;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyDirection:
                    *((UInt32 *)outData) = (id == kObjectID_InputStream) ? 1 : 0;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyTerminalType:
                    *((UInt32 *)outData) = (id == kObjectID_InputStream) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyStartingChannel:
                    *((UInt32 *)outData) = 1;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyLatency:
                    *((UInt32 *)outData) = 0;
                    *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    AudioStreamBasicDescription f = makeFormat();
                    memcpy(outData, &f, sizeof(f));
                    *outSize = sizeof(AudioStreamBasicDescription); return noErr;
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    AudioStreamRangedDescription *rd = (AudioStreamRangedDescription *)outData;
                    rd->mFormat = makeFormat();
                    rd->mSampleRateRange.mMinimum = kSampleRate;
                    rd->mSampleRateRange.mMaximum = kSampleRate;
                    *outSize = sizeof(AudioStreamRangedDescription); return noErr;
                }
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outSize = 0; return noErr;
            }
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VDIMic_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id,
                                        pid_t pid, const AudioObjectPropertyAddress *a,
                                        UInt32 qSize, const void *qData,
                                        UInt32 inSize, const void *inData) {
    if (isStream(id) && a->mSelector == kAudioStreamPropertyIsActive) {
        UInt32 active = *((const UInt32 *)inData);
        if (id == kObjectID_InputStream) {
            gInputStreamIsActive = active;
            driverLog("SetProperty: InputStreamIsActive=%u pid=%d", active, pid);
        } else {
            gWriterStreamIsActive = active;
            driverLog("SetProperty: WriterStreamIsActive=%u pid=%d", active, pid);
        }
    } else if (isStream(id) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        driverLog("SetProperty: StreamFormat (accepted, fixed) obj=%u pid=%d", id, pid);
    } else if (isDevice(id) && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        driverLog("SetProperty: NominalSampleRate (ignored, fixed) pid=%d", pid);
    }
    return kAudioHardwareNoError;
}

#pragma mark - IO

static OSStatus VDIMic_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID) {
    pthread_mutex_lock(&gMutex);
    if (id == kObjectID_InputDevice) {
        gInputDeviceRunning = 1;
        Boolean shmOk = OpenSharedMemory();
        gIOCycleCount = 0;
        gReadOffset = 0;
        gReadInitialized = false;
        if (gShmPtr != NULL) {
            volatile UInt32 *ioActivePtr = (volatile UInt32 *)((char *)gShmPtr + 8);
            *ioActivePtr = 1;
        }
        driverLog("StartIO INPUT: client=%u shm=%s ptr=%p", clientID, shmOk ? "ok" : "FAIL", gShmPtr);
    } else {
        gWriterDeviceRunning = 1;
        driverLog("StartIO WRITER: client=%u", clientID);
    }
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID) {
    pthread_mutex_lock(&gMutex);
    if (id == kObjectID_InputDevice) {
        gInputDeviceRunning = 0;
        if (gShmPtr != NULL) {
            volatile UInt32 *ioActivePtr = (volatile UInt32 *)((char *)gShmPtr + 8);
            *ioActivePtr = 0;
        }
        CloseSharedMemory();
        gReadOffset = 0;
        gReadInitialized = false;
        driverLog("StopIO INPUT: client=%u", clientID);
    } else {
        gWriterDeviceRunning = 0;
        driverLog("StopIO WRITER: client=%u", clientID);
    }
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id,
                                         UInt32 clientID,
                                         Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    UInt32 running = (id == kObjectID_InputDevice) ? gInputDeviceRunning : gWriterDeviceRunning;
    if (!running) return kAudioHardwareNotRunningError;

    Float64 hostTicksPerPeriod = ((Float64)gTimebaseInfo.denom * 1e9 * kZeroTimeStampPeriod) / ((Float64)gTimebaseInfo.numer * kSampleRate);
    UInt64 now = mach_absolute_time();
    UInt64 elapsedTicks = now - gAnchorHostTime;
    UInt64 periodCount = (UInt64)((Float64)elapsedTicks / hostTicksPerPeriod);

    *outSampleTime = (Float64)(periodCount * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)(periodCount * hostTicksPerPeriod);
    *outSeed = gClockSeed;

    static UInt64 sZTSCount = 0;
    sZTSCount++;
    if (sZTSCount <= 5 || sZTSCount % 2000 == 0) {
        driverLog("ZTS: dev=%u #%llu period=%llu sample=%.0f",
                  id, sZTSCount, periodCount, *outSampleTime);
    }
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id,
                                          UInt32 clientID, UInt32 op,
                                          Boolean *outWillDo, Boolean *outWillDoInPlace) {
    *outWillDo = (id == kObjectID_InputDevice && op == kAudioServerPlugInIOOperationReadInput) ||
                 (id == kObjectID_WriterDevice && op == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;
    driverLog("WillDoIO: dev=%u op=%u willDo=%d client=%u", id, op, *outWillDo, clientID);
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id,
                                         UInt32 clientID, UInt32 op,
                                         UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    static UInt64 sCount = 0;
    sCount++;
    if (sCount <= 10 || sCount % 2000 == 0) {
        driverLog("BeginIO: dev=%u #%llu op=%u frames=%u", id, sCount, op, frames);
    }
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id,
                                      AudioObjectID streamID, UInt32 clientID,
                                      UInt32 op, UInt32 frames,
                                      const AudioServerPlugInIOCycleInfo *cycle,
                                      void *ioMainBuffer, void *ioSecondaryBuffer) {
    gIOCycleCount++;

    if (gIOCycleCount <= 20 || gIOCycleCount % 2000 == 0) {
        driverLog("DoIO: dev=%u stream=%u #%llu op=%u frames=%u buf=%p",
                  id, streamID, gIOCycleCount, op, frames, ioMainBuffer);
    }

    if (id == kObjectID_InputDevice && op == kAudioServerPlugInIOOperationReadInput) {
        float *dest = (float *)ioMainBuffer;
        if (gTestToneEnabled) {
            Float64 phaseInc = 440.0 / kSampleRate;
            for (UInt32 i = 0; i < frames; i++) {
                dest[i] = (float)(sin(gTonePhase * 2.0 * 3.14159265358979) * 0.25);
                gTonePhase += phaseInc;
                if (gTonePhase >= 1.0) gTonePhase -= 1.0;
            }
            if (gIOCycleCount <= 20 || gIOCycleCount % 2000 == 0) {
                driverLog("TONE: #%llu dest[0]=%.6f dest[1]=%.6f", gIOCycleCount, dest[0], frames > 1 ? dest[1] : 0.0f);
            }
        } else {
            UInt32 bytesNeeded = frames * kBytesPerFrame * kChannelsPerFrame;
            pthread_mutex_lock(&gMutex);
            if (gShmPtr != NULL) {
                volatile UInt64 *writeOffsetPtr = (volatile UInt64 *)gShmPtr;
                UInt64 writeOffset = *writeOffsetPtr;
                __sync_synchronize();
                UInt32 ringCapacity = (UInt32)(gShmSize - kShmHeaderSize);
                char *ringData = (char *)gShmPtr + kShmHeaderSize;

                if (writeOffset < gReadOffset) { gReadOffset = 0; gReadInitialized = false; }
                if (!gReadInitialized && writeOffset >= kPreBufferBytes) {
                    gReadOffset = writeOffset - kPreBufferBytes;
                    gReadInitialized = true;
                }
                if (writeOffset > gReadOffset + ringCapacity)
                    gReadOffset = writeOffset - ringCapacity / 2;

                UInt64 available = gReadInitialized ? (writeOffset - gReadOffset) : 0;
                if (available >= bytesNeeded) {
                    UInt32 startPos = (UInt32)(gReadOffset % ringCapacity);
                    UInt32 firstChunk = ringCapacity - startPos;
                    if (firstChunk >= bytesNeeded) {
                        memcpy(dest, ringData + startPos, bytesNeeded);
                    } else {
                        memcpy(dest, ringData + startPos, firstChunk);
                        memcpy((char *)dest + firstChunk, ringData, bytesNeeded - firstChunk);
                    }
                    gReadOffset += bytesNeeded;
                } else {
                    memset(dest, 0, bytesNeeded);
                }
            } else {
                memset(dest, 0, frames * kBytesPerFrame * kChannelsPerFrame);
                OpenSharedMemory();
            }
            pthread_mutex_unlock(&gMutex);
        }
        return noErr;
    }

    if (id == kObjectID_WriterDevice && op == kAudioServerPlugInIOOperationWriteMix) {
        return noErr;
    }

    return kAudioHardwareNoError;
}

static OSStatus VDIMic_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id,
                                       UInt32 clientID, UInt32 op,
                                       UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    return kAudioHardwareNoError;
}

#pragma mark - Driver Interface Table

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    VDIMic_QueryInterface,
    VDIMic_AddRef,
    VDIMic_Release,
    VDIMic_Initialize,
    VDIMic_CreateDevice,
    VDIMic_DestroyDevice,
    VDIMic_AddDeviceClient,
    VDIMic_RemoveDeviceClient,
    VDIMic_PerformDeviceConfigurationChange,
    VDIMic_AbortDeviceConfigurationChange,
    VDIMic_HasProperty,
    VDIMic_IsPropertySettable,
    VDIMic_GetPropertyDataSize,
    VDIMic_GetPropertyData,
    VDIMic_SetPropertyData,
    VDIMic_StartIO,
    VDIMic_StopIO,
    VDIMic_GetZeroTimeStamp,
    VDIMic_WillDoIOOperation,
    VDIMic_BeginIOOperation,
    VDIMic_DoIOOperation,
    VDIMic_EndIOOperation,
};

static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;

void *VDIMicDriverFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    driverLog("Factory called");
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        driverLog("Factory: returning driver ref");
        return gDriverRef;
    }
    driverLog("Factory: type mismatch, returning NULL");
    return NULL;
}
