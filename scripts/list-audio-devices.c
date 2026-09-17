#include <CoreAudio/CoreAudio.h>
#include <stdio.h>

int main() {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);
    if (err != 0) { printf("Error getting device list size: %d\n", err); return 1; }

    int count = size / sizeof(AudioDeviceID);
    printf("Found %d audio devices:\n\n", count);

    AudioDeviceID *devices = malloc(size);
    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devices);
    if (err != 0) { printf("Error getting device list: %d\n", err); free(devices); return 1; }

    for (int i = 0; i < count; i++) {
        AudioDeviceID dev = devices[i];

        // Get name
        addr.mSelector = kAudioObjectPropertyName;
        CFStringRef name = NULL;
        UInt32 nameSize = sizeof(name);
        AudioObjectGetPropertyData(dev, &addr, 0, NULL, &nameSize, &name);

        // Get UID
        addr.mSelector = kAudioDevicePropertyDeviceUID;
        CFStringRef uid = NULL;
        UInt32 uidSize = sizeof(uid);
        AudioObjectGetPropertyData(dev, &addr, 0, NULL, &uidSize, &uid);

        // Get manufacturer
        addr.mSelector = kAudioObjectPropertyManufacturer;
        CFStringRef mfr = NULL;
        UInt32 mfrSize = sizeof(mfr);
        AudioObjectGetPropertyData(dev, &addr, 0, NULL, &mfrSize, &mfr);

        // Get transport type
        addr.mSelector = kAudioDevicePropertyTransportType;
        UInt32 transport = 0;
        UInt32 tSize = sizeof(transport);
        AudioObjectGetPropertyData(dev, &addr, 0, NULL, &tSize, &transport);

        // Get input channels
        addr.mSelector = kAudioDevicePropertyStreams;
        addr.mScope = kAudioObjectPropertyScopeInput;
        UInt32 inSize = 0;
        AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &inSize);
        int inStreams = inSize / sizeof(AudioStreamID);

        // Get output channels
        addr.mScope = kAudioObjectPropertyScopeOutput;
        UInt32 outSize = 0;
        AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &outSize);
        int outStreams = outSize / sizeof(AudioStreamID);

        addr.mScope = kAudioObjectPropertyScopeGlobal;

        char nameBuf[256] = "(unknown)";
        char uidBuf[256] = "(unknown)";
        char mfrBuf[256] = "(unknown)";
        if (name) { CFStringGetCString(name, nameBuf, 256, kCFStringEncodingUTF8); CFRelease(name); }
        if (uid) { CFStringGetCString(uid, uidBuf, 256, kCFStringEncodingUTF8); CFRelease(uid); }
        if (mfr) { CFStringGetCString(mfr, mfrBuf, 256, kCFStringEncodingUTF8); CFRelease(mfr); }

        char transportStr[5] = {0};
        transportStr[0] = (transport >> 24) & 0xFF;
        transportStr[1] = (transport >> 16) & 0xFF;
        transportStr[2] = (transport >> 8) & 0xFF;
        transportStr[3] = transport & 0xFF;

        printf("  Device %d (ID=%u):\n", i, dev);
        printf("    Name: %s\n", nameBuf);
        printf("    UID:  %s\n", uidBuf);
        printf("    Mfr:  %s\n", mfrBuf);
        printf("    Transport: '%s' (0x%08X)\n", transportStr, transport);
        printf("    Input streams: %d, Output streams: %d\n\n", inStreams, outStreams);
    }

    free(devices);
    return 0;
}
