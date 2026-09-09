import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let host: String
    private let port: UInt16
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
}
