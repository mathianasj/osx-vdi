import AppKit
import VDICore

let host = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "localhost"
let port: UInt16 = CommandLine.arguments.count > 2 ? UInt16(CommandLine.arguments[2]) ?? 9876 : 9876

let app = NSApplication.shared
let delegate = AppDelegate(host: host, port: port)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
