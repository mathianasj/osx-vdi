import Foundation
import AVFoundation
import CoreMedia

final class MicrophoneCapture: NSObject {
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "com.osx-vdi.mic-capture", qos: .userInteractive)

    var onAudioSample: ((CMSampleBuffer) -> Void)?

    func start() -> Bool {
        let session = AVCaptureSession()

        guard let mic = AVCaptureDevice.default(for: .audio) else {
            print("[MicrophoneCapture] No microphone available")
            return false
        }

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
