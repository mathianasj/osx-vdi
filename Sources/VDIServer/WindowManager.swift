import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import VDICore

final class WindowManager {
    var onWindowCreated: ((WindowInfo) -> Void)?
    var onWindowDestroyed: ((UInt32) -> Void)?
    var onWindowUpdated: ((WindowInfo) -> Void)?

    private var knownWindows: [UInt32: WindowInfo] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var watchedPIDs: Set<pid_t> = []
    private var appObserverToken: Any?

    func discoverWindows() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let windows = content.windows.compactMap { window -> WindowInfo? in
            guard window.owningApplication?.processID != ownPID else { return nil }
            guard window.windowLayer == 0 else { return nil }

            let app = window.owningApplication
            let title = window.title?.isEmpty == false ? window.title : app?.applicationName
            guard title != nil else { return nil }

            return WindowInfo(
                windowID: UInt32(window.windowID),
                title: title,
                appName: app?.applicationName,
                bundleID: app?.bundleIdentifier,
                bounds: CodableRect(cgRect: window.frame),
                isOnScreen: true,
                windowLayer: window.windowLayer
            )
        }

        for window in windows {
            knownWindows[window.windowID] = window
        }

        return windows
    }

    func findSCWindow(byID windowID: UInt32) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == CGWindowID(windowID) }
    }

    func startTracking() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if app.processIdentifier != ownPID {
                watchApp(pid: app.processIdentifier)
            }
        }

        appObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.watchApp(pid: app.processIdentifier)
        }
    }

    func stopTracking() {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        watchedPIDs.removeAll()
        if let token = appObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appObserverToken = nil
        }
    }

    private func watchApp(pid: pid_t) {
        guard !watchedPIDs.contains(pid) else { return }
        watchedPIDs.insert(pid)

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &observer)
        guard result == .success, let observer = observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, appElement, kAXUIElementDestroyedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    fileprivate func handleAXNotification(_ notification: CFString, element: AXUIElement) {
        let name = notification as String

        if name == kAXWindowCreatedNotification as String {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.refreshWindows()
            }
        } else if name == kAXUIElementDestroyedNotification as String {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self?.refreshWindows()
            }
        } else if name == kAXFocusedWindowChangedNotification as String {
            Task { [weak self] in
                await self?.refreshWindows()
            }
        }
    }

    private func refreshWindows() async {
        guard let windows = try? await discoverCurrentWindows() else { return }

        let currentIDs = Set(windows.map { $0.windowID })
        let knownIDs = Set(knownWindows.keys)

        for window in windows {
            if !knownIDs.contains(window.windowID) {
                knownWindows[window.windowID] = window
                onWindowCreated?(window)
            } else if let known = knownWindows[window.windowID],
                      known.bounds != window.bounds || known.title != window.title {
                knownWindows[window.windowID] = window
                onWindowUpdated?(window)
            }
        }

        for id in knownIDs.subtracting(currentIDs) {
            knownWindows.removeValue(forKey: id)
            onWindowDestroyed?(id)
        }
    }

    private func discoverCurrentWindows() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return content.windows.compactMap { window -> WindowInfo? in
            guard window.owningApplication?.processID != ownPID else { return nil }
            guard window.windowLayer == 0 else { return nil }

            let app = window.owningApplication
            let title = window.title?.isEmpty == false ? window.title : app?.applicationName
            guard title != nil else { return nil }

            return WindowInfo(
                windowID: UInt32(window.windowID),
                title: title,
                appName: app?.applicationName,
                bundleID: app?.bundleIdentifier,
                bounds: CodableRect(cgRect: window.frame),
                isOnScreen: true,
                windowLayer: window.windowLayer
            )
        }
    }

    func printWindowList(_ windows: [WindowInfo]) {
        for (index, window) in windows.enumerated() {
            let title = window.title ?? "Untitled"
            let app = window.appName ?? "Unknown"
            let bounds = window.bounds
            print("[\(index + 1)] \(app) — \(title) (\(Int(bounds.width))x\(Int(bounds.height)))")
        }
    }
}

private func axCallback(observer: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    manager.handleAXNotification(notification, element: element)
}
