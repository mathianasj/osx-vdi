import AppKit
import AVFoundation
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var host: String
    private var port: UInt16
    private var initialBundleID: String?
    private var connectionManager: ConnectionManager?
    private var devicesMenu: NSMenu?

    init(host: String, port: UInt16, targetBundleID: String? = nil) {
        self.host = host
        self.port = port
        self.initialBundleID = targetBundleID
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.connectionManager == nil else { return }
            let manager = ConnectionManager(host: self.host, port: self.port, targetBundleID: self.initialBundleID)
            self.connectionManager = manager
            manager.connect()
        }
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit VDI Client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let devicesMenuItem = NSMenuItem()
        let devicesMenu = NSMenu(title: "Devices")
        devicesMenuItem.submenu = devicesMenu
        self.devicesMenu = devicesMenu
        mainMenu.addItem(devicesMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        refreshDevicesMenu()
    }

    private func refreshDevicesMenu() {
        guard let menu = devicesMenu else { return }
        menu.removeAllItems()
        let dm = DeviceManager.shared

        menu.addItem(NSMenuItem.sectionHeader(withTitle: "Microphone"))
        let mics = dm.audioInputDevices()
        let currentMic = dm.currentAudioInput()
        for mic in mics {
            let item = NSMenuItem(title: mic.localizedName, action: #selector(selectAudioInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mic
            item.state = (mic.uniqueID == currentMic?.uniqueID) ? .on : .off
            menu.addItem(item)
        }
        if mics.isEmpty {
            let item = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(withTitle: "Speaker"))
        let outputs = dm.audioOutputDevices()
        let currentOutput = dm.currentAudioOutputID()
        for output in outputs {
            let item = NSMenuItem(title: output.name, action: #selector(selectAudioOutput(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(output.id)
            item.state = (output.id == currentOutput) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(withTitle: "Camera"))
        let cameras = dm.cameraDevices()
        let currentCam = dm.currentCamera()
        for cam in cameras {
            let item = NSMenuItem(title: cam.localizedName, action: #selector(selectCamera(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cam
            item.state = (cam.uniqueID == currentCam?.uniqueID) ? .on : .off
            menu.addItem(item)
        }
        if cameras.isEmpty {
            let item = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Devices", action: #selector(refreshDevicesList), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
    }

    @objc private func selectAudioInput(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AVCaptureDevice else { return }
        DeviceManager.shared.selectedAudioInput = device
        print("[Devices] Audio input: \(device.localizedName)")
        refreshDevicesMenu()
        DeviceManager.shared.onDeviceSelectionChanged?()
    }

    @objc private func selectAudioOutput(_ sender: NSMenuItem) {
        let deviceID = AudioDeviceID(sender.tag)
        DeviceManager.shared.selectedAudioOutputID = deviceID
        print("[Devices] Audio output: \(sender.title)")
        refreshDevicesMenu()
        DeviceManager.shared.onDeviceSelectionChanged?()
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AVCaptureDevice else { return }
        DeviceManager.shared.selectedCamera = device
        print("[Devices] Camera: \(device.localizedName)")
        refreshDevicesMenu()
        DeviceManager.shared.onDeviceSelectionChanged?()
    }

    @objc private func refreshDevicesList() {
        refreshDevicesMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        let bundleID = params.first(where: { $0.name == "bundleID" })?.value

        print("[VDI Client] URL connect: \(newHost):\(newPort) bundleID: \(bundleID ?? "none")")

        if let existing = connectionManager, existing.host == newHost, existing.port == newPort,
           let bundleID = bundleID {
            print("[AppDelegate] Reusing connection, adding bundleID: \(bundleID)")
            existing.addTargetBundleID(bundleID)
            return
        }
        print("[AppDelegate] Creating new connection to \(newHost):\(newPort)")

        connectionManager?.disconnect()

        host = newHost
        port = newPort

        let manager = ConnectionManager(host: host, port: port, targetBundleID: bundleID)
        self.connectionManager = manager
        manager.connect()
    }
}
