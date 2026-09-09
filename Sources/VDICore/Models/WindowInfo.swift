import Foundation
import CoreGraphics

public struct CodableRect: Codable, Sendable, Equatable, Hashable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public init(cgRect: CGRect) {
        self.x = cgRect.origin.x
        self.y = cgRect.origin.y
        self.width = cgRect.size.width
        self.height = cgRect.size.height
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WindowInfo: Codable, Sendable {
    public var windowID: UInt32
    public var title: String?
    public var appName: String?
    public var bundleID: String?
    public var bounds: CodableRect
    public var isOnScreen: Bool
    public var windowLayer: Int

    public init(
        windowID: UInt32,
        title: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        bounds: CodableRect,
        isOnScreen: Bool,
        windowLayer: Int
    ) {
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.bundleID = bundleID
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.windowLayer = windowLayer
    }
}

extension WindowInfo: Equatable {
    public static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

extension WindowInfo: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }
}
