import Foundation
import AppKit
import Network
import CoreMedia
import ScreenCaptureKit
import VDICore

final class ServerSession {
    enum State {
        case waitingForHello
        case connected
        case disconnected
    }

    private struct WindowStream {
        let capture: WindowCaptureSession
        let encoder: VideoEncoder
        var info: WindowInfo
        var frameNumber: UInt32 = 0
        var isSending = false
    }

    private let connection: NWConnection
    private let windowManager: WindowManager
    private let decoder = StreamDecoder()
    private let queue = DispatchQueue(label: "com.osx-vdi.server-session")
    private let inputHandler = InputHandler()

    private var state: State = .waitingForHello
    private var streams: [UInt32: WindowStream] = [:]

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
        switch message {
        case .hello where state == .waitingForHello:
            state = .connected
            send(.helloResponse(version: "1.0", serverName: Host.current().localizedName ?? "VDI Server"))
            sendScreenInfo()
            Task { await sendWindowList() }

        case .selectWindow(let windowID) where state == .connected || !streams.isEmpty:
            if streams[windowID] == nil {
                Task { await startStreaming(windowID: windowID) }
            }

        case .deselectWindow(let windowID):
            Task { await stopStreaming(windowID: windowID) }

        case .inputEvent(let inputEvent):
            if let stream = streams[inputEvent.windowID] {
                inputHandler.handle(inputEvent, windowInfo: stream.info)
            } else {
                print("[ServerSession] No stream for windowID \(inputEvent.windowID), available: \(Array(streams.keys))")
            }

        case .requestKeyframe(let windowID):
            streams[windowID]?.encoder.forceKeyframe()

        default:
            break
        }
    }

    private func sendScreenInfo() {
        let screens = NSScreen.screens.map { screen in
            ScreenInfo(
                bounds: CodableRect(cgRect: screen.frame),
                scaleFactor: Double(screen.backingScaleFactor)
            )
        }
        send(.serverScreenInfo(screens))
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

            let scaleFactor = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
            let width = Int(scWindow.frame.width) * scaleFactor
            let height = Int(scWindow.frame.height) * scaleFactor

            let encoder = try VideoEncoder(width: width, height: height)

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

            capture.onFrame = { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer: sampleBuffer)
            }

            capture.onError = { [weak self] error in
                self?.send(.error("Capture error for window \(windowID): \(error.localizedDescription)"))
                Task { await self?.stopStreaming(windowID: windowID) }
            }

            let app = scWindow.owningApplication
            let info = WindowInfo(
                windowID: windowID,
                title: scWindow.title,
                appName: app?.applicationName,
                bundleID: app?.bundleIdentifier,
                bounds: CodableRect(cgRect: scWindow.frame),
                isOnScreen: true,
                windowLayer: scWindow.windowLayer
            )

            try await capture.start()
            streams[windowID] = WindowStream(capture: capture, encoder: encoder, info: info)
            send(.streamStarted(windowID: windowID, width: width, height: height))
        } catch {
            send(.error("Failed to start streaming: \(error.localizedDescription)"))
        }
    }

    private func stopStreaming(windowID: UInt32) async {
        guard let stream = streams.removeValue(forKey: windowID) else { return }
        try? await stream.capture.stop()
        send(.streamStopped(windowID: windowID))
    }

    private func stopAllStreams() async {
        let windowIDs = Array(streams.keys)
        for windowID in windowIDs {
            await stopStreaming(windowID: windowID)
        }
    }

    private func handleEncodedFrame(nalData: Data, isKeyframe: Bool, timestamp: CMTime, sps: Data?, pps: Data?, windowID: UInt32) {
        guard state != .disconnected else { return }
        guard var stream = streams[windowID] else { return }

        if stream.isSending && !isKeyframe {
            return
        }

        let header = VideoFrameHeader(
            windowID: windowID,
            frameNumber: stream.frameNumber,
            flags: isKeyframe ? 0x01 : 0x00,
            timestamp: UInt64(timestamp.value),
            payloadSize: UInt32(nalData.count),
            spsSize: UInt16(sps?.count ?? 0),
            ppsSize: UInt16(pps?.count ?? 0)
        )
        stream.frameNumber += 1
        stream.isSending = true
        streams[windowID] = stream

        let data = MessageCodec.encode(videoHeader: header, sps: sps, pps: pps, payload: nalData)

        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.streams[windowID]?.isSending = false
        })
    }

    private func send(_ message: ControlMessage) {
        let data = MessageCodec.encode(control: message)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func disconnect() {
        guard state != .disconnected else { return }
        state = .disconnected
        Task { await stopAllStreams() }
        connection.cancel()
    }
}
