import Foundation
import AppKit
import Network
import CoreMedia
import VDICore

final class ConnectionManager {
    private struct WindowSession {
        var decoder: VideoDecoder
        var view: RemoteWindowView?
        var forwarder: InputForwarder?
        var lastFrameNumber: UInt32 = 0
        var hasReceivedFrame = false
        var waitingForKeyframe = false
    }

    let host: String
    let port: UInt16
    private var targetBundleIDs: Set<String>
    private let client: TCPClient
    private let streamDecoder = StreamDecoder()
    private var serverName: String?
    private var windowList: [WindowInfo] = []
    private var windowSessions: [UInt32: WindowSession] = [:]
    private let layoutManager = WindowLayoutManager()
    private let clipboardMonitor = ClipboardMonitor()
    private let voiceIO = VoiceIOManager()
    private let clientMedia = ClientMediaManager()
    private let remoteMenu = RemoteMenuManager()
    let deviceManager = DeviceManager.shared

    init(host: String, port: UInt16, targetBundleID: String? = nil) {
        self.host = host
        self.port = port
        self.targetBundleIDs = targetBundleID.map { [$0] } ?? []
        self.client = TCPClient(host: host, port: port)

        setupHandlers()

        DeviceManager.shared.onDeviceSelectionChanged = { [weak self] in
            guard let self = self else { return }
            let outputID = DeviceManager.shared.currentAudioOutputID()
            self.voiceIO.setOutputDevice(outputID)

            if let mic = DeviceManager.shared.currentAudioInput() {
                let inputID = DeviceManager.shared.audioDeviceID(for: mic)
                self.voiceIO.setInputDevice(inputID)
            } else {
                self.voiceIO.setInputDevice(nil)
            }
        }
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
                self?.startClipboardMonitoring()
                let outputID = DeviceManager.shared.currentAudioOutputID()
                self?.voiceIO.setOutputDevice(outputID)
            case .failed(let error):
                print("Connection failed: \(error)")
                self?.voiceIO.stop()
                self?.clientMedia.stopAll()
            case .cancelled:
                print("Disconnected from server")
                self?.voiceIO.stop()
                self?.clientMedia.stopAll()
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

        streamDecoder.onAudioFrame = { [weak self] header, data in
            self?.voiceIO.play(header: header, data: data)
        }

        clientMedia.onVideoData = { [weak self] data in
            self?.client.send(data)
        }

        clientMedia.onCameraStarted = { [weak self] width, height in
            self?.sendControl(.clientCameraStarted(width: width, height: height))
        }

        clientMedia.onCameraStopped = { [weak self] in
            self?.sendControl(.clientCameraStopped)
        }

        voiceIO.onMicSample = { [weak self] pcmData, sampleRate, channels in
            let header = AudioFrameHeader(
                windowID: 0,
                timestamp: 0,
                sampleRate: sampleRate,
                channels: channels,
                payloadSize: UInt32(pcmData.count)
            )
            let data = MessageCodec.encode(clientAudioHeader: header, payload: pcmData)
            self?.client.send(data)
        }

        remoteMenu.onMenuAction = { [weak self] bundleID, path in
            self?.sendControl(.menuAction(bundleID: bundleID, path: path))
        }
    }

