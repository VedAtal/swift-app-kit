import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored as a Carbon key code + modifier mask because that's
/// what `RegisterEventHotKey` takes.
public struct Shortcut: Equatable, Hashable, Codable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    /// What to show for the key itself ("V", "Space", "F5"…).
    public var keyLabel: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// For writing defaults in code: `Shortcut(kVK_LeftArrow, [.control, .option])`. Pass a label
    /// for letter, number and symbol keys: `Shortcut(kVK_ANSI_W, [.control, .option], label: "W")`.
    public init(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags, label: String? = nil) {
        self.init(
            keyCode: UInt32(keyCode),
            carbonModifiers: Shortcut.carbonModifiers(from: modifiers),
            keyLabel: label ?? Shortcut.specialKeyLabels[keyCode] ?? "?"
        )
    }

    /// Builds a shortcut from a key press, or nil if it has no ⌘/⌃/⌥. A global shortcut without
    /// one of those would take over ordinary typing everywhere.
    @MainActor
    public init?(event: NSEvent) {
        let modifiers = Shortcut.carbonModifiers(from: event.modifierFlags)
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyLabel: Shortcut.label(for: event))
    }

    public var modifierSymbols: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    public var displayString: String { modifierSymbols + keyLabel }

    public var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// The `keyEquivalent` that makes an NSMenuItem show this shortcut on its right-hand side.
    public var menuKeyEquivalent: String {
        if let scalar = Shortcut.menuFunctionKeys[Int(keyCode)].flatMap({ UnicodeScalar($0) }) {
            return String(Character(scalar))
        }
        return keyLabel.count == 1 ? keyLabel.lowercased() : ""
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        return UInt32(modifiers)
    }

    @MainActor
    private static func label(for event: NSEvent) -> String {
        if let special = specialKeyLabels[Int(event.keyCode)] { return special }
        let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return characters.uppercased()
    }

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Keys whose menu key equivalent isn't the character on the key.
    private static let menuFunctionKeys: [Int: Int] = [
        kVK_Space: 0x20, kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Delete: 0x08, kVK_Escape: 0x1B,
        kVK_ForwardDelete: NSDeleteFunctionKey, kVK_LeftArrow: NSLeftArrowFunctionKey,
        kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
        kVK_DownArrow: NSDownArrowFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
        kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
        kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
    ]
}
