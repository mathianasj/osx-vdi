#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#pragma mark - Constants

#define kPlugIn_BundleID        "com.osx-vdi.microphone"
#define kDevice_Name            "VDI Microphone"
#define kDevice_UID             "VDIMicrophone_UID"
#define kDevice_ModelUID        "VDIMicrophone_ModelUID"
#define kManufacturer           "OSX VDI"
#define kSampleRate             48000.0
#define kBitsPerChannel         32
#define kBytesPerFrame          4
#define kChannelsPerFrame       1
#define kBufferFrameSize        512
#define kZeroTimeStampPeriod    16384
#define kShmName                "/vdi-shm-vdi-microphone"
#define kShmHeaderSize          64

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
};

#pragma mark - State

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gDeviceIsRunning = 0;
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;

static int gShmFd = -1;
static void *gShmPtr = NULL;
static size_t gShmSize = kShmHeaderSize + (48000 * 2 * 4);
static UInt64 gReadOffset = 0;
static Boolean gReadInitialized = false;

#pragma mark - Shared Memory

static Boolean OpenSharedMemory(void) {
    if (gShmPtr != NULL) return true;
    gShmFd = shm_open(kShmName, O_RDWR, 0);
    if (gShmFd < 0) return false;
    gShmPtr = mmap(NULL, gShmSize, PROT_READ | PROT_WRITE, MAP_SHARED, gShmFd, 0);
    if (gShmPtr == MAP_FAILED) {
        close(gShmFd);
        gShmFd = -1;
        gShmPtr = NULL;
        return false;
    }
    return true;
}

static void CloseSharedMemory(void) {
    if (gShmPtr != NULL) {
        munmap(gShmPtr, gShmSize);
        gShmPtr = NULL;
    }
    if (gShmFd >= 0) {
        close(gShmFd);
        gShmFd = -1;
    }
}

#pragma mark - Driver Interface

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

static ULONG VDIMic_AddRef(void *inDriver) { return 1; }
static ULONG VDIMic_Release(void *inDriver) { return 1; }

static OSStatus VDIMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    gHost = inHost;
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                     const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VDIMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VDIMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                        const AudioServerPlugInClientInfo *inClientInfo) {
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                           const AudioServerPlugInClientInfo *inClientInfo) {
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                         UInt64 inChangeAction, void *inChangeInfo) {
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void *inChangeInfo) {
    return kAudioHardwareNoError;
}

#pragma mark - Property Support

static Boolean VDIMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                   pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioObjectPropertyCustomPropertyInfoList:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                case kAudioPlugInPropertyBoxList:
                case kAudioPlugInPropertyTranslateUIDToBox:
                case kAudioPlugInPropertyClockDeviceList:
                case kAudioPlugInPropertyTranslateUIDToClockDevice:
                    return true;
            }
            break;
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioObjectPropertyCustomPropertyInfoList:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyStreams:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyLatency:
                case kAudioObjectPropertyControlList:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertyBufferFrameSizeRange:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyClockDevice:
                case kAudioDevicePropertyClockAlgorithm:
                case kAudioDevicePropertyClockIsStable:
                    return true;
            }
            break;
        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyCustomPropertyInfoList:
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
            break;
    }
    return false;
}