    private func handleControlMessage(_ message: ControlMessage) {
        switch message {
        case .helloResponse(let version, let name):
            serverName = name
            print("Server: \(name) (v\(version))")
            sendClientDisplayInfo()

        case .serverScreenInfo(let screens):
            layoutManager.updateServerScreens(screens)
            print("Server screens: \(screens.count)")

        case .windowList(let windows):
            windowList = windows
            print("\nAvailable windows:")
            for (i, w) in windows.enumerated() {
                let title = w.title ?? "Untitled"
                let app = w.appName ?? "Unknown"
                print("  [\(i + 1)] \(app) — \(title) (\(Int(w.bounds.width))x\(Int(w.bounds.height)))")
            }

            if !targetBundleIDs.isEmpty {
                for bundleID in targetBundleIDs {
                    let matching = windows.filter { $0.bundleID == bundleID }
                    if matching.isEmpty {
                        print("No windows found for \(bundleID), retrying in 2s...")
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                            self?.sendControl(.hello(version: "1.0"))
                        }
                    } else {
                        print("Auto-selecting \(matching.count) window(s) for \(bundleID)")
                        for window in matching {
                            sendControl(.selectWindow(windowID: window.windowID))
                        }
                    }
                }
            } else {
                print("\nEnter window number to stream (or 'q' to quit):")
                DispatchQueue.global().async { [weak self] in
                    self?.readWindowSelection()
                }
            }

        case .streamStarted(let windowID, let width, let height):
            print("Stream started: window \(windowID) (\(width)x\(height))")

            if var existing = windowSessions[windowID], existing.view != nil {
                existing.hasReceivedFrame = false
                existing.waitingForKeyframe = true
                existing.lastFrameNumber = 0
                windowSessions[windowID] = existing
                sendControl(.requestKeyframe(windowID: windowID))
                return
            }

            let title = windowList.first(where: { $0.windowID == windowID })?.title ?? "Remote Window"
            let videoDecoder = VideoDecoder()
            var session = WindowSession(decoder: videoDecoder)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let bundleID = self.windowList.first(where: { $0.windowID == windowID })?.bundleID
                let view = RemoteWindowView(width: width, height: height, title: title, bundleID: bundleID)
                if let info = self.windowList.first(where: { $0.windowID == windowID }) {
                    self.layoutManager.updateWindowPosition(view, windowInfo: info)
                }
                view.show()

                videoDecoder.onDecodedFrame = { pixelBuffer, _ in
                    view.updateFrame(pixelBuffer)
                }

                view.onResize = { [weak self] width, height in
                    self?.sendControl(.resizeWindow(windowID: windowID, width: width, height: height))
                }

                view.onDisplayChanged = { [weak self] displayIndex in
                    self?.sendControl(.moveToDisplay(windowID: windowID, displayIndex: displayIndex))
                }

                let forwarder = InputForwarder(windowID: windowID, windowView: view)
                forwarder.onInputEvent = { [weak self] event in
                    self?.sendControl(.inputEvent(event))
                }
                forwarder.start()

                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: view.nsWindow,
                    queue: .main
                ) { [weak self] _ in
                    self?.remoteMenu.activateMenu(forBundleID: bundleID)
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: view.nsWindow,
                    queue: .main
                ) { [weak self] _ in
                    self?.remoteMenu.deactivateMenu()
                }

