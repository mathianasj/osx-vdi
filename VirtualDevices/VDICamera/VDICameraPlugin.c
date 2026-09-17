#include <CoreMediaIO/CMIOHardwarePlugIn.h>
#include <CoreMedia/CMSimpleQueue.h>
#include <CoreMedia/CMSampleBuffer.h>
#include <CoreMedia/CMFormatDescription.h>
#include <CoreMedia/CMTime.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/audio/IOAudioTypes.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <os/log.h>

#pragma mark - Constants

#define kPlugIn_BundleID    "com.osx-vdi.camera"
#define kDevice_Name        "VDI Camera"
#define kDevice_UID         "VDICamera_UID"
#define kDevice_ModelUID    "VDICamera_ModelUID"
#define kManufacturer       "OSX VDI"
#define kFrameRate          30
#define kWidth              1280
#define kHeight             720
#define kShmPath            "/tmp/vdi-shm-vdi-camera"
#define kShmHeaderSize      64
#define kQueueSize          8

#pragma mark - Object IDs

static CMIOObjectID gPlugInObjectID = 0;
static CMIOObjectID gDeviceObjectID = 0;
static CMIOObjectID gStreamObjectID = 0;

static CMIOHardwarePlugInRef gSelfRef = NULL;

#pragma mark - State

static Boolean gIsRunning = false;
static dispatch_source_t gTimer = NULL;
static dispatch_queue_t gTimerQueue = NULL;
static CMSimpleQueueRef gQueue = NULL;
static CMIODeviceStreamQueueAlteredProc gQueueAlteredProc = NULL;
static void *gQueueAlteredRefCon = NULL;
static CMFormatDescriptionRef gFormatDesc = NULL;
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt64 gFrameCount = 0;

#pragma mark - Shared Memory

static int gShmFd = -1;
static void *gShmPtr = NULL;
static size_t gShmSize = kShmHeaderSize + (1920 * 1080 * 4);
static UInt64 gLastSequence = 0;

static Boolean OpenSharedMemory(void) {
    if (gShmPtr != NULL) return true;
    gShmFd = open(kShmPath, O_RDONLY);
    if (gShmFd < 0) return false;
    gShmPtr = mmap(NULL, gShmSize, PROT_READ, MAP_SHARED, gShmFd, 0);
    if (gShmPtr == MAP_FAILED) {
        close(gShmFd);
        gShmFd = -1;
        gShmPtr = NULL;
        return false;
    }
    return true;
}

static void CloseSharedMemory(void) {
    if (gShmPtr != NULL) { munmap(gShmPtr, gShmSize); gShmPtr = NULL; }
    if (gShmFd >= 0) { close(gShmFd); gShmFd = -1; }
}

#pragma mark - Mach Time Helpers

static Float64 gHostClockFreq = 0;

static void InitHostClock(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    gHostClockFreq = (Float64)info.numer / (Float64)info.denom;
}

static UInt64 HostTimeToNanos(UInt64 hostTime) {
    return (UInt64)((Float64)hostTime * gHostClockFreq);
}

#pragma mark - Frame Generation

static void CreateBlankPixelBuffer(CVPixelBufferRef *outPB) {
    CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                        kCVPixelFormatType_32BGRA, NULL, outPB);
    if (*outPB) {
        CVPixelBufferLockBaseAddress(*outPB, 0);
        void *base = CVPixelBufferGetBaseAddress(*outPB);
        memset(base, 0, CVPixelBufferGetBytesPerRow(*outPB) * kHeight);
        CVPixelBufferUnlockBaseAddress(*outPB, 0);
    }
}

static void CreateSampleBuffer(CVPixelBufferRef pb, CMSampleBufferRef *outSB) {
    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt);
    if (!fmt) return;

    UInt64 hostTime = mach_absolute_time();
    CMTime pts = CMTimeMake(HostTimeToNanos(hostTime), 1000000000);
    CMTime dur = CMTimeMake(1, kFrameRate);
    CMSampleTimingInfo timing = { dur, pts, kCMTimeInvalid };

    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true,
                                       NULL, NULL, fmt, &timing, outSB);
    CFRelease(fmt);
}

