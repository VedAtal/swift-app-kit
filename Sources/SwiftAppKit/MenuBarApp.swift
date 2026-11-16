import AppKit
import ServiceManagement
import SwiftUI

/// Starts a menu-bar-only app (no Dock icon). Call it from main.swift:
///
///     MenuBarApp.run(AppDelegate())
@MainActor
public enum MenuBarApp {
    private static var delegate: MenuBarAppDelegate? // NSApplication only keeps a weak reference

    public static func run(_ delegate: MenuBarAppDelegate) -> Never {
        // `setup.sh --uninstall` runs the binary with this flag so the login item goes away with the app.
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        self.delegate = delegate
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }
}

/// The standard app shell: menu bar icon and menu, Settings window, updates, launch at login.
/// Subclass it and override the `open` members to add the app's own parts. The menu is laid out
/// the same in every app:
///
///     <app items>                    addMenuItems(to:)
///     ───────────
///     Grant Accessibility Access…    only while needsAccessibility and it isn't granted
///     Launch at Login
///     Settings…                ⌘,
///     ───────────
///     Update <App>
///     Version 59ba24f · built 2 minutes ago
///     Quit <App>               ⌘Q
///
/// An app with more controls than a menu holds overrides `makePanelView()`. Its icon then opens a
/// panel, and the menu moves to a right-click and the panel's footer.
@MainActor
open class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public let updater = Updater()
    public private(set) var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private lazy var panel = Panel()
    private lazy var settingsWindow: AppWindow = AppWindow(title: "\(AppInfo.name) Settings") { [unowned self] in
        makeSettingsView()
    }

    override public init() {
        super.init()
    }

    // MARK: For subclasses

    /// Called once at launch, after the menu bar icon exists. Set up the app here.
    open func start() {}

    /// Adds the app's own items to the top of the menu. Called every time the menu opens.
    open func addMenuItems(to menu: NSMenu) {}

    /// The panel the menu bar icon opens instead of the menu, usually a stack of PanelSections.
    /// Called every time the panel opens. Return nil (the default) to keep the menu.
    open func makePanelView() -> AnyView? { nil }

    /// The Settings window's content, usually a SettingsForm.
    open func makeSettingsView() -> AnyView {
        AnyView(SettingsForm(needsAccessibility: needsAccessibility) {})
    }

    /// Whether the app currently needs Accessibility access. If it does and access is missing,
    /// the app asks at launch and the menu shows "Grant Accessibility Access…".
    open var needsAccessibility: Bool { false }

    // MARK: Shared behavior

    public func showSettings() { settingsWindow.show() }

    /// Closes the panel, for a panel control that takes over the screen or opens a window.
    public func closePanel() { panel.close() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The app's own glyph (GLYPH in app.env), else its SF Symbol. As a template image, it follows
        // the menu bar's light or dark appearance.
        let image = Bundle.main.image(forResource: "Glyph").map { glyph in
            glyph.size = NSSize(width: 16 * glyph.size.width / glyph.size.height, height: 16)
            glyph.accessibilityDescription = AppInfo.name
            return glyph
        } ?? NSImage(systemSymbolName: AppInfo.symbol, accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        statusItem.button?.image = image
        menu.delegate = self

        start()
        if makePanelView() == nil {
            statusItem.menu = menu
        } else {
            statusItem.button?.target = self
            statusItem.button?.action = #selector(statusItemClicked)
            statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        enableLaunchAtLoginOnFirstRun()

        // setup.sh relaunches the app with this flag after an update from the menu.
        if CommandLine.arguments.contains("--updated") {
            updater.showUpdateResult()
        }
        if needsAccessibility && !Accessibility.isGranted {
            Accessibility.requestOnce()
        }
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.close()
            // A status item only places its menu under the icon while the menu is assigned to it.
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
            return
        }
        panel.toggle(under: button) {
            PanelFrame(
                content: makePanelView() ?? AnyView(EmptyView()), needsAccessibility: needsAccessibility,
                showSettings: { [weak self] in
                    self?.panel.close()
                    self?.showSettings()
                },
                showMenu: { [weak self] in
                    guard let self else { return }
                    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                }
            )
        }
    }

    // Opening the app again (Finder, Spotlight) while it's running shows Settings.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // Rebuilt every time it opens, so it always reflects the current state.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addMenuItems(to: menu)
        if !menu.items.isEmpty { menu.addItem(.separator()) }

        if needsAccessibility && !Accessibility.isGranted {
            menu.addItem("Grant Accessibility Access…", action: Accessibility.grant)
        }
        menu.addItem("Launch at Login") {
            do {
                try LoginItem.setEnabled(!LoginItem.isEnabled)
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
            }
        }.state = LoginItem.isEnabled ? .on : .off
        menu.addItem("Settings…", key: ",") { [weak self] in self?.showSettings() }

        menu.addItem(.separator())
        // While an update runs, the same item brings its progress window back.
        let update = menu.addItem(updater.isUpdating ? "Updating \(AppInfo.name)…" : "Update \(AppInfo.name)") { [weak self] in
            self?.updater.update()
        }
        update.toolTip = updater.isUpdating
            ? "Show update progress"
            : AppInfo.repositoryName.map { "Download the latest from \($0) and reinstall" }
        if let version = AppInfo.versionDescription {
            menu.addDisabledItem(version)
        }
        menu.addItem("Quit \(AppInfo.name)", key: "q") { NSApp.terminate(nil) }
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "configuredLoginItem"
        // Only the installed copy, so running a dev build doesn't add a login item.
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.contains("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? LoginItem.setEnabled(true)
    }
}
