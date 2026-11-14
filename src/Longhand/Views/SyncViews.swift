import SwiftUI
import AppKit

extension SyncStatus {
    /// The one line that says where the library stands against its remote, in Git's own words.
    /// `unpushed` is true while any branch or tag has commits the remote lacks.
    func line(hasRemote: Bool, unpushed: Bool) -> (text: String, warn: Bool) {
        guard hasRemote else { return ("Only on this Mac", false) }
        switch activity {
        case .committing: return ("Committing…", false)
        case .pushing: return ("Pushing…", false)
        case .fetching: return ("Fetching…", false)
        case .pulling: return ("Pulling…", false)
        case .idle: break
        }
        switch problem {
        case .offline: return (unpushed ? "Offline, commits waiting" : "Offline", true)
        case .authentication: return (onGitHub ? "GitHub sign-in failed" : "Sign-in failed", true)
        case .diverged: return ("Diverged from \(place)", true)
        case .other: return ("Push failed", true)
        case nil: break
        }
        if unpushed { return (ahead == 1 ? "1 commit to push" : ahead > 1 ? "\(ahead) commits to push" : "Commits to push", true) }
        if let lastPush { return ("Pushed \(lastPush.formatted(date: .omitted, time: .shortened))", false) }
        return ("Up to date with \(place)", false)
    }

    /// What the problem is and what happens next, in a sentence.
    var explanation: String? {
        switch problem {
        case .offline:
            return "\(Place) can’t be reached. Longhand keeps committing on this Mac and pushes when \(onGitHub ? "the connection returns" : "it can")."
        case .authentication:
            return onGitHub
                ? "GitHub refused the sign-in. Run “gh auth login” in Terminal, then choose Push."
                : "The remote refused the sign-in. Check this Mac’s SSH key, or the password saved in Keychain, then choose Push."
        case .diverged:
            return "This Mac and \(place) have both changed the same lines. Keep Both pushes this Mac’s commits and keeps \(onGitHub ? "GitHub’s" : "the remote’s") as a branch to compare and merge."
        case .other(let message):
            return message
        case nil:
            return nil
        }
    }
}

/// The foot of the window, far right: where the library stands against GitHub ("Pushed
/// 14:32", "2 to push", "Offline"), and a button that pushes now. Click the words for Git
/// Activity. Watches only the sync status and the change state.
struct SyncItem: View {
    @ObservedObject var versions: VersionStore
    @ObservedObject var sync: SyncStatus
    @ObservedObject var changes: ChangeState

    /// Dev switch for pictures: `LONGHAND_BACKUP_DEMO=1` shows it at rest, `=busy` turning.
    private static let demo = ProcessInfo.processInfo.environment["LONGHAND_BACKUP_DEMO"]

    private var hasRemote: Bool { changes.backup != .none || Self.demo != nil }
    private var busy: Bool { sync.activity != .idle || Self.demo == "busy" }

