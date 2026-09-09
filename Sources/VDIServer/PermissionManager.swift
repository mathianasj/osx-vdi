import Foundation
import CoreGraphics

final class PermissionManager {
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
    }
}
