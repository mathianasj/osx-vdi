import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var host: String
    private var port: UInt16
    private var connectionManager: ConnectionManager?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = ConnectionManager(host: host, port: port)
        self.connectionManager = manager
        manager.connect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        connectionManager?.disconnect()
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "vdi",
              url.host == "connect" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = components?.queryItems ?? []

        let newHost = params.first(where: { $0.name == "host" })?.value ?? host
        let newPort = params.first(where: { $0.name == "port" })?.value.flatMap { UInt16($0) } ?? port

        print("[VDI Client] URL connect: \(newHost):\(newPort)")

        connectionManager?.disconnect()

        host = newHost
        port = newPort

        let manager = ConnectionManager(host: host, port: port)
        self.connectionManager = manager
        manager.connect()
    }
}