static void EmitFrame(void) {
    if (!gQueue) return;

    CVPixelBufferRef pb = NULL;
    Boolean gotFrame = false;

    pthread_mutex_lock(&gMutex);
    if (gShmPtr != NULL) {
        UInt64 seq = *(UInt64 *)gShmPtr;
        if (seq != gLastSequence && seq > 0) {
            gLastSequence = seq;
            UInt32 width = *(UInt32 *)((char *)gShmPtr + 8);
            UInt32 height = *(UInt32 *)((char *)gShmPtr + 12);
            UInt32 bytesPerRow = *(UInt32 *)((char *)gShmPtr + 16);
            UInt32 dataSize = *(UInt32 *)((char *)gShmPtr + 24);

            if (dataSize > 0 && width > 0 && height > 0) {
                CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_32BGRA, NULL, &pb);
                if (pb) {
                    CVPixelBufferLockBaseAddress(pb, 0);
                    void *dest = CVPixelBufferGetBaseAddress(pb);
                    size_t destBPR = CVPixelBufferGetBytesPerRow(pb);
                    char *src = (char *)gShmPtr + kShmHeaderSize;
                    UInt32 h = height;
                    for (UInt32 row = 0; row < h; row++) {
                        memcpy((char *)dest + row * destBPR,
                               src + row * bytesPerRow,
                               (destBPR < bytesPerRow) ? destBPR : bytesPerRow);
                    }
                    CVPixelBufferUnlockBaseAddress(pb, 0);
                    gotFrame = true;
                }
            }
        }
    } else {
        OpenSharedMemory();
    }
    pthread_mutex_unlock(&gMutex);

    if (!gotFrame) {
        CreateBlankPixelBuffer(&pb);
    }

    if (pb) {
        CMSampleBufferRef sb = NULL;
        CreateSampleBuffer(pb, &sb);
        CVPixelBufferRelease(pb);

        if (sb) {
            if (CMSimpleQueueGetCount(gQueue) < CMSimpleQueueGetCapacity(gQueue)) {
                CMSimpleQueueEnqueue(gQueue, sb);
                if (gQueueAlteredProc) {
                    gQueueAlteredProc(gStreamObjectID, sb, gQueueAlteredRefCon);
                }
            } else {
                CFRelease(sb);
            }
        }
    }

    gFrameCount++;
}

#pragma mark - IUnknown

static HRESULT VDICam_QueryInterface(void *self, REFIID uuid, LPVOID *interface) {
    CFUUIDRef requestedID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, uuid);
    CFUUIDRef pluginInterfaceID = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
        0xB8, 0x9D, 0xFA, 0xBA, 0x93, 0xBF, 0x11, 0xD8,
        0x8E, 0xA6, 0x00, 0x0A, 0x95, 0xAF, 0x9C, 0x6A);

    if (CFEqual(requestedID, pluginInterfaceID) || CFEqual(requestedID, IUnknownUUID)) {
        *interface = self;
        CFRelease(requestedID);
        return S_OK;
    }
    CFRelease(requestedID);
    *interface = NULL;
    return E_NOINTERFACE;
}

static ULONG VDICam_AddRef(void *self) { return 1; }
static ULONG VDICam_Release(void *self) { return 1; }

#pragma mark - Initialization

static OSStatus VDICam_Initialize(CMIOHardwarePlugInRef self) {
    return kCMIOHardwareNoError;
}

static OSStatus VDICam_InitializeWithObjectID(CMIOHardwarePlugInRef self, CMIOObjectID objectID) {
    gSelfRef = self;
    gPlugInObjectID = objectID;
    InitHostClock();

    CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                   kCVPixelFormatType_32BGRA,
                                   kWidth, kHeight, NULL, &gFormatDesc);

    OSStatus err;
    err = CMIOObjectCreate(self, kCMIOObjectSystemObject, kCMIODeviceClassID, &gDeviceObjectID);
    if (err != kCMIOHardwareNoError) return err;

    err = CMIOObjectCreate(self, gDeviceObjectID, kCMIOStreamClassID, &gStreamObjectID);
    if (err != kCMIOHardwareNoError) return err;

    CMIOObjectID devArr[] = { gDeviceObjectID };
    CMIOObjectsPublishedAndDied(self, kCMIOObjectSystemObject, 1, devArr, 0, NULL);

    CMIOObjectID strArr[] = { gStreamObjectID };
    CMIOObjectsPublishedAndDied(self, gDeviceObjectID, 1, strArr, 0, NULL);

    os_log(OS_LOG_DEFAULT, "[VDICamera] Plugin initialized, device=%u stream=%u",
           gDeviceObjectID, gStreamObjectID);
    return kCMIOHardwareNoError;
}

