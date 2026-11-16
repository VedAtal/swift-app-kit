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

/// A panel button drawn as a tile, highlighted while pressed: `.buttonStyle(.panelTile)`.
public struct PanelTileButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .panelTile(highlighted: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PanelTileButtonStyle {
    public static var panelTile: PanelTileButtonStyle { PanelTileButtonStyle() }
}

/// The popover under the menu bar icon: the app's content above the standard footer.
@MainActor
final class Panel {
    private let popover = NSPopover()
    /// The app that was in front when the panel opened, which opening it took focus from.
    private(set) var previousApp: NSRunningApplication?

    init() {
        popover.behavior = .transient
    }

    /// Opens under `button`, or closes if it's open. The content is built on every open, so it
    /// always reflects the current state.
    func toggle(under button: NSView, content: () -> PanelFrame) {
        guard !popover.isShown else { return popover.performClose(nil) }
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        previousApp = NSWorkspace.shared.frontmostApplication
        // Not activate(): macOS may turn that request down, and an inactive panel spends the first
        // click on waking up. Being active is also what lets a click outside close it.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() { popover.performClose(nil) }
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
                    Button("Grant Accessibility Access…") {
                        Accessibility.request()
                        Accessibility.openSettings()
                    }
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
