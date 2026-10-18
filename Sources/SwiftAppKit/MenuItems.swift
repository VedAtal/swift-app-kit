import AppKit

extension NSMenu {
    /// Adds an item that runs `action` when chosen.
    @MainActor
    @discardableResult
    public func addItem(
        _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.run), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = item
        item.handler = action
        addItem(item)
        return item
    }

    /// Adds an item that shows `shortcut` on its right-hand side and runs `action` when chosen.
    @MainActor
    @discardableResult
    public func addItem(_ title: String, shortcut: Shortcut?, action: @escaping () -> Void) -> NSMenuItem {
        addItem(title, key: shortcut?.menuKeyEquivalent ?? "", modifiers: shortcut?.cocoaModifiers ?? [], action: action)
    }

    /// Adds a grayed-out line of text.
    @MainActor
    @discardableResult
    public func addDisabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?

    @objc func run() { handler?() }
}
