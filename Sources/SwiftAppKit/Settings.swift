import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// Note: no @State/@StateObject in here. In this SDK @State is a macro whose plugin only ships
// with full Xcode, and these apps are meant to build with just the Command Line Tools. View
// state lives in ObservableObject classes instead, and apps should do the same.

/// The standard Settings window layout: the app's own sections, then a General section with
/// launch at login and (if the app needs it) Accessibility access.
///
///     SettingsForm(needsAccessibility: true) {
///         Section("Shortcuts") { … }
///     }
public struct SettingsForm<Content: View>: View {
    private let needsAccessibility: Bool
    private let height: CGFloat
    private let content: Content
    @ObservedObject private var status = SystemStatus.shared

    // Access can be granted in System Settings while this window is open, so keep checking.
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(needsAccessibility: Bool = false, height: CGFloat = 540, @ViewBuilder content: () -> Content) {
        self.needsAccessibility = needsAccessibility
        self.height = height
        self.content = content()
    }

    public var body: some View {
        Form {
            content

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { status.launchAtLogin },
                    set: { status.setLaunchAtLogin($0) }
                ))
                if let error = status.loginItemError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if needsAccessibility {
                    LabeledContent("Accessibility access") {
                        if status.hasAccessibility {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Grant Access…") {
                                Accessibility.request()
                                Accessibility.openSettings()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: height)
        .onAppear { status.refresh() }
        .onReceive(refreshTimer) { _ in status.refresh() }
    }
}

/// A settings row with a button that records a new shortcut when clicked. Esc cancels. With an
/// optional binding, ⌫ clears the shortcut. Shows an error if macOS refused the hotkey named
/// `hotKey` (see HotKeyCenter).
public struct ShortcutField: View {
    private let title: String
    private let hotKey: String?
    private let shortcut: Binding<Shortcut?>
    private let allowsClearing: Bool
    @ObservedObject private var recorder = ShortcutRecorder.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared

    public init(_ title: String, shortcut: Binding<Shortcut>, hotKey: String? = nil) {
        self.title = title
        self.hotKey = hotKey
        self.shortcut = Binding(get: { shortcut.wrappedValue }, set: { if let new = $0 { shortcut.wrappedValue = new } })
        self.allowsClearing = false
    }

    public init(_ title: String, shortcut: Binding<Shortcut?>, hotKey: String? = nil) {
        self.title = title
        self.hotKey = hotKey
        self.shortcut = shortcut
        self.allowsClearing = true
    }

    private var isRecording: Bool { recorder.recording == title }

    public var body: some View {
        LabeledContent {
            Button(isRecording ? "Type a shortcut…" : shortcut.wrappedValue?.displayString ?? "None") {
                if isRecording {
                    recorder.stop()
                } else {
                    recorder.start(title, allowsClearing: allowsClearing) { shortcut.wrappedValue = $0 }
                }
            }
            .frame(minWidth: 130)
        } label: {
            Text(title)
            if let hotKey, hotKeys.failed.contains(hotKey) {
                Text("Already in use by another app or shortcut").foregroundStyle(.red)
            }
        }
    }
}

/// Live state for SettingsForm that can change outside the app (System Settings).
@MainActor
final class SystemStatus: ObservableObject {
    static let shared = SystemStatus()

    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemError: String?
    @Published private(set) var hasAccessibility = false

    func refresh() {
        if launchAtLogin != LoginItem.isEnabled { launchAtLogin = LoginItem.isEnabled }
        if hasAccessibility != Accessibility.isGranted { hasAccessibility = Accessibility.isGranted }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = LoginItem.isEnabled
    }
}

/// Records one shortcut at a time for ShortcutField. While recording, all hotkeys are off, so
/// typing an existing one doesn't trigger it.
@MainActor
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    /// The title of the field that's recording, if any.
    @Published private(set) var recording: String?

    private var onRecord: ((Shortcut?) -> Void)?
    private var allowsClearing = false
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?

    func start(_ field: String, allowsClearing: Bool, onRecord: @escaping (Shortcut?) -> Void) {
        stop()
        recording = field
        self.allowsClearing = allowsClearing
        self.onRecord = onRecord
        HotKeyCenter.shared.isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
        // Don't stay in recording mode (with no hotkeys) if the window is closed mid-recording.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        onRecord = nil
        recording = nil
        HotKeyCenter.shared.isRecording = false
    }

    private func record(_ event: NSEvent) {
        let bare = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == UInt16(kVK_Escape) && bare {
            stop()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) && bare && allowsClearing {
            onRecord?(nil)
            stop()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            NSSound.beep() // needs ⌘, ⌃ or ⌥
            return
        }
        // Set the new shortcut before hotkeys come back on, so the old one never re-registers.
        onRecord?(shortcut)
        stop()
    }
}
