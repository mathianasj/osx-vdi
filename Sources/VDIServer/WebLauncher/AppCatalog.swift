import Foundation
import AppKit

struct AppEntry: Sendable {
    let bundleID: String
    let displayName: String
    let version: String
    let path: String
    let iconPNGData: Data?
}

final class AppCatalog {
    private var entries: [AppEntry] = []
    private let searchPaths: [String]
    private let blocklist: Set<String>

    private static let defaultBlocklist: Set<String> = [
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.dock",
        "com.apple.SystemUIServer",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.WiFiAgent",
        "com.apple.AirPlayUIAgent",
        "com.apple.CoreLocationAgent",
        "com.apple.universalaccessd",
    ]

    init(searchPaths: [String] = ["/Applications"], blocklist: Set<String> = AppCatalog.defaultBlocklist) {
        self.searchPaths = searchPaths
        self.blocklist = blocklist
    }

    func refresh() {
        var discovered: [AppEntry] = []

        for searchPath in searchPaths {
            let url = URL(fileURLWithPath: searchPath)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "app" else { continue }
                enumerator.skipDescendants()

                guard let entry = loadApp(at: fileURL.path) else { continue }
                if blocklist.contains(entry.bundleID) { continue }
                discovered.append(entry)
            }
        }

        discovered.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        entries = discovered
        print("[AppCatalog] Discovered \(entries.count) apps")
    }

    var apps: [AppEntry] { entries }

    func app(forBundleID bundleID: String) -> AppEntry? {
        entries.first { $0.bundleID == bundleID }
    }

    private func loadApp(at path: String) -> AppEntry? {
        guard let bundle = Bundle(path: path) else { return nil }
        guard let bundleID = bundle.bundleIdentifier else { return nil }

        let info = bundle.infoDictionary ?? [:]

        if info["LSUIElement"] as? Bool == true || info["LSUIElement"] as? String == "1" {
            return nil
        }
        if info["LSBackgroundOnly"] as? Bool == true || info["LSBackgroundOnly"] as? String == "1" {
            return nil
        }

        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent

        let version = (info["CFBundleShortVersionString"] as? String) ?? "1.0"

        let icon = NSWorkspace.shared.icon(forFile: path)
        let iconData = renderIconPNG(icon, size: 128)

        return AppEntry(
            bundleID: bundleID,
            displayName: displayName,
            version: version,
            path: path,
            iconPNGData: iconData
        )
    }

    private func renderIconPNG(_ image: NSImage, size: Int) -> Data? {
        let targetSize = NSSize(width: size, height: size)
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        newImage.unlockFocus()

        guard let tiff = newImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }
}
