import AppKit
import VDICore

var host = "localhost"
var port: UInt16 = 9876

let args = CommandLine.arguments
if let hostIndex = args.firstIndex(of: "--host"), hostIndex + 1 < args.count {
    host = args[hostIndex + 1]
} else if args.count > 1, !args[1].starts(with: "-") {
    host = args[1]
}

if let portIndex = args.firstIndex(of: "--port"), portIndex + 1 < args.count {
    port = UInt16(args[portIndex + 1]) ?? 9876
} else if args.count > 2, !args[2].starts(with: "-") {
    port = UInt16(args[2]) ?? 9876
}

let app = NSApplication.shared
let delegate = AppDelegate(host: host, port: port)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

let appleEventManager = NSAppleEventManager.shared()
appleEventManager.setEventHandler(
    delegate,
    andSelector: #selector(AppDelegate.handleURLEvent(_:withReplyEvent:)),
    forEventClass: AEEventClass(kInternetEventClass),
    andEventID: AEEventID(kAEGetURL)
)

app.run()