                self.remoteMenu.activateMenu(forBundleID: bundleID)

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
            if let bundleID = info.bundleID, targetBundleIDs.contains(bundleID),
               windowSessions[info.windowID] == nil,
               info.bounds.width >= 400, info.bounds.height >= 300,
               info.title != nil, info.title != info.appName {
                print("Auto-selecting new window for \(bundleID): \(info.title ?? "Untitled")")
                sendControl(.selectWindow(windowID: info.windowID))
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

        case .cursorUpdate(let windowID, let imageData, let hotspotX, let hotspotY, let pointWidth, let pointHeight):
            windowSessions[windowID]?.view?.updateCursor(imageData: imageData, hotspotX: hotspotX, hotspotY: hotspotY, pointWidth: pointWidth, pointHeight: pointHeight)

        case .clipboardUpdate(let type, let data):
            clipboardMonitor.applyRemoteClipboard(type: type, data: data)

        case .menuBarUpdate(let bundleID, let items):
            DispatchQueue.main.async { [weak self] in
                self?.remoteMenu.updateMenu(bundleID: bundleID, items: items)
            }

        case .requestClientCamera(let width, let height):
            print("Server requested camera: \(width)x\(height)")
            clientMedia.startCamera(width: width, height: height, device: DeviceManager.shared.currentCamera())

        case .requestClientMicrophone:
            print("Server requested microphone")
            let inputID: AudioDeviceID?
            if let mic = DeviceManager.shared.selectedAudioInput {
                inputID = DeviceManager.shared.audioDeviceID(for: mic)
            } else {
                inputID = nil
            }
            voiceIO.startMicCapture(inputDeviceID: inputID)
            sendControl(.clientMicrophoneStarted(sampleRate: 48000, channels: 1))

        case .stopClientCamera:
            clientMedia.stopCamera()

        case .stopClientMicrophone:
            voiceIO.stopMicCapture()
            sendControl(.clientMicrophoneStopped)

        case .error(let message):
            print("Server error: \(message)")

        default:
            break
        }
    }

    // MARK: - Video Stats
    private var videoStatsFile: FileHandle?
    private var frameTimestamps: [UInt64] = []
    private var totalFramesReceived: Int = 0
    private var totalFramesDecoded: Int = 0
    private var totalFramesDropped: Int = 0
    private var totalKeyframes: Int = 0
    private var lastFrameDisplayTime: UInt64 = 0
    private var maxInterFrameMs: Double = 0
    private var totalDecodeLatencyNs: UInt64 = 0
    private var statsStartTime: UInt64 = 0
    private var lastStatsReport: UInt64 = 0
    private var frameSizes: [Int] = []

    private func initVideoStats() {
        if videoStatsFile != nil { return }
        let path = "/tmp/vdi-video-stats.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        videoStatsFile = FileHandle(forWritingAtPath: path)
        statsStartTime = DispatchTime.now().uptimeNanoseconds
        lastStatsReport = statsStartTime
        writeVideoLog("=== VDI Video Stats ===")
    }

    private func writeVideoLog(_ line: String) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - statsStartTime) / 1_000_000_000.0
        let msg = String(format: "[%8.3f] %@\n", elapsed, line)
        videoStatsFile?.write(msg.data(using: .utf8)!)
    }

    private func reportVideoStats() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastStatsReport > 2_000_000_000 else { return }
        lastStatsReport = now

        let elapsed = Double(now - statsStartTime) / 1_000_000_000.0
        let fps = Double(totalFramesReceived) / elapsed

        var avgInterFrame: Double = 0
        var jitter: Double = 0
        if frameTimestamps.count > 1 {
            var intervals: [Double] = []
            for i in 1..<frameTimestamps.count {
                intervals.append(Double(frameTimestamps[i] - frameTimestamps[i-1]) / 1_000_000.0)
            }
            avgInterFrame = intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.map { ($0 - avgInterFrame) * ($0 - avgInterFrame) }.reduce(0, +) / Double(intervals.count)
            jitter = sqrt(variance)
        }

        let avgSize = frameSizes.isEmpty ? 0 : frameSizes.reduce(0, +) / frameSizes.count
        let avgDecodeMs = totalFramesDecoded > 0 ? Double(totalDecodeLatencyNs) / Double(totalFramesDecoded) / 1_000_000.0 : 0

        writeVideoLog(String(format: "STATS: fps=%.1f recv=%d decoded=%d dropped=%d keyframes=%d", fps, totalFramesReceived, totalFramesDecoded, totalFramesDropped, totalKeyframes))
        writeVideoLog(String(format: "  timing: avgInterval=%.1fms jitter=%.1fms maxGap=%.1fms", avgInterFrame, jitter, maxInterFrameMs))
        writeVideoLog(String(format: "  decode: avgLatency=%.1fms avgSize=%dB", avgDecodeMs, avgSize))

        frameTimestamps.removeAll(keepingCapacity: true)
        frameSizes.removeAll(keepingCapacity: true)
        maxInterFrameMs = 0
    }

    private func handleVideoFrame(header: VideoFrameHeader, data: Data) {
        initVideoStats()

        let receiveTime = DispatchTime.now().uptimeNanoseconds
        totalFramesReceived += 1
        frameTimestamps.append(receiveTime)
        frameSizes.append(data.count)

        if header.isKeyframe { totalKeyframes += 1 }

        if lastFrameDisplayTime > 0 {
            let gapMs = Double(receiveTime - lastFrameDisplayTime) / 1_000_000.0
            if gapMs > maxInterFrameMs { maxInterFrameMs = gapMs }
        }
        lastFrameDisplayTime = receiveTime

        guard var session = windowSessions[header.windowID] else { return }

        if session.hasReceivedFrame {
            let expected = session.lastFrameNumber &+ 1
            if header.frameNumber != expected && header.frameNumber > session.lastFrameNumber {
                let dropped = Int(header.frameNumber - session.lastFrameNumber - 1)
                totalFramesDropped += dropped
                writeVideoLog("FRAMEDROP: expected=\(expected) got=\(header.frameNumber) dropped=\(dropped)")
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
        totalFramesDecoded += 1
        totalDecodeLatencyNs += (DispatchTime.now().uptimeNanoseconds - receiveTime)

        reportVideoStats()
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

    private func sendClientDisplayInfo() {
        DispatchQueue.main.async { [weak self] in
            let screens = NSScreen.screens.map { screen in
                ScreenInfo(
                    bounds: CodableRect(cgRect: screen.frame),
                    scaleFactor: Double(screen.backingScaleFactor)
                )
            }
            print("Sending client display info: \(screens.count) display(s)")
            for (i, s) in screens.enumerated() {
                print("  Display \(i): \(Int(s.bounds.width))x\(Int(s.bounds.height)) @ \(s.scaleFactor)x")
            }
            self?.sendControl(.clientDisplayInfo(screens))
        }
    }

    private func startClipboardMonitoring() {
        clipboardMonitor.onClipboardChange = { [weak self] type, data in
            self?.sendControl(.clipboardUpdate(type: type, data: data))
        }
        clipboardMonitor.start()
    }

    func addTargetBundleID(_ bundleID: String) {
        targetBundleIDs.insert(bundleID)
        let matching = windowList.filter { $0.bundleID == bundleID && windowSessions[$0.windowID] == nil }
        if matching.isEmpty {
            print("No windows found yet for \(bundleID), will auto-select when available")
        } else {
            print("Selecting \(matching.count) window(s) for \(bundleID)")
            for window in matching {
                sendControl(.selectWindow(windowID: window.windowID))
            }
        }
    }

    func selectWindow(at index: Int) {
        guard index >= 0, index < windowList.count else { return }
        sendControl(.selectWindow(windowID: windowList[index].windowID))
    }

    func disconnect() {
        clipboardMonitor.stop()
        voiceIO.stop()
        clientMedia.stopAll()
        for (_, session) in windowSessions {
            session.forwarder?.stop()
        }
        windowSessions.removeAll()
        client.disconnect()
    }
}
