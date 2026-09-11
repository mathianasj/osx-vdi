import AppKit
import IOKit.pwr_mgt
import VDICore

var port: UInt16 = 9876

let args = CommandLine.arguments
if let portIndex = args.firstIndex(of: "--port"), portIndex + 1 < args.count,
   let customPort = UInt16(args[portIndex + 1]) {
    port = customPort
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

PermissionManager.ensurePermissions()

var sleepAssertionID: IOPMAssertionID = 0
let result = IOPMAssertionCreateWithName(
    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "VDI Server active — preventing screen lock" as CFString,
    &sleepAssertionID
)
if result == kIOReturnSuccess {
    print("Screen lock prevention enabled")
} else {
    print("Warning: Could not prevent screen lock")
}

let windowManager = WindowManager()
var sessions: [ObjectIdentifier: ServerSession] = [:]

do {
    let server = try TCPServer(port: port)

    server.onNewConnection = { connection in
        let session = ServerSession(connection: connection, windowManager: windowManager)
        let id = ObjectIdentifier(session)
        sessions[id] = session
    }

    windowManager.onWindowCreated = { info in
        for (_, session) in sessions {
            session.handleNewWindow(info)
        }
    }
    windowManager.onWindowDestroyed = { windowID in
        for (_, session) in sessions {
            session.handleWindowDestroyed(windowID)
        }
    }
    windowManager.onWindowUpdated = { info in
        for (_, session) in sessions {
            session.handleWindowUpdated(info)
        }
    }
    windowManager.startTracking()
    print("VDI Server starting on port \(port)...")
    server.start()
} catch {
    print("Failed to start server: \(error)")
    exit(1)
}

app.run()
