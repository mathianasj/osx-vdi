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
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursorHash: Int = 0
    private let clipboardMonitor = ClipboardMonitor()
    private var sendLatencies: [Double] = []
    private var bitrateTimer: DispatchSourceTimer?
    private let virtualDisplayManager = VirtualDisplayManager()

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
            startCursorTracking()
            startClipboardMonitoring()
            startBitrateAdaptation()
            Task { await sendWindowList() }

        case .selectWindow(let windowID) where state == .connected || !streams.isEmpty:
            if streams[windowID] == nil {
                Task { await startStreaming(windowID: windowID) }
            }

        case .deselectWindow(let windowID):
            Task { await stopStreaming(windowID: windowID) }

        case .resizeWindow(let windowID, let width, let height):
            print("[ServerSession] Resize request: window \(windowID) to \(width)x\(height)")
            Task { await restartStreaming(windowID: windowID, width: width, height: height) }

        case .moveToDisplay(let windowID, let displayIndex):
            print("[ServerSession] Move window \(windowID) to display \(displayIndex)")
            if let stream = streams[windowID], let pid = findPid(for: stream.info) {
                virtualDisplayManager.moveWindowToDisplay(pid: pid, windowBounds: stream.info.bounds.cgRect, displayIndex: displayIndex)
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self.recaptureStream(windowID: windowID)
                }
            }

        case .inputEvent(let inputEvent):
            if let stream = streams[inputEvent.windowID] {
                inputHandler.handle(inputEvent, windowInfo: stream.info)
            } else {
                print("[ServerSession] No stream for windowID \(inputEvent.windowID), available: \(Array(streams.keys))")
            }

        case .requestKeyframe(let windowID):
            streams[windowID]?.encoder.forceKeyframe()

        case .clientDisplayInfo(let screens):
            print("[ServerSession] Client has \(screens.count) display(s)")
            if virtualDisplayManager.configureForClient(screens: screens) {
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await self.sendWindowList()
                }
            }

        case .clipboardUpdate(let type, let data):
            clipboardMonitor.applyRemoteClipboard(type: type, data: data)

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

    private func startCursorTracking() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.checkCursorChange()
        }
        timer.resume()
        cursorTimer = timer
    }

    private func stopCursorTracking() {
        cursorTimer?.cancel()
        cursorTimer = nil
    }

    private func checkCursorChange() {
        guard !streams.isEmpty else { return }

        let mouseLocation = NSEvent.mouseLocation
        let cursorWindowID = windowIDAtPoint(mouseLocation)
        guard let windowID = cursorWindowID, streams[windowID] != nil else { return }

        let cursor = NSCursor.current
        let cursorImage = cursor.image
        let hash = cursorImage.tiffRepresentation?.hashValue ?? 0
        guard hash != lastCursorHash else { return }
        lastCursorHash = hash

        guard let tiff = cursorImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        let hotspot = cursor.hotSpot
        let imgSize = cursorImage.size
        send(.cursorUpdate(windowID: windowID, imageData: pngData, hotspotX: Int(hotspot.x), hotspotY: Int(hotspot.y), pointWidth: imgSize.width, pointHeight: imgSize.height))
    }

    private func windowIDAtPoint(_ screenPoint: NSPoint) -> UInt32? {
        let cgPoint = CGPoint(x: screenPoint.x, y: NSScreen.main.map { $0.frame.height - screenPoint.y } ?? screenPoint.y)
        for (id, stream) in streams {
            if stream.info.bounds.cgRect.contains(cgPoint) {
                return id
            }
        }
        return nil
    }

    private func startClipboardMonitoring() {
        clipboardMonitor.onClipboardChange = { [weak self] type, data in
            self?.send(.clipboardUpdate(type: type, data: data))
        }
        clipboardMonitor.start()
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

            if virtualDisplayManager.isActive {
                if let pid = pidForApp(scWindow.owningApplication) {
                    virtualDisplayManager.moveWindowToDisplay(
                        pid: pid,
                        windowBounds: scWindow.frame,
                        displayIndex: 0
                    )
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            let refWindow = try await windowManager.findSCWindow(byID: windowID)
            let actualWindow = refWindow ?? scWindow
            let scaleFactor = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
            let width = Int(actualWindow.frame.width) * scaleFactor
            let height = Int(actualWindow.frame.height) * scaleFactor

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

            let capture = WindowCaptureSession(window: actualWindow, width: width, height: height)

            capture.onFrame = { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer: sampleBuffer)
            }

            capture.onError = { [weak self] error in
                self?.queue.async {
                    self?.send(.error("Capture error for window \(windowID): \(error.localizedDescription)"))
                    Task { await self?.stopStreaming(windowID: windowID) }
                }
            }

            let app = actualWindow.owningApplication
            let info = WindowInfo(
                windowID: windowID,
                title: actualWindow.title,
                appName: app?.applicationName,
                bundleID: app?.bundleIdentifier,
                bounds: CodableRect(cgRect: actualWindow.frame),
                isOnScreen: true,
                windowLayer: actualWindow.windowLayer
            )

            try await capture.start()
            streams[windowID] = WindowStream(capture: capture, encoder: encoder, info: info)
            let pointWidth = Int(scWindow.frame.width)
            let pointHeight = Int(scWindow.frame.height)
            send(.streamStarted(windowID: windowID, width: pointWidth, height: pointHeight))
        } catch {
            send(.error("Failed to start streaming: \(error.localizedDescription)"))
        }
    }

    private func recaptureStream(windowID: UInt32) async {
        guard let oldStream = streams[windowID] else { return }
        try? await oldStream.capture.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)

        do {
            guard let scWindow = try await windowManager.findSCWindow(byID: windowID) else { return }
            let scaleFactor = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
            let pixelWidth = Int(scWindow.frame.width) * scaleFactor
            let pixelHeight = Int(scWindow.frame.height) * scaleFactor

            let encoder = try VideoEncoder(width: pixelWidth, height: pixelHeight)
            encoder.onEncodedFrame = { [weak self] nalData, isKeyframe, pts, sps, pps in
                self?.handleEncodedFrame(nalData: nalData, isKeyframe: isKeyframe, timestamp: pts, sps: sps, pps: pps, windowID: windowID)
            }

            let capture = WindowCaptureSession(window: scWindow, width: pixelWidth, height: pixelHeight)
            capture.onFrame = { [weak encoder] sampleBuffer in encoder?.encode(sampleBuffer: sampleBuffer) }
            capture.onError = { [weak self] error in
                self?.queue.async {
                    self?.send(.error("Capture error for window \(windowID): \(error.localizedDescription)"))
                    Task { await self?.stopStreaming(windowID: windowID) }
                }
            }

            try await capture.start()
            var updatedInfo = oldStream.info
            updatedInfo.bounds = CodableRect(cgRect: scWindow.frame)
            streams[windowID] = WindowStream(capture: capture, encoder: encoder, info: updatedInfo, frameNumber: oldStream.frameNumber)

            let pointWidth = Int(scWindow.frame.width)
            let pointHeight = Int(scWindow.frame.height)
            send(.streamStarted(windowID: windowID, width: pointWidth, height: pointHeight))
            print("[ServerSession] Recaptured stream \(windowID): \(pixelWidth)x\(pixelHeight)")
        } catch {
            print("[ServerSession] Failed to recapture: \(error)")
        }
    }

    private func restartStreaming(windowID: UInt32, width: Int, height: Int) async {
        guard let oldStream = streams[windowID] else { return }

        resizeServerWindow(windowInfo: oldStream.info, width: width, height: height)

        try? await oldStream.capture.stop()

        try? await Task.sleep(nanoseconds: 200_000_000)

        do {
            guard let scWindow = try await windowManager.findSCWindow(byID: windowID) else { return }

            let actualWidth = Int(scWindow.frame.width)
            let actualHeight = Int(scWindow.frame.height)
            print("[ServerSession] Requested: \(width)x\(height), actual window frame: \(actualWidth)x\(actualHeight)")

            let scaleFactor = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
            let pixelWidth = actualWidth * scaleFactor
            let pixelHeight = actualHeight * scaleFactor

            let encoder = try VideoEncoder(width: pixelWidth, height: pixelHeight)
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

            let capture = WindowCaptureSession(window: scWindow, width: pixelWidth, height: pixelHeight)
            capture.onFrame = { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer: sampleBuffer)
            }
            capture.onError = { [weak self] error in
                self?.send(.error("Capture error for window \(windowID): \(error.localizedDescription)"))
            }

            try await capture.start()

            var updatedInfo = oldStream.info
            updatedInfo.bounds = CodableRect(cgRect: scWindow.frame)
            streams[windowID] = WindowStream(capture: capture, encoder: encoder, info: updatedInfo, frameNumber: oldStream.frameNumber)

            let pointWidth = Int(scWindow.frame.width)
            let pointHeight = Int(scWindow.frame.height)
            send(.streamStarted(windowID: windowID, width: pointWidth, height: pointHeight))
            print("[ServerSession] Resized stream \(windowID) to \(pixelWidth)x\(pixelHeight) (points: \(pointWidth)x\(pointHeight))")
        } catch {
            print("[ServerSession] Failed to restart stream: \(error)")
        }
    }

    private func resizeServerWindow(windowInfo: WindowInfo, width: Int, height: Int) {
        guard let pid = findPid(for: windowInfo) else {
            print("[ServerSession] Could not find PID for window resize")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            print("[ServerSession] Could not get AX windows")
            return
        }

        for axWindow in axWindows {
            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success else { continue }
            var pos = CGPoint.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)

            let bounds = windowInfo.bounds
            if abs(pos.x - bounds.x) < 5 && abs(pos.y - bounds.y) < 5 {
                var newSize = CGSize(width: CGFloat(width), height: CGFloat(height))
                guard let sizeValue = AXValueCreate(.cgSize, &newSize) else { continue }
                let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
                print("[ServerSession] AX resize result: \(result == .success ? "success" : "failed (\(result.rawValue))")")
                return
            }
        }
        print("[ServerSession] Could not match AX window by position")
    }

    private func pidForApp(_ app: SCRunningApplication?) -> pid_t? {
        guard let app = app else { return nil }
        return app.processID
    }

    private func findPid(for windowInfo: WindowInfo) -> pid_t? {
        if let bundleID = windowInfo.bundleID {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let pid = apps.first?.processIdentifier { return pid }
        }
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] else { return nil }
        for entry in windowList {
            if let wid = entry[kCGWindowNumber] as? UInt32, wid == windowInfo.windowID,
               let pid = entry[kCGWindowOwnerPID] as? pid_t {
                return pid
            }
        }
        return nil
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
        queue.async { [weak self] in
            guard let self = self, self.state != .disconnected else { return }
            guard var stream = self.streams[windowID] else { return }

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
            self.streams[windowID] = stream

            let data = MessageCodec.encode(videoHeader: header, sps: sps, pps: pps, payload: nalData)
            let sendStart = CFAbsoluteTimeGetCurrent()

            self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.queue.async {
                    self?.streams[windowID]?.isSending = false
                    let latency = CFAbsoluteTimeGetCurrent() - sendStart
                    self?.recordSendLatency(latency)
                }
            })
        }
    }

    private func recordSendLatency(_ latency: Double) {
        sendLatencies.append(latency)
        if sendLatencies.count > 30 {
            sendLatencies.removeFirst()
        }
    }

    private func startBitrateAdaptation() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.adaptBitrate()
        }
        timer.resume()
        bitrateTimer = timer
    }

    private func stopBitrateAdaptation() {
        bitrateTimer?.cancel()
        bitrateTimer = nil
    }

    private func adaptBitrate() {
        guard !sendLatencies.isEmpty else { return }

        let avgLatency = sendLatencies.reduce(0, +) / Double(sendLatencies.count)
        let levels = VideoEncoder.BitrateLevel.allCases

        let targetLevel: VideoEncoder.BitrateLevel
        if avgLatency < 0.005 {
            targetLevel = .high
        } else if avgLatency < 0.015 {
            targetLevel = .excellent
        } else if avgLatency < 0.030 {
            targetLevel = .good
        } else if avgLatency < 0.060 {
            targetLevel = .fair
        } else {
            targetLevel = .poor
        }

        for (_, stream) in streams {
            let current = stream.encoder.currentBitrate
            let target = targetLevel.rawValue

            if target < current {
                stream.encoder.setBitrate(target)
            } else if target > current {
                let currentIdx = levels.firstIndex { $0.rawValue == current } ?? 0
                let nextIdx = min(currentIdx + 1, levels.count - 1)
                stream.encoder.setBitrate(levels[nextIdx].rawValue)
            }
        }
    }

    private func send(_ message: ControlMessage) {
        let data = MessageCodec.encode(control: message)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func handleNewWindow(_ info: WindowInfo) {
        queue.async { [weak self] in
            guard let self = self, self.state == .connected else { return }
            let streamingBundleIDs = Set(self.streams.values.compactMap { $0.info.bundleID })
            if let bundleID = info.bundleID, streamingBundleIDs.contains(bundleID),
               info.bounds.width >= 200, info.bounds.height >= 200,
               info.title != nil, info.title != info.appName {
                print("[ServerSession] Auto-streaming new window \(info.windowID) from \(bundleID) (\(Int(info.bounds.width))x\(Int(info.bounds.height)))")
                self.send(.windowCreated(info))
                Task { await self.startStreaming(windowID: info.windowID) }
            } else {
                self.send(.windowCreated(info))
            }
        }
    }

    func handleWindowDestroyed(_ windowID: UInt32) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.send(.windowDestroyed(windowID: windowID))
            if self.streams[windowID] != nil {
                Task { await self.stopStreaming(windowID: windowID) }
            }
        }
    }

    func handleWindowUpdated(_ info: WindowInfo) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let stream = self.streams[info.windowID] {
                var updatedStream = stream
                updatedStream.info = info
                self.streams[info.windowID] = updatedStream
            }
            self.send(.windowUpdated(info))
        }
    }

    func disconnect() {
        guard state != .disconnected else { return }
        state = .disconnected
        stopCursorTracking()
        stopBitrateAdaptation()
        clipboardMonitor.stop()
        virtualDisplayManager.tearDown()
        Task { await stopAllStreams() }
        connection.cancel()
    }
}
