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
    let event = InputEvent(type: "keyDown", timestamp: 12345)
    let msg = ControlMessage.inputEvent(event)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
    if case .inputEvent(let e) = decoded {
        #expect(e.type == "keyDown")
        #expect(e.timestamp == 12345)
    } else {
        Issue.record("Expected .inputEvent")
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
