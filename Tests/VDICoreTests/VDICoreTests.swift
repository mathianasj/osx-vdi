import Testing
import Foundation
import CoreGraphics
@testable import VDICore

@Test func windowInfoRoundTripsJSON() throws {
    let original = WindowInfo(
        windowID: 42,
        title: "My Window",
        appName: "TestApp",
        bundleID: "com.example.test",
        bounds: CodableRect(x: 10, y: 20, width: 800, height: 600),
        isOnScreen: true,
        windowLayer: 0
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WindowInfo.self, from: data)

    #expect(decoded.windowID == original.windowID)
    #expect(decoded.title == original.title)
    #expect(decoded.appName == original.appName)
    #expect(decoded.bundleID == original.bundleID)
    #expect(decoded.bounds == original.bounds)
    #expect(decoded.isOnScreen == original.isOnScreen)
    #expect(decoded.windowLayer == original.windowLayer)
}

@Test func windowInfoRoundTripsWithNilOptionals() throws {
    let original = WindowInfo(
        windowID: 7,
        bounds: CodableRect(x: 0, y: 0, width: 1920, height: 1080),
        isOnScreen: false,
        windowLayer: 1
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WindowInfo.self, from: data)

    #expect(decoded.windowID == original.windowID)
    #expect(decoded.title == nil)
    #expect(decoded.appName == nil)
    #expect(decoded.bundleID == nil)
    #expect(decoded.isOnScreen == false)
}

@Test func codableRectPreservesCGRect() {
    let rect = CGRect(x: 100.5, y: 200.75, width: 1024.0, height: 768.25)
    let codable = CodableRect(cgRect: rect)
    let restored = codable.cgRect

    #expect(restored == rect)
}

@Test func windowInfoEqualityBasedOnID() {
    let a = WindowInfo(
        windowID: 1,
        title: "A",
        bounds: CodableRect(x: 0, y: 0, width: 100, height: 100),
        isOnScreen: true,
        windowLayer: 0
    )
    let b = WindowInfo(
        windowID: 1,
        title: "B",
        bounds: CodableRect(x: 50, y: 50, width: 200, height: 200),
        isOnScreen: false,
        windowLayer: 1
    )
    let c = WindowInfo(
        windowID: 2,
        title: "A",
        bounds: CodableRect(x: 0, y: 0, width: 100, height: 100),
        isOnScreen: true,
        windowLayer: 0
    )

    #expect(a == b)
    #expect(a != c)
    #expect(a.hashValue == b.hashValue)
}
