import AppKit
import ApplicationServices

/// The Accessibility permission (System Settings → Privacy & Security → Accessibility). Apps
/// need it to send keystrokes to, or move the windows of, other apps.
@MainActor
public enum Accessibility {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    private static var prompted = false

    /// Shows the system "<App> would like to control this computer" prompt if access isn't granted.
    public static func request() {
        prompted = true
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Like `request()`, but at most once per launch, so using the app without access doesn't nag.
    public static func requestOnce() {
        guard !prompted else { return }
        request()
    }

    public static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
