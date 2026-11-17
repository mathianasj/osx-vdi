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
    public var scrollIsContinuous: Bool
    public var scrollPhase: UInt
    public var scrollMomentumPhase: UInt
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
        scrollIsContinuous: Bool = false,
        scrollPhase: UInt = 0,
        scrollMomentumPhase: UInt = 0,
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
        self.scrollIsContinuous = scrollIsContinuous
        self.scrollPhase = scrollPhase
        self.scrollMomentumPhase = scrollMomentumPhase
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

public struct RemoteMenuItem: Codable, Sendable {
    public var title: String
    public var isEnabled: Bool
    public var isSeparator: Bool
    public var keyEquivalent: String?
    public var keyModifiers: UInt?
    public var markChar: String?
    public var children: [RemoteMenuItem]?
    public var path: [Int]

    public init(
        title: String,
        isEnabled: Bool = true,
        isSeparator: Bool = false,
        keyEquivalent: String? = nil,
        keyModifiers: UInt? = nil,
        markChar: String? = nil,
        children: [RemoteMenuItem]? = nil,
        path: [Int] = []
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.isSeparator = isSeparator
        self.keyEquivalent = keyEquivalent
        self.keyModifiers = keyModifiers
        self.markChar = markChar
        self.children = children
        self.path = path
    }
}

extension Array where Element == RemoteMenuItem {
    public var hashableDescription: String {
        map { $0.hashableDescription }.joined()
    }
}

extension RemoteMenuItem {
    public var hashableDescription: String {
        var s = title + (isEnabled ? "1" : "0") + (markChar ?? "")
        if let kids = children {
            s += "{" + kids.map { $0.hashableDescription }.joined() + "}"
        }
        return s
    }
}

public enum ControlMessage: Codable, Sendable {
    case hello(version: String)
    case helloResponse(version: String, serverName: String)
    case serverScreenInfo([ScreenInfo])
    case clientDisplayInfo([ScreenInfo])
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
    case resizeWindow(windowID: UInt32, width: Int, height: Int)
    case moveToDisplay(windowID: UInt32, displayIndex: Int)
    case cursorUpdate(windowID: UInt32, imageData: Data, hotspotX: Int, hotspotY: Int, pointWidth: Double, pointHeight: Double)
    case clipboardUpdate(type: String, data: Data)
    case requestClientCamera(width: Int, height: Int)
    case requestClientMicrophone
    case stopClientCamera
    case stopClientMicrophone
    case clientCameraStarted(width: Int, height: Int)
    case clientMicrophoneStarted(sampleRate: UInt32, channels: UInt16)
    case clientCameraStopped
    case clientMicrophoneStopped
    case menuBarUpdate(bundleID: String, items: [RemoteMenuItem])
    case menuAction(bundleID: String, path: [Int])
    case error(String)
}
