import AppKit
import SwiftUI

/// A standard window for SwiftUI content: titled, closable, centered the first time, and kept
/// around between showings. Closing it hands focus back to whatever app was in front before.
@MainActor
public final class AppWindow {
    private let title: String
    private let makeContent: () -> AnyView
    private let sizesToContent: Bool
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// `sizesToContent` makes the window grow and shrink with its content (e.g. a disclosure group).
    public init(title: String, sizesToContent: Bool = false, content: @escaping () -> AnyView) {
        self.title = title
        self.sizesToContent = sizesToContent
        self.makeContent = content
    }

    public func show() {
        if window == nil {
            let controller = NSHostingController(rootView: makeContent())
            if sizesToContent { controller.sizingOptions = [.preferredContentSize] }
            let window = NSWindow(contentViewController: controller)
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { NSApp.hide(nil) }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() { window?.close() }
}
