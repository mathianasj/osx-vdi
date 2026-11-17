import Foundation
import AppKit
import VDICore

final class MenuBarReader {
    func readMenuBar(pid: pid_t) -> [RemoteMenuItem]? {
        let app = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success else {
            return nil
        }

        let menuBar = menuBarRef as! AXUIElement
        guard let barItems = axChildren(of: menuBar) else { return nil }

        var result: [RemoteMenuItem] = []
        for (i, barItem) in barItems.enumerated() {
            if let item = readMenuItem(barItem, path: [i]) {
                result.append(item)
            }
        }
        return result
    }

    func performAction(pid: pid_t, path: [Int]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success else {
            return false
        }

        let menuBar = menuBarRef as! AXUIElement
        guard let target = findElement(in: menuBar, path: path) else { return false }

        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    private func readMenuItem(_ element: AXUIElement, path: [Int]) -> RemoteMenuItem? {
        let title = axString(element, kAXTitleAttribute as CFString) ?? ""
        let role = axString(element, kAXRoleAttribute as CFString) ?? ""

        if role == "AXSeparator" || (title.isEmpty && role == "AXMenuItem") {
            return RemoteMenuItem(title: "", isSeparator: true, path: path)
        }

        let enabled = axBool(element, kAXEnabledAttribute as CFString)
        let keyEquiv = axString(element, "AXMenuItemCmdChar" as CFString)
        let keyMods = axUInt(element, "AXMenuItemCmdModifiers" as CFString)
        let mark = axString(element, "AXMenuItemMarkChar" as CFString)

        var children: [RemoteMenuItem]?
        if let submenuItems = findSubmenuItems(of: element) {
            children = []
            for (i, child) in submenuItems.enumerated() {
                if let item = readMenuItem(child, path: path + [i]) {
                    children!.append(item)
                }
            }
            if children!.isEmpty { children = nil }
        }

        return RemoteMenuItem(
            title: title,
            isEnabled: enabled,
            keyEquivalent: keyEquiv,
            keyModifiers: keyMods,
            markChar: mark,
            children: children,
            path: path
        )
    }

    private func findSubmenuItems(of element: AXUIElement) -> [AXUIElement]? {
        guard let children = axChildren(of: element) else { return nil }
        for child in children {
            let role = axString(child, kAXRoleAttribute as CFString)
            if role == "AXMenu" {
                return axChildren(of: child)
            }
        }
        return nil
    }

    private func findElement(in menuBar: AXUIElement, path: [Int]) -> AXUIElement? {
        guard !path.isEmpty else { return nil }

        guard let barItems = axChildren(of: menuBar) else { return nil }
        guard path[0] < barItems.count else { return nil }

        var current = barItems[path[0]]

        for depth in 1..<path.count {
            guard let submenuItems = findSubmenuItems(of: current) else { return nil }
            guard path[depth] < submenuItems.count else { return nil }
            current = submenuItems[path[depth]]
        }

        return current
    }

    // MARK: - AX Helpers

    private func axChildren(of element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? [AXUIElement]
    }

    private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    private func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return true }
        if let num = ref as? NSNumber { return num.boolValue }
        return true
    }

    private func axUInt(_ element: AXUIElement, _ attribute: CFString) -> UInt? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        if let num = ref as? NSNumber { return num.uintValue }
        return nil
    }
}
