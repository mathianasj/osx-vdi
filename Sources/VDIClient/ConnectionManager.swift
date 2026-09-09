import Foundation
import Network
import CoreMedia
import VDICore

final class ConnectionManager {
    private let host: String
    private let port: UInt16
    private let client: TCPClient
    private let decoder = StreamDecoder()
    private let videoDecoder = VideoDecoder()
    private var remoteView: RemoteWindowView?
    private var inputForwarder: InputForwarder?
    private var serverName: String?
    private var windowList: [WindowInfo] = []

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
            self?.decoder.feed(data)
        }

        decoder.onControlMessage = { [weak self] message in
            self?.handleControlMessage(message)
        }

        decoder.onVideoFrame = { [weak self] header, data in
            self?.handleVideoFrame(header: header, data: data)
        }

        videoDecoder.onDecodedFrame = { [weak self] pixelBuffer, pts in
            self?.remoteView?.updateFrame(pixelBuffer)
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
            if let first = windows.first {
                print("\nAuto-selecting window 1: \(first.title ?? "Untitled")")
                sendControl(.selectWindow(windowID: first.windowID))
            }

        case .streamStarted(let windowID, let width, let height):
            print("Stream started: window \(windowID) (\(width)x\(height))")
            let title = windowList.first(where: { $0.windowID == windowID })?.title ?? "Remote Window"
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let view = RemoteWindowView(width: width, height: height, title: title)
                view.show()
                self.remoteView = view

                self.inputForwarder?.stop()
                let forwarder = InputForwarder(windowID: windowID, windowView: view)
                forwarder.onInputEvent = { [weak self] event in
                    self?.sendControl(.inputEvent(event))
                }
                forwarder.start()
                self.inputForwarder = forwarder
            }

        case .streamStopped(let windowID):
            print("Stream stopped: window \(windowID)")

        case .windowUpdated(let info):
            if let idx = windowList.firstIndex(where: { $0.windowID == info.windowID }) {
                windowList[idx] = info
            }

        case .error(let message):
            print("Server error: \(message)")

        default:
            break
        }
    }

    private func handleVideoFrame(header: VideoFrameHeader, data: Data) {
        videoDecoder.decode(frameHeader: header, frameData: data)
    }

    private func sendControl(_ message: ControlMessage) {
        let data = MessageCodec.encode(control: message)
        client.send(data)
    }

    func requestKeyframe() {
        sendControl(.requestKeyframe(windowID: 0))
    }

    func selectWindow(at index: Int) {
        guard index >= 0, index < windowList.count else { return }
        sendControl(.selectWindow(windowID: windowList[index].windowID))
    }

    func disconnect() {
        client.disconnect()
    }
}
