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
        var framesInFlight: Int = 0
        static let maxInFlight = 5
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
    private var bitrateAdaptationStart: CFAbsoluteTime = 0
    private let virtualDisplayManager = VirtualDisplayManager()
    private let virtualCamera = VirtualCameraProvider()
    private let virtualMicrophone = VirtualMicrophoneProvider()
    private let menuBarReader = MenuBarReader()
    private var menuTimer: DispatchSourceTimer?
    private var lastMenuHash: [String: Int] = [:]

    var onDisconnect: (() -> Void)?
    var onAuthenticated: (() -> Void)?

    init(connection: NWConnection, windowManager: WindowManager) {
        self.connection = connection
        self.windowManager = windowManager

        decoder.onControlMessage = { [weak self] message in
            self?.handleControlMessage(message)
        }

        decoder.onClientVideoFrame = { [weak self] header, data in
            self?.virtualCamera.handleClientVideoFrame(header: header, data: data)
        }

        virtualCamera.onExtensionConnected = { [weak self] in
            print("[ServerSession] Camera extension connected, requesting client camera")
            self?.send(.requestClientCamera(width: 1280, height: 720))
        }
        virtualCamera.onExtensionDisconnected = { [weak self] in
            print("[ServerSession] Camera extension disconnected, stopping client camera")
            self?.send(.stopClientCamera)
        }

        decoder.onClientAudioFrame = { [weak self] header, data in
            self?.virtualMicrophone.handleClientAudioFrame(header: header, data: data)
        }

        virtualMicrophone.onIOStarted = { [weak self] in
            print("[ServerSession] Mic IO started, requesting client microphone")
            self?.send(.requestClientMicrophone)
        }
        virtualMicrophone.onIOStopped = {
            print("[ServerSession] Mic IO stopped (client mic stays active)")
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

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.state == .waitingForHello else { return }
            print("[ServerSession] No hello received after 5s, disconnecting stray connection")
            self.disconnect()
        }
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
            onAuthenticated?()
            onAuthenticated = nil
            send(.helloResponse(version: "1.0", serverName: Host.current().localizedName ?? "VDI Server"))
            sendScreenInfo()
            startCursorTracking()
            startClipboardMonitoring()
            startMenuTracking()
            startBitrateAdaptation()
            virtualMicrophone.start()
            virtualCamera.start()
            send(.requestClientMicrophone)
            Task { await sendWindowList() }

        case .hello where state == .connected:
            print("[ServerSession] Refreshing window list for reconnected client")
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
                switchAudioToWindow(inputEvent.windowID)
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

        case .clientCameraStarted(let width, let height):
            print("[ServerSession] Client camera started: \(width)x\(height)")

        case .clientMicrophoneStarted(let sampleRate, let channels):
            print("[ServerSession] Client microphone started: \(sampleRate)Hz \(channels)ch")

        case .clientCameraStopped:
            print("[ServerSession] Client camera stopped")

        case .clientMicrophoneStopped:
            print("[ServerSession] Client microphone stopped")

        case .menuAction(let bundleID, let path):
            handleMenuAction(bundleID: bundleID, path: path)

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

    // MARK: - Menu Bar

    private func startMenuTracking() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.pollMenuBars()
        }
        timer.resume()
        menuTimer = timer
    }

    private func stopMenuTracking() {
        menuTimer?.cancel()
        menuTimer = nil
    }

    private func pollMenuBars() {
        var seen = Set<String>()
        for (_, stream) in streams {
            guard let bundleID = stream.info.bundleID, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)

            guard let pid = findPid(for: stream.info) else { continue }
            guard let items = menuBarReader.readMenuBar(pid: pid) else { continue }

            let hash = items.hashableDescription.hashValue
            if lastMenuHash[bundleID] != hash {
                lastMenuHash[bundleID] = hash
                send(.menuBarUpdate(bundleID: bundleID, items: items))
                print("[ServerSession] Menu bar updated for \(bundleID) (\(items.count) top-level items)")
            }
        }
    }

    private func sendMenuBar(for info: WindowInfo) {
        guard let bundleID = info.bundleID, let pid = findPid(for: info) else { return }
        guard let items = menuBarReader.readMenuBar(pid: pid) else { return }
        lastMenuHash[bundleID] = items.hashableDescription.hashValue
        send(.menuBarUpdate(bundleID: bundleID, items: items))
        print("[ServerSession] Sent menu bar for \(bundleID) (\(items.count) top-level items)")
    }

    private func handleMenuAction(bundleID: String, path: [Int]) {
        guard let stream = streams.values.first(where: { $0.info.bundleID == bundleID }),
              let pid = findPid(for: stream.info) else {
            print("[ServerSession] No stream found for menu action: \(bundleID)")
            return
        }

        if menuBarReader.performAction(pid: pid, path: path) {
            print("[ServerSession] Menu action performed: \(bundleID) path=\(path)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.queue.async {
                    self?.pollMenuBars()
                }
            }
        } else {
            print("[ServerSession] Menu action failed: \(bundleID) path=\(path)")
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
            let scaleFactor = scaleFactorForWindow(actualWindow.frame)
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

            let shouldCaptureAudio = queue.sync { activeAudioWindowID == nil }
            let capture = WindowCaptureSession(window: actualWindow, width: width, height: height, audioEnabled: shouldCaptureAudio)
            if shouldCaptureAudio {
                queue.sync { activeAudioWindowID = windowID }
                print("[ServerSession] Audio capture assigned to window \(windowID)")
            }

            capture.onFrame = { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer: sampleBuffer)
            }

            capture.onIdleResume = { [weak encoder] in
                encoder?.forceKeyframe()
            }

            capture.onAudioSample = { [weak self] sampleBuffer in
                self?.handleAudioSample(sampleBuffer, windowID: windowID)
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

            let stream = WindowStream(capture: capture, encoder: encoder, info: info)
            let pointWidth = Int(scWindow.frame.width)
            let pointHeight = Int(scWindow.frame.height)
            queue.sync {
                self.streams[windowID] = stream
            }
            send(.streamStarted(windowID: windowID, width: pointWidth, height: pointHeight))
            sendMenuBar(for: info)

            try await capture.start()
        } catch {
            send(.error("Failed to start streaming: \(error.localizedDescription)"))
        }
    }

    private func recaptureStream(windowID: UInt32) async {
        let oldStream = queue.sync { streams[windowID] }
        guard let oldStream = oldStream else { return }
        try? await oldStream.capture.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)

        do {
            guard let scWindow = try await windowManager.findSCWindow(byID: windowID) else { return }
            let scaleFactor = scaleFactorForWindow(scWindow.frame)
            let pixelWidth = Int(scWindow.frame.width) * scaleFactor
            let pixelHeight = Int(scWindow.frame.height) * scaleFactor

            let encoder = try VideoEncoder(width: pixelWidth, height: pixelHeight)
            encoder.onEncodedFrame = { [weak self] nalData, isKeyframe, pts, sps, pps in
                self?.handleEncodedFrame(nalData: nalData, isKeyframe: isKeyframe, timestamp: pts, sps: sps, pps: pps, windowID: windowID)
            }

            let isAudioWindow = queue.sync { activeAudioWindowID == windowID }
            let capture = WindowCaptureSession(window: scWindow, width: pixelWidth, height: pixelHeight, audioEnabled: isAudioWindow)
            capture.onFrame = { [weak encoder] sampleBuffer in encoder?.encode(sampleBuffer: sampleBuffer) }
            capture.onIdleResume = { [weak encoder] in encoder?.forceKeyframe() }
            capture.onAudioSample = { [weak self] sampleBuffer in
                self?.handleAudioSample(sampleBuffer, windowID: windowID)
            }
            capture.onError = { [weak self] error in
                self?.queue.async {
                    self?.send(.error("Capture error for window \(windowID): \(error.localizedDescription)"))
                    Task { await self?.stopStreaming(windowID: windowID) }
                }
            }

            var updatedInfo = oldStream.info
            updatedInfo.bounds = CodableRect(cgRect: scWindow.frame)
            let stream = WindowStream(capture: capture, encoder: encoder, info: updatedInfo, frameNumber: oldStream.frameNumber)
            queue.sync { self.streams[windowID] = stream }

            let pointWidth = Int(scWindow.frame.width)
            let pointHeight = Int(scWindow.frame.height)
            send(.streamStarted(windowID: windowID, width: pointWidth, height: pointHeight))

            try await capture.start()
            print("[ServerSession] Recaptured stream \(windowID): \(pixelWidth)x\(pixelHeight)")
        } catch {
            print("[ServerSession] Failed to recapture: \(error)")
        }
    }

    private func restartStreaming(windowID: UInt32, width: Int, height: Int) async {
        let oldStream = queue.sync { streams[windowID] }
        guard let oldStream = oldStream else { return }

        resizeServerWindow(windowID: windowID, windowInfo: oldStream.info, width: width, height: height)

        try? await oldStream.capture.stop()

        try? await Task.sleep(nanoseconds: 200_000_000)

        do {
            guard let scWindow = try await windowManager.findSCWindow(byID: windowID) else { return }

            let actualWidth = Int(scWindow.frame.width)
            let actualHeight = Int(scWindow.frame.height)
            let scaleFactor = scaleFactorForWindow(scWindow.frame)
            print("[ServerSession] Requested: \(width)x\(height), actual window frame: \(actualWidth)x\(actualHeight), scale: \(scaleFactor)x")

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

            let isAudioWindow = queue.sync { activeAudioWindowID == windowID }
            let capture = WindowCaptureSession(window: scWindow, width: pixelWidth, height: pixelHeight, audioEnabled: isAudioWindow)
            capture.onFrame = { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer: sampleBuffer)
            }
            capture.onIdleResume = { [weak encoder] in encoder?.forceKeyframe() }
            capture.onAudioSample = { [weak self] sampleBuffer in
                self?.handleAudioSample(sampleBuffer, windowID: windowID)
            }
            capture.onError = { [weak self] error in
                self?.send(.error("Capture error for window \(windowID): \(error.localizedDescription)"))
            }

            var updatedInfo = oldStream.info
            updatedInfo.bounds = CodableRect(cgRect: scWindow.frame)
            let stream = WindowStream(capture: capture, encoder: encoder, info: updatedInfo, frameNumber: oldStream.frameNumber)
            queue.sync { self.streams[windowID] = stream }

            let pointWidth = Int(scWindow.frame.width)
            let pointHeight = Int(scWindow.frame.height)
            send(.streamStarted(windowID: windowID, width: pointWidth, height: pointHeight))

            try await capture.start()
            print("[ServerSession] Resized stream \(windowID) to \(pixelWidth)x\(pixelHeight) (points: \(pointWidth)x\(pointHeight))")
        } catch {
            print("[ServerSession] Failed to restart stream: \(error)")
        }
    }

    private func resizeServerWindow(windowID: UInt32, windowInfo: WindowInfo, width: Int, height: Int) {
        var currentPos: CGPoint?
        var currentPid: pid_t?

        if let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[CFString: Any]] {
            for entry in windowList {
                if let wid = entry[kCGWindowNumber] as? UInt32, wid == windowID,
                   let ownerPID = entry[kCGWindowOwnerPID] as? pid_t {
                    currentPid = ownerPID
                    if let bounds = entry[kCGWindowBounds] as? NSDictionary,
                       let rect = CGRect(dictionaryRepresentation: bounds) {
                        currentPos = rect.origin
                    }
                    break
                }
            }
        }

        let pid = currentPid ?? findPid(for: windowInfo)
        guard let pid = pid else {
            print("[ServerSession] Could not find PID for window resize")
            return
        }

        let matchPos = currentPos ?? CGPoint(x: windowInfo.bounds.x, y: windowInfo.bounds.y)

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

            if abs(pos.x - matchPos.x) < 5 && abs(pos.y - matchPos.y) < 5 {
                var newSize = CGSize(width: CGFloat(width), height: CGFloat(height))
                guard let sizeValue = AXValueCreate(.cgSize, &newSize) else { continue }
                let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
                print("[ServerSession] AX resize to \(width)x\(height): \(result == .success ? "success" : "failed (\(result.rawValue))")")
                return
            }
        }
        print("[ServerSession] Could not match AX window by position (looking for \(matchPos))")
    }

    private func scaleFactorForWindow(_ frame: CGRect) -> Int {
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let displayBounds = CGDisplayBounds(displayID)
            if displayBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                return max(1, Int(screen.backingScaleFactor))
            }
        }
        return Int(NSScreen.main?.backingScaleFactor ?? 2.0)
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
        let stream = queue.sync { streams.removeValue(forKey: windowID) }
        guard let stream = stream else { return }
        try? await stream.capture.stop()
        send(.streamStopped(windowID: windowID))

        queue.async { [weak self] in
            guard let self = self else { return }
            if self.activeAudioWindowID == windowID {
                self.activeAudioWindowID = nil
                if let nextID = self.streams.keys.first {
                    self.activeAudioWindowID = nextID
                    self.streams[nextID]?.capture.setAudioEnabled(true)
                    print("[ServerSession] Audio reassigned to window \(nextID)")
                }
            }
        }
    }

    private func stopAllStreams() async {
        let windowIDs = queue.sync { Array(streams.keys) }
        for windowID in windowIDs {
            await stopStreaming(windowID: windowID)
        }
    }

    private var activeAudioWindowID: UInt32?
    private var lastAudioSwitchTime: UInt64 = 0
    private var audioFrameCount: UInt64 = 0

    private func switchAudioToWindow(_ windowID: UInt32) {
        guard activeAudioWindowID != windowID else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastAudioSwitchTime > 500_000_000 else { return }
        lastAudioSwitchTime = now

        if let oldID = activeAudioWindowID, let oldStream = streams[oldID] {
            oldStream.capture.setAudioEnabled(false)
        }
        activeAudioWindowID = windowID
        if let newStream = streams[windowID] {
            newStream.capture.setAudioEnabled(true)
            print("[ServerSession] Audio switched to window \(windowID)")
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer, windowID: UInt32) {
        guard state != .disconnected else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var sampleRate: UInt32 = 48000
        var channels: UInt16 = 2
        var isInterleaved = true
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            sampleRate = UInt32(asbd.pointee.mSampleRate)
            channels = UInt16(asbd.pointee.mChannelsPerFrame)
            isInterleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        }

        let chCount = Int(channels)
        var ablSize: Int = 0
        var blockBuffer: CMBlockBuffer?

        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard ablSize > 0 else { return }

        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablMemory = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status2 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablMemory,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status2 == noErr else { return }

        let ablPtr = UnsafeMutableAudioBufferListPointer(ablMemory)
        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))

        var pcmData: Data
        if isInterleaved || ablPtr.count == 1 {
            guard let src = ablPtr[0].mData else { return }
            pcmData = Data(bytes: src, count: Int(ablPtr[0].mDataByteSize))
        } else {
            let bytesPerChannel = frameCount * 4
            pcmData = Data(count: bytesPerChannel * chCount)
            pcmData.withUnsafeMutableBytes { dest in
                let destPtr = dest.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for ch in 0..<min(chCount, ablPtr.count) {
                    guard let src = ablPtr[ch].mData else { continue }
                    memcpy(destPtr + ch * bytesPerChannel, src, min(Int(ablPtr[ch].mDataByteSize), bytesPerChannel))
                }
            }
        }

        audioFrameCount += 1
        if audioFrameCount == 1 || audioFrameCount % 500 == 0 {
            print("[ServerSession] Audio frame #\(audioFrameCount): \(sampleRate)Hz \(channels)ch \(pcmData.count)B interleaved=\(isInterleaved) bufs=\(ablPtr.count) frames=\(frameCount)")
        }

        let header = AudioFrameHeader(
            windowID: windowID,
            timestamp: UInt64(pts.value),
            sampleRate: sampleRate,
            channels: channels,
            payloadSize: UInt32(pcmData.count)
        )

        let data = MessageCodec.encode(audioHeader: header, payload: pcmData)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func handleEncodedFrame(nalData: Data, isKeyframe: Bool, timestamp: CMTime, sps: Data?, pps: Data?, windowID: UInt32) {
        queue.async { [weak self] in
            guard let self = self, self.state != .disconnected else { return }
            guard var stream = self.streams[windowID] else { return }

            if stream.framesInFlight >= WindowStream.maxInFlight && !isKeyframe {
                stream.encoder.forceKeyframe()
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
            stream.framesInFlight += 1
            self.streams[windowID] = stream

            let data = MessageCodec.encode(videoHeader: header, sps: sps, pps: pps, payload: nalData)
            let sendStart = CFAbsoluteTimeGetCurrent()

            self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.queue.async {
                    if let inFlight = self?.streams[windowID]?.framesInFlight, inFlight > 0 {
                        self?.streams[windowID]?.framesInFlight = inFlight - 1
                    }
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
        bitrateAdaptationStart = CFAbsoluteTimeGetCurrent()
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

        let elapsed = CFAbsoluteTimeGetCurrent() - bitrateAdaptationStart
        if elapsed < 5.0 {
            sendLatencies.removeAll()
            return
        }

        let avgLatency = sendLatencies.reduce(0, +) / Double(sendLatencies.count)

        let targetLevel: VideoEncoder.BitrateLevel
        if avgLatency < 0.005 {
            targetLevel = .high
        } else if avgLatency < 0.015 {
            targetLevel = .excellent
        } else if avgLatency < 0.030 {
            targetLevel = .good
        } else {
            targetLevel = .fair
        }

        for (_, stream) in streams {
            let current = stream.encoder.currentBitrate
            let target = targetLevel.rawValue

            if target != current {
                print("[Bitrate] \(current/1_000_000)Mbps → \(target/1_000_000)Mbps (latency=\(String(format: "%.1f", avgLatency * 1000))ms)")
                stream.encoder.setBitrate(target)
                if target > current {
                    stream.encoder.forceKeyframe()
                }
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
            print("[ServerSession] windowCreated: \(info.windowID) bundleID=\(info.bundleID ?? "nil") layer=\(info.windowLayer) title=\(info.title ?? "nil") size=\(Int(info.bounds.width))x\(Int(info.bounds.height))")
            if let bundleID = info.bundleID, streamingBundleIDs.contains(bundleID),
               info.bounds.width >= 200, info.bounds.height >= 200,
               info.windowLayer == 0,
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
        stopMenuTracking()
        clipboardMonitor.stop()
        virtualDisplayManager.tearDown()
        virtualCamera.stop()
        virtualMicrophone.stop()
        let allStreams = streams
        streams.removeAll()
        activeAudioWindowID = nil
        for (_, stream) in allStreams {
            Task { try? await stream.capture.stop() }
        }
        connection.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.onDisconnect?()
        }
    }
}
