# swift-app-kit

The shared parts of my macOS menu bar apps ([Recall](https://github.com/VedAtal/recall),
[Snap](https://github.com/VedAtal/snap)): one install script, one menu layout, one Settings
window style, one icon style, and the plumbing every app needs. Each app keeps only its own logic.

The rules the apps follow are in [STANDARDS.md](STANDARDS.md).

## What's in it

| Piece | What it gives an app |
|---|---|
| `scripts/setup.sh` | The whole install: build, app icon, Info.plist, code signing, install, launch, update from GitHub, uninstall |
| `scripts/make-icon.swift` | The app icon: a white SF Symbol on a gradient rounded square |
| `MenuBarApp`, `MenuBarAppDelegate` | Menu-bar-only startup, the standard menu, Settings window, launch at login on first run, the update flow |
| `SettingsForm`, `ShortcutField` | The standard Settings layout (the app's sections, then General) and a shortcut recorder |
| `HotKeyCenter`, `Shortcut` | Any number of global shortcuts, plus pausing them and reporting ones another app already has |
| `Updater` | "Update &lt;App&gt;": reinstalls the latest commit from GitHub, with a progress window |
| `Accessibility`, `LoginItem`, `AppInfo` | Permission checks, the login item, and the app's name, symbol, and version |
| `AppWindow`, `NSMenu.addItem(…)` | A standard window for SwiftUI content, and closure-based menu items |
| `templates/` | The `setup.sh` every app copies unchanged, and a sample `app.env` |

## Making a new app

1. Create the app's repo with this layout:

   ```
   Package.swift      depends on swift-app-kit (below)
   app.env            name, bundle ID, symbol, icon colors (copy templates/app.env)
   setup.sh           copy templates/setup.sh exactly, and chmod +x it
   Sources/<App>/
     main.swift       MenuBarApp.run(AppDelegate())
     AppDelegate.swift
   ```

2. In `Package.swift`, depend on this repo, and name the executable product the same as
   `APP_NAME`:

   ```swift
   dependencies: [
       .package(url: "https://github.com/VedAtal/swift-app-kit.git", branch: "main")
   ],
   targets: [
       .executableTarget(
           name: "Example",
           dependencies: [.product(name: "SwiftAppKit", package: "swift-app-kit")],
           path: "Sources/Example"
       )
   ]
   ```

3. Subclass `MenuBarAppDelegate`:

   ```swift
   import SwiftAppKit
   import SwiftUI

   final class AppDelegate: MenuBarAppDelegate {
       override func start() { /* set up the app */ }
       override func addMenuItems(to menu: NSMenu) { menu.addItem("Do Something") { … } }
       override func makeSettingsView() -> AnyView { AnyView(SettingsForm { Section("Example") { … } }) }
       override var needsAccessibility: Bool { false }
   }
   ```

4. Run `./setup.sh --local`. Commit `Package.resolved`. It pins the exact version of the kit.

## Changing the kit

Apps use the kit version pinned in their `Package.resolved`, so pushing here changes nothing
until an app picks it up. To work on the kit and an app together:

```sh
cd ~/projects/recall
swift package edit swift-app-kit --path ../swift-app-kit   # build against your local kit folder
./setup.sh --local                                         # try it
```

When it works, push the kit, then in each app:

```sh
swift package unedit swift-app-kit   # back to the GitHub version
swift package update swift-app-kit   # move the pin to the kit's latest commit
git commit -am "update swift-app-kit"
```

Once that app commit is on GitHub, the app's "Update" menu item installs it.

## How setup.sh fits together

```
<app>/setup.sh  (templates/setup.sh, identical in every app)
  ├─ checks Swift is installed
  ├─ swift package resolve        downloads the kit at the pinned version
  └─ runs <kit>/scripts/setup.sh with APP_ROOT=<app>
       └─ reads <app>/app.env and does the rest
```

Every build copies `scripts/setup.sh` and `app.env` into the app's `Contents/Resources`. The
app's **Update** menu item runs that copy, which downloads the app's latest commit and runs
*its* `setup.sh --local`. So an update always uses the install steps from the version being
installed.

**Signing.** Each app gets its own self-signed certificate, in
`~/Library/Keychains/<app>-codesign.keychain-db`. macOS ties the Accessibility permission to
the signature, and an ad-hoc signature changes on every build, so without this you'd have to
grant access again after each update.

**Build tools.** Everything builds with only the Command Line Tools. Full Xcode isn't needed.
