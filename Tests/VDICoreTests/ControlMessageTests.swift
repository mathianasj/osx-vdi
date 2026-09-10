import Testing
import Foundation
import CoreGraphics
@testable import VDICore

@Test func helloRoundTrips() throws {
    let msg = ControlMessage.hello(version: "1.0")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .hello(let version) = decoded {
        #expect(version == "1.0")
    } else {
        Issue.record("Expected .hello")
    }
}

@Test func helloResponseRoundTrips() throws {
    let msg = ControlMessage.helloResponse(version: "1.0", serverName: "TestServer")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .helloResponse(let version, let name) = decoded {
        #expect(version == "1.0")
        #expect(name == "TestServer")
    } else {
        Issue.record("Expected .helloResponse")
    }
}

@Test func serverScreenInfoRoundTrips() throws {
    let screens = [
        ScreenInfo(bounds: CodableRect(x: 0, y: 0, width: 1920, height: 1080), scaleFactor: 2.0),
        ScreenInfo(bounds: CodableRect(x: 1920, y: 0, width: 2560, height: 1440), scaleFactor: 2.0)
    ]
    let msg = ControlMessage.serverScreenInfo(screens)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .serverScreenInfo(let s) = decoded {
        #expect(s.count == 2)
        #expect(s[0].bounds.width == 1920)
        #expect(s[1].scaleFactor == 2.0)
    } else {
        Issue.record("Expected .serverScreenInfo")
    }
}

@Test func windowListRoundTrips() throws {
    let windows = [
        WindowInfo(
            windowID: 1,
            title: "Window 1",
            bounds: CodableRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true,
            windowLayer: 0
        )
    ]
    let msg = ControlMessage.windowList(windows)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .windowList(let list) = decoded {
        #expect(list.count == 1)
        #expect(list[0].windowID == 1)
    } else {
        Issue.record("Expected .windowList")
    }
}

@Test func selectWindowRoundTrips() throws {
    let msg = ControlMessage.selectWindow(windowID: 42)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .selectWindow(let id) = decoded {
        #expect(id == 42)
    } else {
        Issue.record("Expected .selectWindow")
    }
}

@Test func streamStartedRoundTrips() throws {
    let msg = ControlMessage.streamStarted(windowID: 1, width: 1920, height: 1080)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .streamStarted(let id, let w, let h) = decoded {
        #expect(id == 1)
        #expect(w == 1920)
        #expect(h == 1080)
    } else {
        Issue.record("Expected .streamStarted")
    }
}

@Test func streamStoppedRoundTrips() throws {
    let msg = ControlMessage.streamStopped(windowID: 5)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .streamStopped(let id) = decoded {
        #expect(id == 5)
    } else {
        Issue.record("Expected .streamStopped")
    }
}

@Test func windowUpdatedRoundTrips() throws {
    let info = WindowInfo(
        windowID: 3,
        title: "Updated",
        bounds: CodableRect(x: 10, y: 20, width: 640, height: 480),
        isOnScreen: true,
        windowLayer: 0
    )
    let msg = ControlMessage.windowUpdated(info)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .windowUpdated(let w) = decoded {
        #expect(w.windowID == 3)
        #expect(w.title == "Updated")
    } else {
        Issue.record("Expected .windowUpdated")
    }
}

@Test func inputEventRoundTrips() throws {
    let event = InputEvent(
        windowID: 1,
        type: .keyDown,
        keyCode: 0x00,
        modifiers: 0x100,
        characters: "a"
    )
    let msg = ControlMessage.inputEvent(event)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .inputEvent(let e) = decoded {
        #expect(e.windowID == 1)
        #expect(e.type == .keyDown)
        #expect(e.keyCode == 0x00)
        #expect(e.characters == "a")
    } else {
        Issue.record("Expected .inputEvent")
    }
}

@Test func mouseInputEventRoundTrips() throws {
    let event = InputEvent(
        windowID: 5,
        type: .mouseDown,
        x: 0.5,
        y: 0.75,
        button: 0,
        modifiers: 0
    )
    let msg = ControlMessage.inputEvent(event)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .inputEvent(let e) = decoded {
        #expect(e.windowID == 5)
        #expect(e.type == .mouseDown)
        #expect(e.x == 0.5)
        #expect(e.y == 0.75)
        #expect(e.button == 0)
    } else {
        Issue.record("Expected .inputEvent")
    }
}

@Test func scrollInputEventRoundTrips() throws {
    let event = InputEvent(
        windowID: 2,
        type: .scrollWheel,
        scrollDeltaX: 1.5,
        scrollDeltaY: -3.0
    )
    let msg = ControlMessage.inputEvent(event)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .inputEvent(let e) = decoded {
        #expect(e.type == .scrollWheel)
        #expect(e.scrollDeltaX == 1.5)
        #expect(e.scrollDeltaY == -3.0)
    } else {
        Issue.record("Expected .inputEvent")
    }
}

@Test func deselectWindowRoundTrips() throws {
    let msg = ControlMessage.deselectWindow(windowID: 10)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .deselectWindow(let id) = decoded {
        #expect(id == 10)
    } else {
        Issue.record("Expected .deselectWindow")
    }
}

@Test func windowCreatedRoundTrips() throws {
    let info = WindowInfo(
        windowID: 99,
        title: "New Window",
        bounds: CodableRect(x: 0, y: 0, width: 400, height: 300),
        isOnScreen: true,
        windowLayer: 0
    )
    let msg = ControlMessage.windowCreated(info)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .windowCreated(let w) = decoded {
        #expect(w.windowID == 99)
        #expect(w.title == "New Window")
    } else {
        Issue.record("Expected .windowCreated")
    }
}

@Test func windowDestroyedRoundTrips() throws {
    let msg = ControlMessage.windowDestroyed(windowID: 42)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .windowDestroyed(let id) = decoded {
        #expect(id == 42)
    } else {
        Issue.record("Expected .windowDestroyed")
    }
}

@Test func requestKeyframeRoundTrips() throws {
    let msg = ControlMessage.requestKeyframe(windowID: 7)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .requestKeyframe(let id) = decoded {
        #expect(id == 7)
    } else {
        Issue.record("Expected .requestKeyframe")
    }
}

@Test func errorRoundTrips() throws {
    let msg = ControlMessage.error("something went wrong")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .error(let message) = decoded {
        #expect(message == "something went wrong")
    } else {
        Issue.record("Expected .error")
    }
}
