import AppKit
import VDICore

final class RemoteMenuManager {
    var onMenuAction: ((String, [Int]) -> Void)?

    private var remoteItemsByBundleID: [String: [RemoteMenuItem]] = [:]
    private var activeBundleID: String?
    private var savedLocalMenu: NSMenu?

    func updateMenu(bundleID: String, items: [RemoteMenuItem]) {
        remoteItemsByBundleID[bundleID] = items

        if bundleID == activeBundleID {
            installMenu(forBundleID: bundleID)
        }
    }

    func activateMenu(forBundleID bundleID: String?) {
        guard let bundleID = bundleID else {
            restoreLocalMenu()
            return
        }

        activeBundleID = bundleID
        installMenu(forBundleID: bundleID)
    }

    func deactivateMenu() {
        activeBundleID = nil
        restoreLocalMenu()
    }

    private func installMenu(forBundleID bundleID: String) {
        guard let items = remoteItemsByBundleID[bundleID] else { return }

        if savedLocalMenu == nil {
            savedLocalMenu = NSApp.mainMenu
        }

        let menu = buildMainMenu(from: items, bundleID: bundleID)

        if let localMenu = savedLocalMenu {
            for item in localMenu.items {
                if item.submenu?.title == "Devices" || item.submenu?.title == "" {
                    let copy = item.copy() as! NSMenuItem
                    menu.addItem(copy)
                }
            }
        }

        NSApp.mainMenu = menu
    }

    private func restoreLocalMenu() {
        if let saved = savedLocalMenu {
            NSApp.mainMenu = saved
            savedLocalMenu = nil
        }
    }

    private func buildMainMenu(from items: [RemoteMenuItem], bundleID: String) -> NSMenu {
        let mainMenu = NSMenu()

        for remoteItem in items {
            let menuItem = NSMenuItem(title: remoteItem.title, action: nil, keyEquivalent: "")
            if let children = remoteItem.children {
                let submenu = buildSubmenu(title: remoteItem.title, items: children, bundleID: bundleID)
                menuItem.submenu = submenu
            }
            mainMenu.addItem(menuItem)
        }

        return mainMenu
    }

    private func buildSubmenu(title: String, items: [RemoteMenuItem], bundleID: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false

        for remoteItem in items {
            if remoteItem.isSeparator {
                menu.addItem(.separator())
                continue
            }

            let menuItem = NSMenuItem(
                title: remoteItem.title,
                action: #selector(RemoteMenuTarget.handleMenuAction(_:)),
                keyEquivalent: ""
            )
            menuItem.isEnabled = remoteItem.isEnabled

            if let mark = remoteItem.markChar {
                if mark == "✓" {
                    menuItem.state = .on
                } else if mark == "•" || mark == "-" {
                    menuItem.state = .mixed
                }
            }

            if let children = remoteItem.children {
                menuItem.submenu = buildSubmenu(title: remoteItem.title, items: children, bundleID: bundleID)
                menuItem.action = nil
                menuItem.target = nil
            } else {
                let target = RemoteMenuTarget(bundleID: bundleID, path: remoteItem.path) { [weak self] bid, path in
                    self?.onMenuAction?(bid, path)
                }
                menuItem.target = target
                menuItem.representedObject = target
            }

            menu.addItem(menuItem)
        }

        return menu
    }

    private func convertModifiers(_ axMods: UInt) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = [.command]
        if axMods & 1 != 0 { flags.insert(.shift) }
        if axMods & 2 != 0 { flags.insert(.option) }
        if axMods & 4 != 0 { flags.insert(.control) }
        return flags
    }
}

private class RemoteMenuTarget: NSObject {
    let bundleID: String
    let path: [Int]
    let handler: (String, [Int]) -> Void

    init(bundleID: String, path: [Int], handler: @escaping (String, [Int]) -> Void) {
        self.bundleID = bundleID
        self.path = path
        self.handler = handler
    }

    @objc func handleMenuAction(_ sender: Any?) {
        handler(bundleID, path)
    }
}