static OSStatus VDIMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                           pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                           Boolean *outIsSettable) {
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                            pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                            UInt32 inQualifierDataSize, const void *inQualifierData,
                                            UInt32 *outDataSize) {
    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyResourceBundle:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyTranslateUIDToBox:
                case kAudioPlugInPropertyTranslateUIDToClockDevice:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyBoxList:
                case kAudioPlugInPropertyClockDeviceList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
            }
            break;
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyClockDevice:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                    *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeGlobal) ? sizeof(AudioObjectID) : 0;
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyIsHidden:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertyClockAlgorithm:
                case kAudioDevicePropertyClockIsStable:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSizeRange:
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyControlList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
            }
            break;
        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = sizeof(AudioStreamRangedDescription);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
            }
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VDIMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                        pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                        UInt32 inQualifierDataSize, const void *inQualifierData,
                                        UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    *((CFStringRef *)outData) = CFSTR(kManufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    CFStringRef uid = *((CFStringRef *)inQualifierData);
                    if (CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo) {
                        *((AudioObjectID *)outData) = kObjectID_Device;
                    } else {
                        *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    }
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                }
                case kAudioPlugInPropertyTranslateUIDToBox:
                case kAudioPlugInPropertyTranslateUIDToClockDevice:
                    *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyResourceBundle:
                    *((CFStringRef *)outData) = CFSTR("");
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyBoxList:
                case kAudioPlugInPropertyClockDeviceList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
            }
            break;

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                    *((CFStringRef *)outData) = CFSTR(kDevice_Name);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    *((CFStringRef *)outData) = CFSTR(kManufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceUID:
                    *((CFStringRef *)outData) = CFSTR(kDevice_UID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyModelUID:
                    *((CFStringRef *)outData) = CFSTR(kDevice_ModelUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyTransportType:
                    *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockDomain:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockDevice:
                    *((CFStringRef *)outData) = CFSTR("");
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                    if (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                        *((AudioObjectID *)outData) = kObjectID_Stream_Input;
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 0;
                    }
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *((AudioObjectID *)outData) = kObjectID_Stream_Input;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceIsAlive:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyIsHidden:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceIsRunning:
                    *((UInt32 *)outData) = gDeviceIsRunning;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    *((Float64 *)outData) = kSampleRate;
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange *range = (AudioValueRange *)outData;
                    range->mMinimum = kSampleRate;
                    range->mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *((UInt32 *)outData) = kZeroTimeStampPeriod;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockAlgorithm:
                    *((UInt32 *)outData) = kAudioDeviceClockAlgorithmSimpleIIR;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockIsStable:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertySafetyOffset:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyLatency:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSize:
                    *((UInt32 *)outData) = kBufferFrameSize;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSizeRange: {
                    AudioValueRange *range = (AudioValueRange *)outData;
                    range->mMinimum = kBufferFrameSize;
                    range->mMaximum = kBufferFrameSize;
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                }
                case kAudioObjectPropertyControlList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
            }
            break;

        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    *((AudioClassID *)outData) = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyIsActive:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyDirection:
                    *((UInt32 *)outData) = 1; // input
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyTerminalType:
                    *((UInt32 *)outData) = kAudioStreamTerminalTypeMicrophone;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyStartingChannel:
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyLatency:
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    AudioStreamBasicDescription *desc = (AudioStreamBasicDescription *)outData;
                    desc->mSampleRate = kSampleRate;
                    desc->mFormatID = kAudioFormatLinearPCM;
                    desc->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
                    desc->mBytesPerPacket = kBytesPerFrame * kChannelsPerFrame;
                    desc->mFramesPerPacket = 1;
                    desc->mBytesPerFrame = kBytesPerFrame * kChannelsPerFrame;
                    desc->mChannelsPerFrame = kChannelsPerFrame;
                    desc->mBitsPerChannel = kBitsPerChannel;
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return kAudioHardwareNoError;
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    AudioStreamRangedDescription *desc = (AudioStreamRangedDescription *)outData;
                    desc->mFormat.mSampleRate = kSampleRate;
                    desc->mFormat.mFormatID = kAudioFormatLinearPCM;
                    desc->mFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
                    desc->mFormat.mBytesPerPacket = kBytesPerFrame * kChannelsPerFrame;
                    desc->mFormat.mFramesPerPacket = 1;
                    desc->mFormat.mBytesPerFrame = kBytesPerFrame * kChannelsPerFrame;
                    desc->mFormat.mChannelsPerFrame = kChannelsPerFrame;
                    desc->mFormat.mBitsPerChannel = kBitsPerChannel;
                    desc->mSampleRateRange.mMinimum = kSampleRate;
                    desc->mSampleRateRange.mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioStreamRangedDescription);
                    return kAudioHardwareNoError;
                }
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
            }
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VDIMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                        pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                        UInt32 inQualifierDataSize, const void *inQualifierData,
                                        UInt32 inDataSize, const void *inData) {
    return kAudioHardwareNoError;
}

#pragma mark - IO

static void SetIOActiveFlag(UInt32 active) {
    if (gShmPtr != NULL) {
        *(volatile UInt32 *)((char *)gShmPtr + 8) = active;
    }
}

static OSStatus VDIMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    pthread_mutex_lock(&gMutex);
    gDeviceIsRunning = 1;
    OpenSharedMemory();
    SetIOActiveFlag(1);
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    pthread_mutex_lock(&gMutex);
    gDeviceIsRunning = 0;
    SetIOActiveFlag(0);
    CloseSharedMemory();
    gReadOffset = 0;
    gReadInitialized = false;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         UInt32 inClientID,
                                         Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    static UInt64 sampleCount = 0;
    UInt64 hostTime = mach_absolute_time();
    *outSampleTime = (Float64)sampleCount;
    *outHostTime = hostTime;
    *outSeed = 1;
    sampleCount += kZeroTimeStampPeriod;
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID, UInt32 inOperationID,
                                          Boolean *outWillDo, Boolean *outWillDoInPlace) {
    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      AudioObjectID inStreamObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                      void *ioMainBuffer, void *ioSecondaryBuffer) {
    if (inOperationID != kAudioServerPlugInIOOperationReadInput) {
        return kAudioHardwareNoError;
    }

    float *dest = (float *)ioMainBuffer;
    UInt32 framesToFill = inIOBufferFrameSize;
    UInt32 bytesNeeded = framesToFill * kBytesPerFrame * kChannelsPerFrame;

    pthread_mutex_lock(&gMutex);
    if (gShmPtr != NULL) {
        volatile UInt64 *writeOffsetPtr = (volatile UInt64 *)gShmPtr;
        UInt64 writeOffset = *writeOffsetPtr;
        UInt32 ringCapacity = (UInt32)(gShmSize - kShmHeaderSize);
        char *ringData = (char *)gShmPtr + kShmHeaderSize;

        if (!gReadInitialized && writeOffset > 0) {
            gReadOffset = writeOffset;
            gReadInitialized = true;
        }

        if (writeOffset > gReadOffset + ringCapacity) {
            gReadOffset = writeOffset - ringCapacity;
        }

        UInt64 available = writeOffset - gReadOffset;

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
        memset(dest, 0, bytesNeeded);
        OpenSharedMemory();
    }
    pthread_mutex_unlock(&gMutex);

    return kAudioHardwareNoError;
}

static OSStatus VDIMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         UInt32 inClientID, UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return kAudioHardwareNoError;
}

static OSStatus VDIMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID, UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return kAudioHardwareNoError;
}

#pragma mark - Driver Interface Table

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,                                       // _reserved
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
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}