    var body: some View {
        let line: (text: String, warn: Bool) = Self.demo == nil
            ? sync.line(hasRemote: hasRemote, unpushed: changes.backup == .behind)
            : (Self.demo == "busy" ? "Pushing…" : "Pushed 14:32", false)
        HStack(spacing: 4) {
            Button { versions.sheet = .backup } label: {
                Text(line.text)
                    .foregroundStyle(Color(line.warn ? PaperTheme.accent : PaperTheme.secondary))
                    .lineLimit(1)
                    .boxed(height: 18, padding: 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasRemote ? tooltip : "Commits are kept only on this Mac. Click to connect a repository.")
            if hasRemote {
                Button {
                    if !busy { versions.syncNow() }
                } label: {
                    Group {
                        if busy {
                            Symbol.syncing.view(size: 10, weight: .semibold)
                                .symbolEffect(.rotate, options: .repeat(.continuous))
                        } else {
                            Symbol.upload.view(size: 10, weight: .semibold)
                        }
                    }
                    .foregroundStyle(Color(line.warn && !busy ? PaperTheme.accent : PaperTheme.secondary))
                    .frame(width: 22, height: 18)
                    .background(Color(PaperTheme.controlFill), in: rounded(Layout.smallRadius + 1))
                    .overlay(rounded(Layout.smallRadius + 1).strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sync with \(sync.place) now")
            }
        }
        .fixedSize()
    }

    private var tooltip: String {
        var lines: [String] = []
        if let date = sync.lastCommit { lines.append("Last commit \(time(date))") }
        if let date = sync.lastPush { lines.append("Last push \(time(date))") }
        if let date = sync.lastFetch { lines.append("Last fetch \(time(date))") }
        if let explanation = sync.explanation { lines.append(explanation) }
        lines.append("Click for Git Activity")
        return lines.joined(separator: "\n")
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

/// Git Activity: the repository, the branch, when the last commit, push and fetch happened,
/// what is wrong if anything, and every Git command the sync ran with Git's answer.
struct GitActivity: View {
    @EnvironmentObject private var versions: VersionStore
    @ObservedObject var sync: SyncStatus
    @ObservedObject var changes: ChangeState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let line = sync.line(hasRemote: true, unpushed: changes.backup == .behind)
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                SheetRow(label: "Repository") {
                    value(versions.backupPage.map { $0.replacingOccurrences(of: "https://github.com/", with: "") } ?? versions.remoteAddress ?? "origin")
                        .textSelection(.enabled)
                }
                SheetRow(label: "Branch") { value(versions.currentRewrite?.id ?? "main") }
                SheetRow(label: "Status") {
                    Text(line.text)
                        .font(.system(size: Layout.chromeSize, weight: .medium))
                        .foregroundStyle(Color(line.warn ? PaperTheme.accent : PaperTheme.ink))
                }
            }
            if let explanation = sync.explanation { SheetNote(explanation, accent: true) }
            log
            SheetButtons {
                if sync.activity != .idle { ProgressView().controlSize(.small) }
                if versions.backupPage != nil {
                    Button("View on GitHub") { versions.openBackupPage() }
                        .buttonStyle(SquareButtonStyle())
                }
                if sync.problem == .diverged {
                    Button("Keep Both") { versions.keepBoth() }
                        .buttonStyle(SquareButtonStyle())
                        .disabled(sync.activity != .idle)
                        .help("Push this Mac’s commits and keep \(sync.onGitHub ? "GitHub’s" : "the remote’s") as a branch")
                } else {
                    Button("Fetch") { versions.syncNow() }
                        .buttonStyle(SquareButtonStyle())
                        .disabled(sync.activity != .idle)
                        .help("Fetch from \(sync.place) and pull any new commits")
                    Button("Push") { versions.commitAndPush() }
                        .buttonStyle(SquareButtonStyle())
                        .disabled(sync.activity != .idle)
                        .help("Commit any changes, then push to \(sync.place)")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SquareButtonStyle(primary: true))
            }
        }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if sync.log.isEmpty {
                        Text("No Git activity yet")
                            .font(.system(size: Layout.detailSize))
                            .foregroundStyle(Color(PaperTheme.secondary))
                    }
                    ForEach(sync.log) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(Color(PaperTheme.secondary))
                                    .frame(width: 64, alignment: .leading)
                                Text(entry.command)
                                    .foregroundStyle(Color(PaperTheme.ink))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(entry.ok ? "OK" : "Failed")
                                    .foregroundStyle(Color(entry.ok ? PaperTheme.secondary : PaperTheme.accent))
                            }
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .foregroundStyle(Color(PaperTheme.secondary))
                                    .lineLimit(4)
                                    .padding(.leading, 72)
                                    .textSelection(.enabled)
                            }
                        }
                        .font(.system(size: Layout.detailSize, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 120)
            .background(Color(PaperTheme.controlFill), in: rounded(Layout.radius))
            .overlay(rounded(Layout.radius).strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
        }
        .padding(.top, 12)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(Color(PaperTheme.ink))
    }
}
