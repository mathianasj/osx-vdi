import Foundation

public struct InputEvent: Codable, Sendable {
    public var type: String
    public var timestamp: UInt64

    public init(type: String, timestamp: UInt64) {
        self.type = type
        self.timestamp = timestamp
    }
}

public enum ControlMessage: Codable, Sendable {
    case hello(version: String)
    case helloResponse(version: String, serverName: String)
    case windowList([WindowInfo])
    case selectWindow(windowID: UInt32)
    case streamStarted(windowID: UInt32, width: Int, height: Int)
    case streamStopped(windowID: UInt32)
    case windowUpdated(WindowInfo)
    case inputEvent(InputEvent)
    case requestKeyframe(windowID: UInt32)
    case error(String)
}
