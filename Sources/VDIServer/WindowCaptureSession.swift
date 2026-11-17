import Foundation
import ScreenCaptureKit
import CoreMedia

final class WindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var audioStream: SCStream?
    private let window: SCWindow
    private let width: Int
    private let height: Int
    private var audioEnabled: Bool
    private let captureQueue = DispatchQueue(label: "com.osx-vdi.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.osx-vdi.capture.audio", qos: .userInteractive)

    var onFrame: ((CMSampleBuffer) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var onIdleResume: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var idleFrameCount: Int = 0
    private static let idleThreshold = 120 // ~2 seconds at 60fps

    init(window: SCWindow, width: Int, height: Int, audioEnabled: Bool = true) {
        self.window = window
        self.width = width
        self.height = height
        self.audioEnabled = audioEnabled
        super.init()
    }

    func start() async throws {
        let videoFilter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = false
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        config.width = width
        config.height = height
        config.capturesAudio = false
        config.sampleRate = 48000
        config.channelCount = 2

        let stream = SCStream(filter: videoFilter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream

        if audioEnabled {
            try await startAudioStream()
        }
        print("[WindowCapture] Capture started: \(width)x\(height) audio=\(audioEnabled)")
    }

    private func startAudioStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let app = window.owningApplication else {
            print("[WindowCapture] No owning application for audio stream")
            return
        }

        guard let display = content.displays.first else {
            print("[WindowCapture] No display found for audio stream")
            return
        }

        let audioFilter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let audioConfig = SCStreamConfiguration()
        audioConfig.capturesAudio = true
        audioConfig.sampleRate = 48000
        audioConfig.channelCount = 2
        audioConfig.width = 2
        audioConfig.height = 2
        audioConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let aStream = SCStream(filter: audioFilter, configuration: audioConfig, delegate: self)
        try aStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await aStream.startCapture()
        self.audioStream = aStream
        print("[WindowCapture] Audio stream started for app \(app.bundleIdentifier ?? "?") (display \(display.displayID))")
    }

    func stop() async throws {
        if let aStream = audioStream {
            try? await aStream.stopCapture()
            audioStream = nil
        }
        guard let stream = stream else { return }
        try await stream.stopCapture()
        self.stream = nil
    }

    func setAudioEnabled(_ enabled: Bool) {
        guard enabled != audioEnabled else { return }
        audioEnabled = enabled
        Task {
            if enabled {
                do {
                    try await startAudioStream()
                    print("[WindowCapture] Audio enabled for window")
                } catch {
                    print("[WindowCapture] Failed to start audio stream: \(error)")
                }
            } else {
                if let aStream = audioStream {
                    try? await aStream.stopCapture()
                    audioStream = nil
                    print("[WindowCapture] Audio disabled for window")
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard stream === self.stream else { return }
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusValue = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusValue),
                  status == .complete else {
                return
            }

            if let dirtyRects = attachments.first?[.dirtyRects] as? [CGRect], dirtyRects.isEmpty {
                idleFrameCount += 1
                if idleFrameCount > Self.idleThreshold {
                    return
                }
            } else {
                if idleFrameCount > Self.idleThreshold {
                    onIdleResume?()
                }
                idleFrameCount = 0
            }

            onFrame?(sampleBuffer)

        case .audio:
            onAudioSample?(sampleBuffer)

        case .microphone:
            break

        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if stream === self.audioStream {
            print("[WindowCapture] Audio stream stopped with error: \(error)")
        } else {
            onError?(error)
        }
    }
}
