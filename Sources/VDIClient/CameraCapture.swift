import Foundation
import AVFoundation
import CoreMedia
import VDICore

final class CameraCapture: NSObject {
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "com.osx-vdi.camera-capture", qos: .userInteractive)
    private var encoder: VideoEncoder?
    private var frameNumber: UInt32 = 0

    var onEncodedFrame: ((Data, Bool, CMTime, Data?, Data?) -> Void)?

    private let requestedWidth: Int
    private let requestedHeight: Int

    init(width: Int = 1280, height: Int = 720) {
        self.requestedWidth = width
        self.requestedHeight = height
        super.init()
    }

    func start() -> Bool {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(for: .video) else {
            print("[CameraCapture] No camera available")
            return false
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                print("[CameraCapture] Cannot add camera input")
                return false
            }
            session.addInput(input)
        } catch {
            print("[CameraCapture] Failed to create camera input: \(error)")
            return false
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            print("[CameraCapture] Cannot add video output")
            return false
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            connection.isVideoMirrored = true
        }

        do {
            let encoder = try VideoEncoder(
                width: requestedWidth,
                height: requestedHeight,
                bitrate: 2_000_000,
                keyframeInterval: 30,
                frameRate: 30
            )
            encoder.onEncodedFrame = { [weak self] nalData, isKeyframe, pts, sps, pps in
                self?.onEncodedFrame?(nalData, isKeyframe, pts, sps, pps)
            }
            self.encoder = encoder
        } catch {
            print("[CameraCapture] Failed to create encoder: \(error)")
            return false
        }

        session.startRunning()
        self.captureSession = session
        self.videoOutput = output
        print("[CameraCapture] Started: \(requestedWidth)x\(requestedHeight)")
        return true
    }

    func stop() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
        encoder = nil
        print("[CameraCapture] Stopped")
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        encoder?.encode(sampleBuffer: sampleBuffer)
    }
}
