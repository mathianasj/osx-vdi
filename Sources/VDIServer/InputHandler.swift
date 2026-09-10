import AppKit
import CoreGraphics
import VDICore

final class InputHandler {
    func handle(_ event: InputEvent, windowInfo: WindowInfo) {
        switch event.type {
        case .mouseDown, .mouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved, .mouseDragged:
            handleMouseEvent(event, windowInfo: windowInfo)
        case .scrollWheel:
            handleScrollEvent(event, windowInfo: windowInfo)
        case .keyDown, .keyUp:
            handleKeyEvent(event, windowInfo: windowInfo)
        case .flagsChanged:
            handleFlagsChanged(event, windowInfo: windowInfo)
        }
    }

    private func handleMouseEvent(_ event: InputEvent, windowInfo: WindowInfo) {
        let bounds = windowInfo.bounds
        let screenX = bounds.x + event.x * bounds.width
        let screenY = bounds.y + event.y * bounds.height
        let point = CGPoint(x: screenX, y: screenY)

        let mouseType: CGEventType
        let mouseButton: CGMouseButton

        switch event.type {
        case .mouseDown:
            mouseType = .leftMouseDown
            mouseButton = .left
        case .mouseUp:
            mouseType = .leftMouseUp
            mouseButton = .left
        case .rightMouseDown:
            mouseType = .rightMouseDown
            mouseButton = .right
        case .rightMouseUp:
            mouseType = .rightMouseUp
            mouseButton = .right
        case .mouseMoved:
            mouseType = .mouseMoved
            mouseButton = .left
        case .mouseDragged:
            mouseType = .leftMouseDragged
            mouseButton = .left
        default:
            return
        }

        guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            print("[InputHandler] Failed to create CGEvent for \(event.type)")
            return
        }
        cgEvent.flags = CGEventFlags(rawValue: event.modifiers)

        if event.type == .mouseDown || event.type == .mouseUp ||
           event.type == .rightMouseDown || event.type == .rightMouseUp {
            cgEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        CGWarpMouseCursorPosition(point)
        cgEvent.post(tap: .cghidEventTap)
    }

    private func handleScrollEvent(_ event: InputEvent, windowInfo: WindowInfo) {
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(event.scrollDeltaY), wheel2: Int32(event.scrollDeltaX), wheel3: 0) else { return }
        cgEvent.flags = CGEventFlags(rawValue: event.modifiers)

        if let pid = pidForWindow(windowInfo) {
            cgEvent.postToPid(pid)
        } else {
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    private func handleKeyEvent(_ event: InputEvent, windowInfo: WindowInfo) {
        let keyDown = event.type == .keyDown
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(event.keyCode), keyDown: keyDown) else { return }
        cgEvent.flags = CGEventFlags(rawValue: event.modifiers)

        if let pid = pidForWindow(windowInfo) {
            cgEvent.postToPid(pid)
        } else {
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    private func handleFlagsChanged(_ event: InputEvent, windowInfo: WindowInfo) {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(event.keyCode), keyDown: true) else { return }
        cgEvent.type = .flagsChanged
        cgEvent.flags = CGEventFlags(rawValue: event.modifiers)

        if let pid = pidForWindow(windowInfo) {
            cgEvent.postToPid(pid)
        } else {
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    private func pidForWindow(_ windowInfo: WindowInfo) -> pid_t? {
        if let bundleID = windowInfo.bundleID {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let pid = apps.first?.processIdentifier {
                return pid
            }
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
}
