import Foundation
import AppKit
import Network
import CoreMedia
import VDICore

final class ConnectionManager {
    private struct WindowSession {
        let decoder: VideoDecoder
        var view: RemoteWindowView?
        var forwarder: InputForwarder?
        var lastFrameNumber: UInt32 = 0
        var hasReceivedFrame = false
        var waitingForKeyframe = false
    }

    private let host: String
    private let port: UInt16
    private let client: TCPClient
    private let streamDecoder = StreamDecoder()
    private var serverName: String?
    private var windowList: [WindowInfo] = []
    private var windowSessions: [UInt32: WindowSession] = [:]

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        self.client = TCPClient(host: host, port: port)

        setupHandlers()
    }

    func connect() {
        print("Connecting to \(host):\(port)...")
        client.connect()
    }

    private func setupHandlers() {
        client.onStateChange = { [weak self] state in
            switch state {
            case .ready:
                print("Connected to server")
                self?.sendControl(.hello(version: "1.0"))
            case .failed(let error):
                print("Connection failed: \(error)")
            case .cancelled:
                print("Disconnected from server")
            default:
                break
            }
        }

        client.onData = { [weak self] data in
            self?.streamDecoder.feed(data)
        }

        streamDecoder.onControlMessage = { [weak self] message in
            self?.handleControlMessage(message)
        }

        streamDecoder.onVideoFrame = { [weak self] header, data in
            self?.handleVideoFrame(header: header, data: data)
        }
    }

    private func handleControlMessage(_ message: ControlMessage) {
        switch message {
        case .helloResponse(let version, let name):
            serverName = name
            print("Server: \(name) (v\(version))")

        case .windowList(let windows):
            windowList = windows
            print("\nAvailable windows:")
            for (i, w) in windows.enumerated() {
                let title = w.title ?? "Untitled"
                let app = w.appName ?? "Unknown"
                print("  [\(i + 1)] \(app) — \(title) (\(Int(w.bounds.width))x\(Int(w.bounds.height)))")
            }
            print("\nEnter window number to stream (or 'q' to quit):")
            DispatchQueue.global().async { [weak self] in
                self?.readWindowSelection()
            }

        case .streamStarted(let windowID, let width, let height):
            print("Stream started: window \(windowID) (\(width)x\(height))")
            let title = windowList.first(where: { $0.windowID == windowID })?.title ?? "Remote Window"
            let videoDecoder = VideoDecoder()
            var session = WindowSession(decoder: videoDecoder)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
                let viewWidth = Int(Double(width) / scaleFactor)
                let viewHeight = Int(Double(height) / scaleFactor)
                let view = RemoteWindowView(width: viewWidth, height: viewHeight, title: title)
                view.show()

                videoDecoder.onDecodedFrame = { pixelBuffer, _ in
                    view.updateFrame(pixelBuffer)
                }

                let forwarder = InputForwarder(windowID: windowID, windowView: view)
                forwarder.onInputEvent = { [weak self] event in
                    self?.sendControl(.inputEvent(event))
                }
                forwarder.start()

                session.view = view
                session.forwarder = forwarder
                self.windowSessions[windowID] = session
            }

            windowSessions[windowID] = session

        case .streamStopped(let windowID):
            print("Stream stopped: window \(windowID)")
            windowSessions[windowID]?.forwarder?.stop()
            windowSessions.removeValue(forKey: windowID)

        case .windowCreated(let info):
            if windowList.firstIndex(where: { $0.windowID == info.windowID }) == nil {
                windowList.append(info)
            }

        case .windowDestroyed(let windowID):
            windowList.removeAll { $0.windowID == windowID }
            windowSessions[windowID]?.forwarder?.stop()
            windowSessions.removeValue(forKey: windowID)

        case .windowUpdated(let info):
            if let idx = windowList.firstIndex(where: { $0.windowID == info.windowID }) {
                windowList[idx] = info
            }
            windowSessions[info.windowID]?.view?.updateTitle(info.title ?? "Remote Window")

        case .error(let message):
            print("Server error: \(message)")

        default:
            break
        }
    }

    private func handleVideoFrame(header: VideoFrameHeader, data: Data) {
        guard var session = windowSessions[header.windowID] else { return }

        if session.hasReceivedFrame {
            let expected = session.lastFrameNumber &+ 1
            if header.frameNumber != expected {
                print("Frame loss detected: expected \(expected), got \(header.frameNumber)")
                session.waitingForKeyframe = true
                windowSessions[header.windowID] = session
                sendControl(.requestKeyframe(windowID: header.windowID))
            }
        }

        if session.waitingForKeyframe && !header.isKeyframe {
            return
        }
        if header.isKeyframe {
            session.waitingForKeyframe = false
        }

        session.lastFrameNumber = header.frameNumber
        session.hasReceivedFrame = true
        windowSessions[header.windowID] = session

        session.decoder.decode(frameHeader: header, frameData: data)
    }

    private func sendControl(_ message: ControlMessage) {
        let data = MessageCodec.encode(control: message)
        client.send(data)
    }

    private func readWindowSelection() {
        while let line = readLine() {
            let input = line.trimmingCharacters(in: .whitespaces)
            if input.lowercased() == "q" {
                disconnect()
                exit(0)
            }
            if let num = Int(input), num >= 1, num <= windowList.count {
                let window = windowList[num - 1]
                print("Selecting: \(window.title ?? "Untitled")")
                sendControl(.selectWindow(windowID: window.windowID))
                print("\nEnter another window number, or 'q' to quit:")
            } else {
                print("Invalid selection. Enter 1-\(windowList.count) or 'q':")
            }
        }
    }

    func selectWindow(at index: Int) {
        guard index >= 0, index < windowList.count else { return }
        sendControl(.selectWindow(windowID: windowList[index].windowID))
    }

    func disconnect() {
        for (_, session) in windowSessions {
            session.forwarder?.stop()
        }
        windowSessions.removeAll()
        client.disconnect()
    }
}
