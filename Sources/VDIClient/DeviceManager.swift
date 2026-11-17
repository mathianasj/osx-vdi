import Foundation
import AVFoundation
import CoreAudio

final class DeviceManager {
    static let shared = DeviceManager()

    var selectedAudioInput: AVCaptureDevice?
    var selectedCamera: AVCaptureDevice?
    var selectedAudioOutputID: AudioDeviceID?

    var onDeviceSelectionChanged: (() -> Void)?

    struct AudioOutputDevice {
        let id: AudioDeviceID
        let name: String
    }

    func audioInputDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func cameraDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    func audioOutputDevices() -> [AudioOutputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> AudioOutputDevice? in
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &outputAddress, 0, nil, &outputSize) == noErr else {
                return nil
            }
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(outputSize))
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &outputAddress, 0, nil, &outputSize, bufferListPtr) == noErr else {
                return nil
            }
            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let outputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard outputChannels > 0 else { return nil }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

            return AudioOutputDevice(id: deviceID, name: name as String)
        }
    }

    func defaultAudioOutputID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &size,
            &deviceID
        )
        return deviceID
    }

    func currentAudioInput() -> AVCaptureDevice? {
        selectedAudioInput ?? AVCaptureDevice.default(for: .audio)
    }

    func currentCamera() -> AVCaptureDevice? {
        selectedCamera ?? AVCaptureDevice.default(for: .video)
    }

    func currentAudioOutputID() -> AudioDeviceID {
        selectedAudioOutputID ?? defaultAudioOutputID()
    }

    func audioDeviceID(for captureDevice: AVCaptureDevice) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &ids
        ) == noErr else { return nil }

        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
               (uid as String) == captureDevice.uniqueID {
                return id
            }
        }
        return nil
    }
}
