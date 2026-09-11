import Foundation
import AppKit
import CGVirtualDisplayBridge
import VDICore

final class VirtualDisplayManager {
    struct VirtualScreen {
        let display: CGVirtualDisplay
        let clientBounds: CodableRect
        let scaleFactor: Double
    }

    private var virtualScreens: [VirtualScreen] = []

    var primaryDisplayID: CGDirectDisplayID? {
        virtualScreens.first?.display.displayID
    }

    var isActive: Bool {
        !virtualScreens.isEmpty
    }

    func configureForClient(screens: [ScreenInfo]) -> Bool {
        tearDown()

        for (i, screen) in screens.enumerated() {
            let width = Int(screen.bounds.width)
            let height = Int(screen.bounds.height)
            let hiDPI: UInt32 = screen.scaleFactor >= 2.0 ? 2 : 1

            let desc = CGVirtualDisplayDescriptor()
            desc.setDispatchQueue(DispatchQueue.main)
            desc.name = "VDI Display \(i)"
            desc.maxPixelsWide = UInt32(width) * hiDPI
            desc.maxPixelsHigh = UInt32(height) * hiDPI
            let ppi: Double = screen.scaleFactor >= 2.0 ? 218 : 109
            desc.sizeInMillimeters = CGSize(
                width: Double(width) * 25.4 / ppi,
                height: Double(height) * 25.4 / ppi
            )
            desc.vendorID = 0x0D10
            desc.productID = UInt32(0x0001 + i)
            desc.serialNum = UInt32(0x0001 + i)
            desc.terminationHandler = { _, _ in
                print("[VirtualDisplayManager] Display \(i) terminated")
            }

            let newDisplay = CGVirtualDisplay(descriptor: desc)

            let settings = CGVirtualDisplaySettings()
            settings.hiDPI = hiDPI
            settings.modes = [
                CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60)
            ]

            guard newDisplay.apply(settings) else {
                print("[VirtualDisplayManager] Failed to apply settings for display \(i)")
                continue
            }

            virtualScreens.append(VirtualScreen(
                display: newDisplay,
                clientBounds: screen.bounds,
                scaleFactor: screen.scaleFactor
            ))
            print("[VirtualDisplayManager] Created display \(i): \(width)x\(height) @ \(screen.scaleFactor)x (ID: \(newDisplay.displayID))")
        }

        print("[VirtualDisplayManager] Created \(virtualScreens.count) virtual display(s)")
        return !virtualScreens.isEmpty
    }

    func displayIDForIndex(_ index: Int) -> CGDirectDisplayID? {
        guard index < virtualScreens.count else { return nil }
        return virtualScreens[index].display.displayID
    }

    func screenFrame(forDisplayIndex index: Int) -> CGRect? {
        guard let displayID = displayIDForIndex(index) else { return nil }
        return screenFrame(for: displayID)
    }

    func moveWindowToDisplay(pid: pid_t, windowBounds: CGRect, displayIndex: Int) {
        guard let displayID = displayIDForIndex(displayIndex) else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        for axWindow in axWindows {
            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success else { continue }
            var pos = CGPoint.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)

            if abs(pos.x - windowBounds.origin.x) < 5 && abs(pos.y - windowBounds.origin.y) < 5 {
                guard let frame = screenFrame(for: displayID) else { return }
                var newPos = CGPoint(x: frame.origin.x, y: frame.origin.y)
                guard let posValue = AXValueCreate(.cgPoint, &newPos) else { return }
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)

                let screen = virtualScreens[displayIndex]
                var newSize = CGSize(width: screen.clientBounds.width, height: screen.clientBounds.height)
                guard let sizeValue = AXValueCreate(.cgSize, &newSize) else { return }
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)

                print("[VirtualDisplayManager] Moved and resized window to display \(displayIndex) at \(newPos), size \(newSize)")
                return
            }
        }
    }

    func tearDown() {
        virtualScreens.removeAll()
        print("[VirtualDisplayManager] All virtual displays torn down")
    }

    private func screenFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        for screen in NSScreen.screens {
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if screenNumber == displayID {
                return screen.frame
            }
        }
        return nil
    }
}