static OSStatus VDICam_Teardown(CMIOHardwarePlugInRef self) {
    if (gIsRunning) {
        if (gTimer) { dispatch_source_cancel(gTimer); gTimer = NULL; }
        CloseSharedMemory();
        gIsRunning = false;
    }

    if (gStreamObjectID) {
        CMIOObjectID strArr[] = { gStreamObjectID };
        CMIOObjectsPublishedAndDied(self, gDeviceObjectID, 0, NULL, 1, strArr);
    }
    if (gDeviceObjectID) {
        CMIOObjectID devArr[] = { gDeviceObjectID };
        CMIOObjectsPublishedAndDied(self, kCMIOObjectSystemObject, 0, NULL, 1, devArr);
    }

    if (gQueue) { CFRelease(gQueue); gQueue = NULL; }
    if (gFormatDesc) { CFRelease(gFormatDesc); gFormatDesc = NULL; }

    return kCMIOHardwareNoError;
}

#pragma mark - Object Properties

static void VDICam_ObjectShow(CMIOHardwarePlugInRef self, CMIOObjectID objectID) {
}

static Boolean VDICam_ObjectHasProperty(CMIOHardwarePlugInRef self, CMIOObjectID objectID,
                                         const CMIOObjectPropertyAddress *address) {
    if (objectID == gPlugInObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
            case kCMIOObjectPropertyOwner:
            case kCMIOObjectPropertyName:
            case kCMIOObjectPropertyManufacturer:
            case kCMIOObjectPropertyOwnedObjects:
                return true;
        }
    } else if (objectID == gDeviceObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
            case kCMIOObjectPropertyOwner:
            case kCMIOObjectPropertyName:
            case kCMIOObjectPropertyManufacturer:
            case kCMIOObjectPropertyOwnedObjects:
            case kCMIODevicePropertyPlugIn:
            case kCMIODevicePropertyDeviceUID:
            case kCMIODevicePropertyModelUID:
            case kCMIODevicePropertyTransportType:
            case kCMIODevicePropertyDeviceIsAlive:
            case kCMIODevicePropertyDeviceIsRunning:
            case kCMIODevicePropertyDeviceIsRunningSomewhere:
            case kCMIODevicePropertyDeviceCanBeDefaultDevice:
            case kCMIODevicePropertyLatency:
            case kCMIODevicePropertyStreams:
            case kCMIODevicePropertyStreamConfiguration:
            case kCMIODevicePropertyHogMode:
            case kCMIODevicePropertyExcludeNonDALAccess:
            case kCMIODevicePropertyCanProcessAVCCommand:
            case kCMIODevicePropertyCanProcessRS422Command:
                return true;
        }
    } else if (objectID == gStreamObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
            case kCMIOObjectPropertyOwner:
            case kCMIOObjectPropertyName:
            case kCMIOStreamPropertyDirection:
            case kCMIOStreamPropertyTerminalType:
            case kCMIOStreamPropertyStartingChannel:
            case kCMIOStreamPropertyLatency:
            case kCMIOStreamPropertyFormatDescription:
            case kCMIOStreamPropertyFormatDescriptions:
            case kCMIOStreamPropertyFrameRate:
            case kCMIOStreamPropertyFrameRates:
            case kCMIOStreamPropertyMinimumFrameRate:
            case kCMIOStreamPropertyNoDataTimeoutInMSec:
            case kCMIOStreamPropertyNoDataEventCount:
                return true;
        }
    }
    return false;
}

static OSStatus VDICam_ObjectIsPropertySettable(CMIOHardwarePlugInRef self, CMIOObjectID objectID,
                                                 const CMIOObjectPropertyAddress *address,
                                                 Boolean *isSettable) {
    *isSettable = false;
    return kCMIOHardwareNoError;
}

