import Foundation
import Network
import CoreMedia
import ScreenCaptureKit
import VDICore

final class ServerSession {
    enum State {
        case waitingForHello
        case connected
        case streaming(windowID: UInt32)
        case disconnected
    }

    private let connection: NWConnection
    private let windowManager: WindowManager
    private let decoder = StreamDecoder()
    private let queue = DispatchQueue(label: "com.osx-vdi.server-session")

    private var state: State = .waitingForHello
    private var captureSession: WindowCaptureSession?
    private var encoder: VideoEncoder?
    private var frameNumber: UInt32 = 0
    private var isSending = false

    init(connection: NWConnection, windowManager: WindowManager) {
        self.connection = connection
        self.windowManager = windowManager

        decoder.onControlMessage = { [weak self] message in
            self?.handleControlMessage(message)
        }

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.disconnect()
            } else if case .cancelled = state {
                self?.disconnect()
            }
        }

        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let data = content {
                self?.decoder.feed(data)
            }
            if isComplete || error != nil {
                self?.disconnect()
                return
            }
            self?.receiveLoop()
        }
    }

    private func handleControlMessage(_ message: ControlMessage) {
        switch (state, message) {
        case (.waitingForHello, .hello):
            state = .connected
            send(.helloResponse(version: "1.0", serverName: Host.current().localizedName ?? "VDI Server"))
            Task { await sendWindowList() }

        case (.connected, .selectWindow(let windowID)):
            Task { await startStreaming(windowID: windowID) }

        case (.streaming, .requestKeyframe):
            encoder?.forceKeyframe()

        case (.streaming, .selectWindow(let windowID)):
            Task {
                await stopStreaming()
                await startStreaming(windowID: windowID)
            }

        default:
            break
        }
    }

    private func sendWindowList() async {
        do {
            let windows = try await windowManager.discoverWindows()
            send(.windowList(windows))
        } catch {
            send(.error("Failed to discover windows: \(error.localizedDescription)"))
        }
    }

    private func startStreaming(windowID: UInt32) async {
        do {
            guard let scWindow = try await windowManager.findSCWindow(byID: windowID) else {
                send(.error("Window not found: \(windowID)"))
                return
            }

            let width = Int(scWindow.frame.width)
            let height = Int(scWindow.frame.height)

            let encoder = try VideoEncoder(width: width, height: height)
            self.encoder = encoder

            encoder.onEncodedFrame = { [weak self] nalData, isKeyframe, pts, sps, pps in
                self?.handleEncodedFrame(
                    nalData: nalData,
                    isKeyframe: isKeyframe,
                    timestamp: pts,
                    sps: sps,
                    pps: pps,
                    windowID: windowID
                )
            }

            let capture = WindowCaptureSession(window: scWindow, width: width, height: height)
            self.captureSession = capture

            capture.onFrame = { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer: sampleBuffer)
            }

            capture.onError = { [weak self] error in
                self?.send(.error("Capture error: \(error.localizedDescription)"))
                Task { await self?.stopStreaming() }
            }

            try await capture.start()
            state = .streaming(windowID: windowID)
            send(.streamStarted(windowID: windowID, width: width, height: height))
        } catch {
            send(.error("Failed to start streaming: \(error.localizedDescription)"))
        }
    }

    private func stopStreaming() async {
        try? await captureSession?.stop()
        captureSession = nil
        encoder = nil
        frameNumber = 0

        if case .streaming(let windowID) = state {
            state = .connected
            send(.streamStopped(windowID: windowID))
        }
    }

    private func handleEncodedFrame(nalData: Data, isKeyframe: Bool, timestamp: CMTime, sps: Data?, pps: Data?, windowID: UInt32) {
        guard case .streaming = state else { return }

        if isSending && !isKeyframe {
            return
        }

        let header = VideoFrameHeader(
            windowID: windowID,
            frameNumber: frameNumber,
            flags: isKeyframe ? 0x01 : 0x00,
            timestamp: UInt64(timestamp.value),
            payloadSize: UInt32(nalData.count),
            spsSize: UInt16(sps?.count ?? 0),
            ppsSize: UInt16(pps?.count ?? 0)
        )
        frameNumber += 1

        let data = MessageCodec.encode(videoHeader: header, sps: sps, pps: pps, payload: nalData)

        isSending = true
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.isSending = false
        })
    }

    private func send(_ message: ControlMessage) {
        let data = MessageCodec.encode(control: message)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func disconnect() {
        guard case .disconnected = state else {
            state = .disconnected
            Task { await stopStreaming() }
            connection.cancel()
            return
        }
    }
}
