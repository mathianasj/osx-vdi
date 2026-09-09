import AppKit
import VDICore

final class InputForwarder {
    private var monitors: [Any] = []
    private let windowID: UInt32
    private let windowView: RemoteWindowView
    var onInputEvent: ((InputEvent) -> Void)?

    init(windowID: UInt32, windowView: RemoteWindowView) {
        self.windowID = windowID
        self.windowView = windowView
    }

    func start() {
        let eventMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .mouseMoved, .leftMouseDragged,
            .scrollWheel,
            .keyDown, .keyUp,
            .flagsChanged
        ]

        let monitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
        if let monitor = monitor {
            monitors.append(monitor)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    private func handleEvent(_ nsEvent: NSEvent) {
        guard let window = nsEvent.window, window === windowView.nsWindow else { return }

        let inputEvent: InputEvent

        switch nsEvent.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .mouseMoved, .leftMouseDragged:
            let (nx, ny) = normalizedPosition(nsEvent)
            inputEvent = InputEvent(
                windowID: windowID,
                type: mapMouseType(nsEvent.type),
                x: nx,
                y: ny,
                button: Int(nsEvent.buttonNumber),
                modifiers: UInt64(nsEvent.modifierFlags.rawValue)
            )

        case .scrollWheel:
            inputEvent = InputEvent(
                windowID: windowID,
                type: .scrollWheel,
                scrollDeltaX: nsEvent.scrollingDeltaX,
                scrollDeltaY: nsEvent.scrollingDeltaY
            )

        case .keyDown, .keyUp:
            inputEvent = InputEvent(
                windowID: windowID,
                type: nsEvent.type == .keyDown ? .keyDown : .keyUp,
                keyCode: nsEvent.keyCode,
                modifiers: UInt64(nsEvent.modifierFlags.rawValue),
                characters: nsEvent.characters
            )

        case .flagsChanged:
            inputEvent = InputEvent(
                windowID: windowID,
                type: .flagsChanged,
                keyCode: nsEvent.keyCode,
                modifiers: UInt64(nsEvent.modifierFlags.rawValue)
            )

        default:
            return
        }

        onInputEvent?(inputEvent)
    }

    private func normalizedPosition(_ event: NSEvent) -> (Double, Double) {
        guard let contentView = event.window?.contentView else { return (0, 0) }
        let local = contentView.convert(event.locationInWindow, from: nil)
        let bounds = contentView.bounds
        let nx = Double(local.x / bounds.width).clamped(to: 0...1)
        let ny = Double(1.0 - local.y / bounds.height).clamped(to: 0...1)
        return (nx, ny)
    }

    private func mapMouseType(_ type: NSEvent.EventType) -> InputEventType {
        switch type {
        case .leftMouseDown: return .mouseDown
        case .leftMouseUp: return .mouseUp
        case .rightMouseDown: return .rightMouseDown
        case .rightMouseUp: return .rightMouseUp
        case .mouseMoved: return .mouseMoved
        case .leftMouseDragged: return .mouseDragged
        default: return .mouseMoved
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
