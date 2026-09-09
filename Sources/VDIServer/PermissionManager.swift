import Foundation
import CoreGraphics
import AppKit

final class PermissionManager {
    static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func checkScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func ensurePermissions() {
        if checkScreenCapturePermission() {
            return
        }

        print("Screen recording permission is required.")
        print("Go to: System Settings > Privacy & Security > Screen Recording")
        print("Enable permission for this application, then restart.")
        print("")
        print("Requesting permission now...")

        let granted = requestScreenCapturePermission()

        if !granted {
            print("Screen recording permission was denied. Exiting.")
            exit(1)
        }

        if !checkAccessibilityPermission() {
            print("")
            print("Accessibility permission is recommended for input forwarding.")
            print("Go to: System Settings > Privacy & Security > Accessibility")
            _ = requestAccessibilityPermission()
        }
    }
}