static OSStatus VDICam_ObjectGetPropertyDataSize(CMIOHardwarePlugInRef self, CMIOObjectID objectID,
                                                  const CMIOObjectPropertyAddress *address,
                                                  UInt32 qualifierDataSize, const void *qualifierData,
                                                  UInt32 *dataSize) {
    if (objectID == gPlugInObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
                *dataSize = sizeof(CMIOClassID); return kCMIOHardwareNoError;
            case kCMIOObjectPropertyOwner:
                *dataSize = sizeof(CMIOObjectID); return kCMIOHardwareNoError;
            case kCMIOObjectPropertyName:
            case kCMIOObjectPropertyManufacturer:
                *dataSize = sizeof(CFStringRef); return kCMIOHardwareNoError;
            case kCMIOObjectPropertyOwnedObjects:
                *dataSize = sizeof(CMIOObjectID); return kCMIOHardwareNoError;
        }
    } else if (objectID == gDeviceObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
            case kCMIODevicePropertyTransportType:
                *dataSize = sizeof(CMIOClassID); return kCMIOHardwareNoError;
            case kCMIOObjectPropertyOwner:
            case kCMIODevicePropertyPlugIn:
                *dataSize = sizeof(CMIOObjectID); return kCMIOHardwareNoError;
            case kCMIOObjectPropertyName:
            case kCMIOObjectPropertyManufacturer:
            case kCMIODevicePropertyDeviceUID:
            case kCMIODevicePropertyModelUID:
                *dataSize = sizeof(CFStringRef); return kCMIOHardwareNoError;
            case kCMIODevicePropertyDeviceIsAlive:
            case kCMIODevicePropertyDeviceIsRunning:
            case kCMIODevicePropertyDeviceIsRunningSomewhere:
            case kCMIODevicePropertyDeviceCanBeDefaultDevice:
            case kCMIODevicePropertyLatency:
            case kCMIODevicePropertyHogMode:
            case kCMIODevicePropertyExcludeNonDALAccess:
            case kCMIODevicePropertyCanProcessAVCCommand:
            case kCMIODevicePropertyCanProcessRS422Command:
                *dataSize = sizeof(UInt32); return kCMIOHardwareNoError;
            case kCMIODevicePropertyStreams:
                *dataSize = sizeof(CMIOStreamID); return kCMIOHardwareNoError;
            case kCMIODevicePropertyStreamConfiguration:
                *dataSize = sizeof(UInt32) * 2; return kCMIOHardwareNoError;
        }
    } else if (objectID == gStreamObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
                *dataSize = sizeof(CMIOClassID); return kCMIOHardwareNoError;
            case kCMIOObjectPropertyOwner:
                *dataSize = sizeof(CMIOObjectID); return kCMIOHardwareNoError;
            case kCMIOObjectPropertyName:
                *dataSize = sizeof(CFStringRef); return kCMIOHardwareNoError;
            case kCMIOStreamPropertyDirection:
            case kCMIOStreamPropertyTerminalType:
            case kCMIOStreamPropertyStartingChannel:
            case kCMIOStreamPropertyLatency:
            case kCMIOStreamPropertyNoDataTimeoutInMSec:
            case kCMIOStreamPropertyNoDataEventCount:
                *dataSize = sizeof(UInt32); return kCMIOHardwareNoError;
            case kCMIOStreamPropertyFormatDescription:
                *dataSize = sizeof(CMFormatDescriptionRef); return kCMIOHardwareNoError;
            case kCMIOStreamPropertyFormatDescriptions:
                *dataSize = sizeof(CFArrayRef); return kCMIOHardwareNoError;
            case kCMIOStreamPropertyFrameRate:
            case kCMIOStreamPropertyMinimumFrameRate:
                *dataSize = sizeof(Float64); return kCMIOHardwareNoError;
            case kCMIOStreamPropertyFrameRates:
                *dataSize = sizeof(CFArrayRef); return kCMIOHardwareNoError;
        }
    }
    return kCMIOHardwareUnknownPropertyError;
}

