import AppKit
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

let windowManager = WindowManager()
var sessions: [ObjectIdentifier: ServerSession] = [:]

do {
    let server = try TCPServer(port: port)

    server.onNewConnection = { connection in
        let session = ServerSession(connection: connection, windowManager: windowManager)
        let id = ObjectIdentifier(session)
        sessions[id] = session
    }

    windowManager.startTracking()
    print("VDI Server starting on port \(port)...")
    server.start()
} catch {
    print("Failed to start server: \(error)")
    exit(1)
}

app.run()
