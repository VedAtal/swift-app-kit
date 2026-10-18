import Carbon.HIToolbox
import Combine

/// The app's system-wide hotkeys, registered with Carbon's `RegisterEventHotKey`. It's an old
/// API, but it's still the supported way to do this, and unlike an event tap it needs no
/// permissions. A hotkey takes its key combination away from every other app while registered.
@MainActor
public final class HotKeyCenter: ObservableObject {
    public static let shared = HotKeyCenter()

    /// Names of hotkeys macOS refused, usually because another app already has that combination.
    @Published public private(set) var failed: Set<String> = []

    /// Turns every hotkey off without forgetting them (e.g. a "Pause" menu item).
    @Published public var isPaused = false {
        didSet { if isPaused != oldValue { reregisterAll() } }
    }

    /// Set by ShortcutField while a new shortcut is being typed, so the old ones don't fire.
    var isRecording = false {
        didSet { if isRecording != oldValue { reregisterAll() } }
    }

    private struct Entry {
        let id: UInt32
        var shortcut: Shortcut
        var action: () -> Void
        var ref: EventHotKeyRef?
    }

    private var entries: [String: Entry] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    private var isActive: Bool { !isPaused && !isRecording }

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr else { return status }
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(hotKeyID.id) }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }

    /// Registers `shortcut` under `name`, replacing whatever that name had. Pass nil to remove it.
    /// If macOS refuses the combination, `name` ends up in `failed`.
    public func register(_ name: String, _ shortcut: Shortcut?, action: @escaping () -> Void) {
        unregister(name)
        guard let shortcut else { return }
        var entry = Entry(id: nextID, shortcut: shortcut, action: action)
        nextID += 1
        if isActive { activate(&entry, name: name) }
        entries[name] = entry
    }

    public func unregister(_ name: String) {
        guard let entry = entries.removeValue(forKey: name) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
        failed.remove(name)
    }

    public func unregisterAll() {
        for name in Array(entries.keys) { unregister(name) }
    }

    private func activate(_ entry: inout Entry, name: String) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5341_4B48), id: entry.id) // 'SAKH'
        let status = RegisterEventHotKey(
            entry.shortcut.keyCode, entry.shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &entry.ref
        )
        if status == noErr { failed.remove(name) } else { failed.insert(name) }
    }

    private func reregisterAll() {
        for name in entries.keys {
            guard var entry = entries[name] else { continue }
            if let ref = entry.ref {
                UnregisterEventHotKey(ref)
                entry.ref = nil
            }
            if isActive { activate(&entry, name: name) } else { failed.remove(name) }
            entries[name] = entry
        }
    }

    private func fire(_ id: UInt32) {
        entries.values.first { $0.id == id }?.action()
    }
}
