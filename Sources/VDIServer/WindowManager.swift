import Foundation
import ScreenCaptureKit
import CoreGraphics
import VDICore

final class WindowManager {
    func discoverWindows() async throws -> [WindowInfo] {
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

    func findSCWindow(byID windowID: UInt32) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == CGWindowID(windowID) }
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
