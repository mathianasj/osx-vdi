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
    private var pollTimer: Timer?

    func discoverWindows() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let windows = content.windows.compactMap { window -> WindowInfo? in
            guard window.owningApplication?.processID != ownPID else { return nil }
            guard window.windowLayer == 0 else { return nil }
            guard let title = window.title, !title.isEmpty else { return nil }

            let app = window.owningApplication
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.pollForChanges()
            }
        }
    }

    func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollForChanges() async {
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
            guard let title = window.title, !title.isEmpty else { return nil }

            let app = window.owningApplication
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
