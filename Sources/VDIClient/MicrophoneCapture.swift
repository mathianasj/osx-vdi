import Foundation
import AVFoundation
import CoreMedia

final class MicrophoneCapture: NSObject {
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "com.osx-vdi.mic-capture", qos: .userInteractive)

    var onAudioSample: ((CMSampleBuffer) -> Void)?

    func start(device: AVCaptureDevice? = nil) -> Bool {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[MicrophoneCapture] Authorization status: \(authStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")

        if authStatus == .notDetermined {
            print("[MicrophoneCapture] Requesting microphone permission...")
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            print("[MicrophoneCapture] Permission \(granted ? "granted" : "denied")")
            if !granted { return false }
        } else if authStatus != .authorized {
            print("[MicrophoneCapture] Microphone access denied/restricted")
            return false
        }

        let session = AVCaptureSession()

        let mic = device ?? AVCaptureDevice.default(for: .audio)
        guard let mic = mic else {
            print("[MicrophoneCapture] No microphone available")
            return false
        }
        print("[MicrophoneCapture] Using device: \(mic.localizedName) (\(mic.uniqueID))")

        do {
            let input = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(input) else {
                print("[MicrophoneCapture] Cannot add mic input")
                return false
            }
            session.addInput(input)
        } catch {
            print("[MicrophoneCapture] Failed to create mic input: \(error)")
            return false
        }

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            print("[MicrophoneCapture] Cannot add audio output")
            return false
        }
        session.addOutput(output)

        session.startRunning()
        self.captureSession = session
        self.audioOutput = output
        print("[MicrophoneCapture] Started")
        return true
    }

    func stop() {
        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
        print("[MicrophoneCapture] Stopped")
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onAudioSample?(sampleBuffer)
    }
}
