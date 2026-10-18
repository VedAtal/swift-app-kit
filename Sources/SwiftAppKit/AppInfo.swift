import Foundation

/// What the app knows about itself. setup.sh writes all of this into Info.plist from the app's
/// app.env and from git, so there's one place to change it.
public enum AppInfo {
    /// e.g. "Recall".
    public static var name: String {
        infoString("CFBundleName") ?? ProcessInfo.processInfo.processName
    }

    /// The SF Symbol used for the menu bar icon and the app icon.
    public static var symbol: String { infoString("AppSymbol") ?? "app" }

    /// Where updates come from: the HTTPS URL of the repo this copy was built from.
    public static var repositoryURL: String? { infoString("AppRepositoryURL") }

    /// The commit this copy was built from, with a "-dirty" suffix if it had uncommitted changes.
    public static var commit: String? { infoString("AppCommit") }

    public static var commitSubject: String? { infoString("AppCommitSubject") }

    public static var buildDate: Date? {
        infoString("AppBuildDate").flatMap { try? Date($0, strategy: .iso8601) }
    }

    /// "github.com/owner/repo", for display.
    public static var repositoryName: String? {
        repositoryURL.map {
            $0.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: ".git", with: "", options: [.anchored, .backwards])
        }
    }

    /// e.g. "59ba24f", or "59ba24f (modified)" for a --local build with uncommitted changes.
    public static var shortCommit: String? {
        commit.map { String($0.prefix(7)) + ($0.hasSuffix("-dirty") ? " (modified)" : "") }
    }

    /// e.g. "Version 59ba24f · built 5 minutes ago".
    public static var versionDescription: String? {
        let built = buildDate.map { "built \($0.formatted(.relative(presentation: .named)))" }
        guard let shortCommit else { return built.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        return ["Version \(shortCommit)", built].compactMap { $0 }.joined(separator: " · ")
    }

    /// ~/Library/Logs/<name>. setup.sh --uninstall removes it.
    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(name)", isDirectory: true)
    }

    private static func infoString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
