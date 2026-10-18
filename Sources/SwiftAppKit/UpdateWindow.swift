import AppKit
import SwiftUI

/// What the update window shows. Fed from setup.sh's log while an update runs.
@MainActor
final class UpdateProgress: ObservableObject {
    enum Phase {
        case running, upToDate, updated, failed
    }

    @Published private(set) var phase: Phase = .running
    @Published private(set) var step = "Starting…"
    @Published private(set) var fraction = 0.0
    @Published private(set) var log = ""
    @Published var showsDetails = false

    /// Roughly where each of setup.sh's "==> " steps sits in the whole update. Building takes most
    /// of the time, so it covers the biggest stretch and gets filled in from swift build's
    /// "[n/m]" lines.
    private static let milestones: [(prefix: String, fraction: Double)] = [
        ("Checking", 0.03), ("Downloading", 0.1), ("Building", 0.2),
        ("Assembling", 0.85), ("Signing", 0.9), ("Installing", 0.95), ("Launching", 1.0),
    ]

    var isRunning: Bool { phase == .running }

    var title: String {
        switch phase {
        case .running: "Updating \(AppInfo.name)"
        case .upToDate: "\(AppInfo.name) is up to date"
        case .updated: "\(AppInfo.name) was updated"
        case .failed: "Update failed"
        }
    }

    var detail: String {
        let version = AppInfo.shortCommit ?? "this version"
        switch phase {
        case .running:
            return step
        case .upToDate:
            return "You're running \(version), the newest commit on \(AppInfo.repositoryName ?? "GitHub")."
        case .updated:
            let subject = AppInfo.commitSubject.map { ": “\($0)”" } ?? "."
            return "Now running \(version)\(subject)"
        case .failed:
            return "\(AppInfo.name) is still on the previous version. The details below show what went wrong."
        }
    }

    func start() {
        phase = .running
        step = "Starting…"
        fraction = 0
        log = ""
        showsDetails = false
    }

    func finish(_ phase: Phase) {
        self.phase = phase
        if phase == .failed { showsDetails = true }
    }

    func update(fromLog text: String) {
        guard text != log else { return }
        log = String(text.suffix(20_000))

        let lines = text.split(separator: "\n")
        guard let stepIndex = lines.lastIndex(where: { $0.hasPrefix("==> ") }) else { return }
        step = String(lines[stepIndex].dropFirst(4))

        var estimate = Self.milestones.first { step.hasPrefix($0.prefix) }?.fraction ?? fraction
        if step.hasPrefix("Building"),
           let counter = lines[stepIndex...].last(where: { $0.hasPrefix("[") }),
           let (done, total) = Self.buildCounter(counter), total > 0 {
            estimate = 0.2 + 0.65 * Double(done) / Double(total)
        }
        fraction = max(fraction, min(estimate, 1)) // never move backwards
    }

    /// Parses swift build's "[6 / 8] Compiling…" prefix.
    private static func buildCounter(_ line: Substring) -> (Int, Int)? {
        guard let close = line.firstIndex(of: "]") else { return nil }
        let parts = line[line.index(after: line.startIndex)..<close]
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return (done, total)
    }
}

@MainActor
final class UpdateWindowController {
    let progress = UpdateProgress()
    private lazy var window: AppWindow = AppWindow(title: AppInfo.name, sizesToContent: true) { [weak self, progress] in
        AnyView(UpdateView(
            progress: progress,
            onClose: { [weak self] in self?.window.close() },
            onOpenLog: { NSWorkspace.shared.open(Updater.logURL) }
        ))
    }

    func show() { window.show() }
}

private struct UpdateView: View {
    @ObservedObject var progress: UpdateProgress
    let onClose: () -> Void
    let onOpenLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.title).font(.headline)
                    Text(progress.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if progress.isRunning {
                ProgressView(value: progress.fraction)
            }

            if !progress.log.isEmpty {
                DisclosureGroup("Details", isExpanded: $progress.showsDetails) {
                    logView
                }
            }

            HStack {
                if progress.isRunning {
                    Text("You can close this window. The update keeps going.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if progress.phase == .failed {
                    Button("Open Log", action: onOpenLog)
                }
                Button(progress.isRunning ? "Hide" : "OK", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(progress.log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(8)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: progress.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .padding(.top, 6)
    }
}
