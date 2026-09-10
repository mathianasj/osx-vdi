import Foundation

public enum InputEventType: String, Codable, Sendable {
    case mouseDown
    case mouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case mouseDragged
    case scrollWheel
    case keyDown
    case keyUp
    case flagsChanged
}

public struct InputEvent: Codable, Sendable {
    public var windowID: UInt32
    public var type: InputEventType
    public var x: Double
    public var y: Double
    public var button: Int
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var scrollDeltaX: Double
    public var scrollDeltaY: Double
    public var characters: String?

    public init(
        windowID: UInt32,
        type: InputEventType,
        x: Double = 0,
        y: Double = 0,
        button: Int = 0,
        keyCode: UInt16 = 0,
        modifiers: UInt64 = 0,
        scrollDeltaX: Double = 0,
        scrollDeltaY: Double = 0,
        characters: String? = nil
    ) {
        self.windowID = windowID
        self.type = type
        self.x = x
        self.y = y
        self.button = button
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.characters = characters
    }
}

public struct ScreenInfo: Codable, Sendable {
    public var bounds: CodableRect
    public var scaleFactor: Double

    public init(bounds: CodableRect, scaleFactor: Double) {
        self.bounds = bounds
        self.scaleFactor = scaleFactor
    }
}

public enum ControlMessage: Codable, Sendable {
    case hello(version: String)
    case helloResponse(version: String, serverName: String)
    case serverScreenInfo([ScreenInfo])
    case windowList([WindowInfo])
    case selectWindow(windowID: UInt32)
    case deselectWindow(windowID: UInt32)
    case streamStarted(windowID: UInt32, width: Int, height: Int)
    case streamStopped(windowID: UInt32)
    case windowCreated(WindowInfo)
    case windowDestroyed(windowID: UInt32)
    case windowUpdated(WindowInfo)
    case inputEvent(InputEvent)
    case requestKeyframe(windowID: UInt32)
    case error(String)
}