static OSStatus VDICam_ObjectGetPropertyData(CMIOHardwarePlugInRef self, CMIOObjectID objectID,
                                              const CMIOObjectPropertyAddress *address,
                                              UInt32 qualifierDataSize, const void *qualifierData,
                                              UInt32 dataSize, UInt32 *dataUsed, void *data) {
    if (objectID == gPlugInObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
                *(CMIOClassID *)data = kCMIOPlugInClassID;
                *dataUsed = sizeof(CMIOClassID);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyOwner:
                *(CMIOObjectID *)data = kCMIOObjectSystemObject;
                *dataUsed = sizeof(CMIOObjectID);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyName:
                *(CFStringRef *)data = CFSTR(kDevice_Name);
                *dataUsed = sizeof(CFStringRef);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyManufacturer:
                *(CFStringRef *)data = CFSTR(kManufacturer);
                *dataUsed = sizeof(CFStringRef);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyOwnedObjects:
                *(CMIOObjectID *)data = gDeviceObjectID;
                *dataUsed = sizeof(CMIOObjectID);
                return kCMIOHardwareNoError;
        }
    } else if (objectID == gDeviceObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
                *(CMIOClassID *)data = kCMIODeviceClassID;
                *dataUsed = sizeof(CMIOClassID);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyOwner:
                *(CMIOObjectID *)data = gPlugInObjectID;
                *dataUsed = sizeof(CMIOObjectID);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyName:
                *(CFStringRef *)data = CFSTR(kDevice_Name);
                *dataUsed = sizeof(CFStringRef);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyManufacturer:
                *(CFStringRef *)data = CFSTR(kManufacturer);
                *dataUsed = sizeof(CFStringRef);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyPlugIn:
                *(CMIOObjectID *)data = gPlugInObjectID;
                *dataUsed = sizeof(CMIOObjectID);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyDeviceUID:
                *(CFStringRef *)data = CFSTR(kDevice_UID);
                *dataUsed = sizeof(CFStringRef);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyModelUID:
                *(CFStringRef *)data = CFSTR(kDevice_ModelUID);
                *dataUsed = sizeof(CFStringRef);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyTransportType:
                *(UInt32 *)data = kIOAudioDeviceTransportTypeVirtual;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyDeviceIsAlive:
                *(UInt32 *)data = 1;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyDeviceIsRunning:
            case kCMIODevicePropertyDeviceIsRunningSomewhere:
                *(UInt32 *)data = gIsRunning ? 1 : 0;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyDeviceCanBeDefaultDevice:
                *(UInt32 *)data = 1;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyLatency:
                *(UInt32 *)data = 0;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyHogMode:
                *(pid_t *)data = -1;
                *dataUsed = sizeof(pid_t);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyExcludeNonDALAccess:
                *(UInt32 *)data = 0;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyCanProcessAVCCommand:
            case kCMIODevicePropertyCanProcessRS422Command:
                *(UInt32 *)data = 0;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyStreams:
                *(CMIOStreamID *)data = gStreamObjectID;
                *dataUsed = sizeof(CMIOStreamID);
                return kCMIOHardwareNoError;
            case kCMIODevicePropertyStreamConfiguration: {
                UInt32 *config = (UInt32 *)data;
                config[0] = 1; // number of streams
                config[1] = 1; // channels per stream
                *dataUsed = sizeof(UInt32) * 2;
                return kCMIOHardwareNoError;
            }
        }
    } else if (objectID == gStreamObjectID) {
        switch (address->mSelector) {
            case kCMIOObjectPropertyClass:
                *(CMIOClassID *)data = kCMIOStreamClassID;
                *dataUsed = sizeof(CMIOClassID);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyOwner:
                *(CMIOObjectID *)data = gDeviceObjectID;
                *dataUsed = sizeof(CMIOObjectID);
                return kCMIOHardwareNoError;
            case kCMIOObjectPropertyName:
                *(CFStringRef *)data = CFSTR(kDevice_Name);
                *dataUsed = sizeof(CFStringRef);
                return kCMIOHardwareNoError;
            case kCMIOStreamPropertyDirection:
                *(UInt32 *)data = 1; // source (input)
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIOStreamPropertyTerminalType:
                *(UInt32 *)data = 'camr';
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIOStreamPropertyStartingChannel:
                *(UInt32 *)data = 1;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIOStreamPropertyLatency:
                *(UInt32 *)data = 0;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIOStreamPropertyFormatDescription:
                *(CMFormatDescriptionRef *)data = gFormatDesc;
                CFRetain(gFormatDesc);
                *dataUsed = sizeof(CMFormatDescriptionRef);
                return kCMIOHardwareNoError;
            case kCMIOStreamPropertyFormatDescriptions: {
                CFArrayRef arr = CFArrayCreate(kCFAllocatorDefault,
                    (const void **)&gFormatDesc, 1, &kCFTypeArrayCallBacks);
                *(CFArrayRef *)data = arr;
                *dataUsed = sizeof(CFArrayRef);
                return kCMIOHardwareNoError;
            }
            case kCMIOStreamPropertyFrameRate:
            case kCMIOStreamPropertyMinimumFrameRate:
                *(Float64 *)data = (Float64)kFrameRate;
                *dataUsed = sizeof(Float64);
                return kCMIOHardwareNoError;
            case kCMIOStreamPropertyFrameRates: {
                Float64 rate = (Float64)kFrameRate;
                CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &rate);
                CFArrayRef arr = CFArrayCreate(kCFAllocatorDefault,
                    (const void **)&num, 1, &kCFTypeArrayCallBacks);
                CFRelease(num);
                *(CFArrayRef *)data = arr;
                *dataUsed = sizeof(CFArrayRef);
                return kCMIOHardwareNoError;
            }
            case kCMIOStreamPropertyNoDataTimeoutInMSec:
                *(UInt32 *)data = 3000;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
            case kCMIOStreamPropertyNoDataEventCount:
                *(UInt32 *)data = 0;
                *dataUsed = sizeof(UInt32);
                return kCMIOHardwareNoError;
        }
    }
    return kCMIOHardwareUnknownPropertyError;
}

