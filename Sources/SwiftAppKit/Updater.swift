import AppKit

/// "Update <App>": runs the copy of swift-app-kit's setup.sh bundled in the app, in its default
/// mode, which downloads the latest version from GitHub and installs it. Progress shows in the
/// update window. On success, setup.sh quits this copy and launches the new build with
/// --updated, and the new build shows the result.
@MainActor
public final class Updater {
    public var isUpdating: Bool { process != nil }

    private var process: Process?
    private var logTimer: Timer?
    private let window = UpdateWindowController()

    public init() {}

    static var logURL: URL { AppInfo.logDirectory.appendingPathComponent("update.log") }

    /// Starts an update, or brings the progress window back if one is already running.
    public func update() {
        guard !isUpdating else {
            window.show()
            return
        }
        guard let repositoryURL = AppInfo.repositoryURL,
              let script = Bundle.main.url(forResource: "setup", withExtension: "sh") else {
            showAlert("This copy of \(AppInfo.name) doesn't know where to get updates",
                      info: "It was built from a folder with no GitHub remote. Run setup.sh from a clone of the repository once, and Update \(AppInfo.name) will work from then on.")
            return
        }

        let log: FileHandle
        do {
            try FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: Self.logURL)
        } catch {
            showAlert("Couldn't start the update", info: error.localizedDescription)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        // The bundled script isn't in a git checkout, so tell it which repo to install from, and
        // that it should relaunch the app with --updated when it's done.
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SETUP_REPO": repositoryURL,
            "SETUP_FROM_APP": "1",
        ]) { $1 }
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        // Output goes to a file, not a pipe. setup.sh quits this app partway through, and writing
        // to a pipe nobody is reading anymore would kill the script.
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.finished(status: status) }
        }

        do {
            try process.run()
        } catch {
            showAlert("Couldn't start the update", info: error.localizedDescription)
            return
        }
        self.process = process
        window.progress.start()
        window.show()

        // The script's output is the progress report: follow the log as it grows.
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLog() }
        }
        RunLoop.main.add(timer, forMode: .common)
        logTimer = timer
    }

    /// Called at launch when setup.sh started this copy with --updated.
    public func showUpdateResult() {
        window.progress.finish(.updated)
        window.show()
    }

    private func readLog() {
        window.progress.update(fromLog: (try? String(contentsOf: Self.logURL, encoding: .utf8)) ?? "")
    }

    private func finished(status: Int32) {
        process = nil
        logTimer?.invalidate()
        logTimer = nil
        readLog()
        // A successful install quits this copy before the script exits. So if we're still here,
        // either the script found nothing newer (exit 0) or it failed. Either way, this version is
        // still the one running.
        window.progress.finish(status == 0 ? .upToDate : .failed)
        window.show()
    }

    private func showAlert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        NSApp.activate()
        alert.runModal()
    }

}
