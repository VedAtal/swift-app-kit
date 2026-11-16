import AppKit
import SwiftUI

/// A titled group of controls in an app's panel (MenuBarAppDelegate.makePanelView).
///
///     PanelSection("Displays") { Slider(…) }
public struct PanelSection<Content: View>: View {
    private let title: String
    private let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content
        }
    }
}

extension View {
    /// The panel's tile look: faint at rest, tinted and outlined when highlighted (chosen, on,
    /// pressed).
    public func panelTile(highlighted: Bool = false, cornerRadius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(highlighted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(highlighted ? Color.accentColor.opacity(0.55) : .clear))
    }
}

/// A panel button drawn as a tile, highlighted while pressed or while `highlighted` (chosen, on):
/// `.buttonStyle(.panelTile)`, `.buttonStyle(.panelTile(highlighted: isOn))`.
public struct PanelTileButtonStyle: ButtonStyle {
    private let highlighted: Bool

    public init(highlighted: Bool = false) {
        self.highlighted = highlighted
    }

    public func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, highlighted: highlighted)
    }

    private struct Tile: View {
        let configuration: Configuration
        let highlighted: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .panelTile(highlighted: highlighted || configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PanelTileButtonStyle {
    public static var panelTile: PanelTileButtonStyle { PanelTileButtonStyle() }
    public static func panelTile(highlighted: Bool) -> PanelTileButtonStyle { PanelTileButtonStyle(highlighted: highlighted) }
}

/// A panel row with a title on the left and a switch on the right.
public struct PanelToggle: View {
    private let title: String
    private let isOn: Binding<Bool>

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self.isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }
}

/// The panel under the menu bar icon: the app's content above the standard footer. Like a menu,
/// it never takes focus from the app you're in, so its controls can act on that app (move its
/// window, paste into it), and the first click reaches them.
@MainActor
final class Panel {
    private let window = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private weak var button: NSView?
    private var monitors: [Any] = []
    private var resizeObserver: NSObjectProtocol?
    private var dismissedAt: TimeInterval = 0

    init() {
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onEscape = { [weak self] in self?.close() }
        // The window grows from its bottom edge when the content does; keep it hanging from the icon.
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    /// Opens under `button`, or closes if it's open. The content is built on every open, so it
    /// always reflects the current state.
    func toggle(under button: NSView, content: () -> PanelFrame) {
        guard !window.isVisible else { return close() }
        // The menu bar belongs to another process, so a click on the icon first reaches the
        // monitors below as a click outside, which closed the panel. Don't reopen it.
        guard ProcessInfo.processInfo.systemUptime - dismissedAt > 0.3 else { return }
        self.button = button
        let controller = NSHostingController(rootView: content().background(PanelBackground()))
        controller.sizingOptions = [.preferredContentSize]
        window.contentViewController = controller
        window.setContentSize(controller.view.fittingSize)
        place()
        window.orderFrontRegardless()
        window.makeKey()
        // Any click elsewhere closes it, as it would a menu: in another app, or in this app's other windows.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            },
            NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window !== self.window { self.dismiss() }
                }
                return event
            },
        ].compactMap { $0 }
    }

    private func dismiss() {
        dismissedAt = ProcessInfo.processInfo.systemUptime
        close()
    }

    func close() {
        guard window.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        window.orderOut(nil)
        window.contentViewController = nil
    }

    /// Just under the icon, and inside its screen.
    private func place() {
        guard let button, let iconWindow = button.window, let screen = iconWindow.screen else { return }
        let icon = iconWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let width = window.frame.width, visible = screen.visibleFrame
        let x = min(max(icon.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        window.setFrameTopLeftPoint(CGPoint(x: x, y: icon.minY - 4))
    }
}

private final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// The menu's frosted background, with its rounded corners.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        let radius: CGFloat = 12
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        view.maskImage = mask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The app's panel content above the standard footer: the app's name, Settings, and the menu.
struct PanelFrame: View {
    let content: AnyView
    let needsAccessibility: Bool
    let showSettings: () -> Void
    let showMenu: () -> Void
    @ObservedObject private var status = SystemStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                content
                if needsAccessibility && !status.hasAccessibility {
                    Button("Grant Accessibility Access…", action: Accessibility.grant)
                }
            }
            .padding(16)
            Divider()
            HStack(spacing: 12) {
                Text(AppInfo.name).font(.headline)
                Spacer()
                Button(action: showSettings) { Image(systemName: "gearshape") }.help("Settings…")
                Button(action: showMenu) { Image(systemName: "ellipsis.circle") }.help("More")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .onAppear { status.refresh() }
    }
}