static OSStatus VDICam_ObjectSetPropertyData(CMIOHardwarePlugInRef self, CMIOObjectID objectID,
                                              const CMIOObjectPropertyAddress *address,
                                              UInt32 qualifierDataSize, const void *qualifierData,
                                              UInt32 dataSize, const void *data) {
    return kCMIOHardwareNoError;
}

#pragma mark - Device Operations

static OSStatus VDICam_DeviceSuspend(CMIOHardwarePlugInRef self, CMIODeviceID device) {
    return kCMIOHardwareNoError;
}

static OSStatus VDICam_DeviceResume(CMIOHardwarePlugInRef self, CMIODeviceID device) {
    return kCMIOHardwareNoError;
}

static OSStatus VDICam_DeviceStartStream(CMIOHardwarePlugInRef self, CMIODeviceID device,
                                          CMIOStreamID stream) {
    if (gIsRunning) return kCMIOHardwareNoError;

    pthread_mutex_lock(&gMutex);
    OpenSharedMemory();
    gIsRunning = true;
    gFrameCount = 0;
    pthread_mutex_unlock(&gMutex);

    if (!gTimerQueue) {
        gTimerQueue = dispatch_queue_create("com.osx-vdi.camera.timer", DISPATCH_QUEUE_SERIAL);
    }

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gTimerQueue);
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(1000000000.0 / kFrameRate), 1000000);
    dispatch_source_set_event_handler(gTimer, ^{ EmitFrame(); });
    dispatch_resume(gTimer);

    os_log(OS_LOG_DEFAULT, "[VDICamera] Stream started");
    return kCMIOHardwareNoError;
}

static OSStatus VDICam_DeviceStopStream(CMIOHardwarePlugInRef self, CMIODeviceID device,
                                         CMIOStreamID stream) {
    if (!gIsRunning) return kCMIOHardwareNoError;

    if (gTimer) {
        dispatch_source_cancel(gTimer);
        gTimer = NULL;
    }

    pthread_mutex_lock(&gMutex);
    gIsRunning = false;
    CloseSharedMemory();
    pthread_mutex_unlock(&gMutex);

    os_log(OS_LOG_DEFAULT, "[VDICamera] Stream stopped");
    return kCMIOHardwareNoError;
}

static OSStatus VDICam_DeviceProcessAVCCommand(CMIOHardwarePlugInRef self, CMIODeviceID device,
                                                CMIODeviceAVCCommand *ioAVCCommand) {
    return kCMIOHardwareUnsupportedOperationError;
}

static OSStatus VDICam_DeviceProcessRS422Command(CMIOHardwarePlugInRef self, CMIODeviceID device,
                                                  CMIODeviceRS422Command *ioRS422Command) {
    return kCMIOHardwareUnsupportedOperationError;
}

#pragma mark - Stream Operations

static OSStatus VDICam_StreamCopyBufferQueue(CMIOHardwarePlugInRef self, CMIOStreamID stream,
                                              CMIODeviceStreamQueueAlteredProc queueAlteredProc,
                                              void *queueAlteredRefCon,
                                              CMSimpleQueueRef *queue) {
    if (gQueue) {
        // Drain existing queue
        while (CMSimpleQueueGetCount(gQueue) > 0) {
            CFTypeRef item = (CFTypeRef)CMSimpleQueueDequeue(gQueue);
            if (item) CFRelease(item);
        }
        CFRelease(gQueue);
        gQueue = NULL;
    }

    OSStatus err = CMSimpleQueueCreate(kCFAllocatorDefault, kQueueSize, &gQueue);
    if (err != noErr) return err;

    gQueueAlteredProc = queueAlteredProc;
    gQueueAlteredRefCon = queueAlteredRefCon;

    *queue = gQueue;
    CFRetain(gQueue);

    return kCMIOHardwareNoError;
}

static OSStatus VDICam_StreamDeckPlay(CMIOHardwarePlugInRef self, CMIOStreamID stream) {
    return kCMIOHardwareUnsupportedOperationError;
}

static OSStatus VDICam_StreamDeckStop(CMIOHardwarePlugInRef self, CMIOStreamID stream) {
    return kCMIOHardwareUnsupportedOperationError;
}

static OSStatus VDICam_StreamDeckJog(CMIOHardwarePlugInRef self, CMIOStreamID stream, SInt32 speed) {
    return kCMIOHardwareUnsupportedOperationError;
}

static OSStatus VDICam_StreamDeckCueTo(CMIOHardwarePlugInRef self, CMIOStreamID stream,
                                        Float64 frameNumber, Boolean playOnCue) {
    return kCMIOHardwareUnsupportedOperationError;
}

#pragma mark - Driver Interface Table

static CMIOHardwarePlugInInterface gPlugInInterface = {
    NULL,                                   // _reserved
    VDICam_QueryInterface,
    VDICam_AddRef,
    VDICam_Release,
    VDICam_Initialize,
    VDICam_InitializeWithObjectID,
    VDICam_Teardown,
    VDICam_ObjectShow,
    VDICam_ObjectHasProperty,
    VDICam_ObjectIsPropertySettable,
    VDICam_ObjectGetPropertyDataSize,
    VDICam_ObjectGetPropertyData,
    VDICam_ObjectSetPropertyData,
    VDICam_DeviceSuspend,
    VDICam_DeviceResume,
    VDICam_DeviceStartStream,
    VDICam_DeviceStopStream,
    VDICam_DeviceProcessAVCCommand,
    VDICam_DeviceProcessRS422Command,
    VDICam_StreamCopyBufferQueue,
    VDICam_StreamDeckPlay,
    VDICam_StreamDeckStop,
    VDICam_StreamDeckJog,
    VDICam_StreamDeckCueTo,
};

static CMIOHardwarePlugInInterface *gPlugInInterfacePtr = &gPlugInInterface;
static CMIOHardwarePlugInRef gPlugInRef = &gPlugInInterfacePtr;

void *VDICameraPluginFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    CFUUIDRef pluginTypeID = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
        0x30, 0x01, 0x0C, 0x1C, 0x93, 0xBF, 0x11, 0xD8,
        0x8B, 0x5B, 0x00, 0x0A, 0x95, 0xAF, 0x9C, 0x6A);

    if (CFEqual(requestedTypeUUID, pluginTypeID)) {
        return gPlugInRef;
    }
    return NULL;
}
