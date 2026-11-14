import SwiftUI
import AppKit

/// File › Commit…, Create Tag… and Publish Repository… / Git Activity…, one sheet each.
struct VersionSheet: View {
    @EnvironmentObject private var versions: VersionStore
    let kind: VersionStore.Sheet

    var body: some View {
        Group {
            switch kind {
            case .save: SaveVersionSheet()
            case .draft: DraftSheet()
            case .backup: BackupSheet()
            case .rewrite: StartRewriteSheet()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 520)
        .background(Color(PaperTheme.paper))
    }
}

// MARK: - Save Version

private struct SaveVersionSheet: View {
    @EnvironmentObject private var versions: VersionStore
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var unchanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle("Commit")
            SheetField(label: "Summary", placeholder: "Ch 7: cut the flashback", text: $note)
                .help("What changed in this commit")
            if unchanged {
                SheetNote("No scene has changed since your last commit.", accent: true)
            }
            RecentVersions(points: versions.recent)
            SheetButtons {
                Button(unchanged ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Commit") {
                    versions.save(note: note) { saved in
                        if saved { dismiss() } else { unchanged = true }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SquareButtonStyle(primary: true))
                .disabled(versions.busy || !versions.available)
            }
        }
    }
}

// MARK: - Mark as Draft

private struct DraftSheet: View {
    @EnvironmentObject private var versions: VersionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle("New Tag")
            VStack(spacing: 12) {
                SheetField(label: "Name", placeholder: versions.nextDraftName, text: $name)
                    .help("A name for this point in the work, such as Second draft or Sent to editor")
                SheetField(label: "Message", placeholder: "Optional", text: $note)
            }
            if let failure { SheetNote(failure, accent: true) }
            RecentVersions(points: versions.recent)
            SheetButtons {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Create Tag") {
                    versions.markDraft(name: name, note: note) { problem in
                        if let problem { failure = problem } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SquareButtonStyle(primary: true))
                .disabled(versions.busy || !versions.available)
            }
        }
        .onAppear { if name.isEmpty { name = versions.nextDraftName } }
    }
}

// MARK: - Back Up to GitHub

private struct BackupSheet: View {
    @EnvironmentObject private var versions: VersionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failure: String?
    @State private var host: RemoteHost = .gitHub
    @State private var address = ""
    @State private var folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(versions.hasBackup ? "Git Activity" : "Connect Repository")
            if versions.hasBackup {
                existing
            } else {
                setup
            }
        }
        .onAppear {
            // Pictures: LONGHAND_REMOTE=other|folder opens on that choice.
            switch ProcessInfo.processInfo.environment["LONGHAND_REMOTE"] {
            case "other": host = .other
            case "folder": host = .folder
            default: break
            }
            if name.isEmpty { name = versions.suggestedRepositoryName }
            if !versions.hasBackup { versions.loadAccounts() }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                SheetRow(label: "Remote") {
                    SquareSegments(options: RemoteHost.allCases, title: \.title, selection: $host)
                }
                switch host {
                case .gitHub: gitHubFields
                case .other:
                    SheetField(label: "Address", placeholder: "git@example.com:you/novel.git", text: $address)
                        .help("Any Git remote this Mac can sign in to: SSH with a key, or HTTPS with a password saved in Keychain. An empty repository.")
                case .folder:
                    SheetRow(label: "Folder") {
                        FolderChoice(folder: folder) {
                            folder = chooseFolder(prompt: "Choose",
                                                  message: "Choose a folder on this Mac or a drive. Longhand makes “\(versions.suggestedRepositoryName).git” in it and pushes there.")
                        }
                    }
                    .help("A repository in a folder on this Mac or an external drive: \(versions.suggestedRepositoryName).git")
                }
            }
            if let failure { SheetNote(failure, accent: true) }
            SheetButtons {
                if versions.busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Connect") {
                    failure = nil
                    switch host {
                    case .gitHub: versions.createBackup(name: name.isEmpty ? versions.suggestedRepositoryName : name) { failure = $0 }
                    case .other: versions.connectRemote(address: address) { failure = $0 }
                    case .folder: if let folder { versions.connectFolder(folder) { failure = $0 } }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SquareButtonStyle(primary: true))
                .disabled(versions.busy || !versions.available
                          || (host == .other && address.trimmingCharacters(in: .whitespaces).isEmpty)
                          || (host == .folder && folder == nil))
                .help(host == .gitHub
                      ? "Creates a private repository on GitHub and pushes every commit, branch and tag to it"
                      : "Pushes every commit, branch and tag to this remote")
            }
        }
    }

    @ViewBuilder private var gitHubFields: some View {
                SheetRow(label: "Account") {
                    if versions.accounts.count > 1 {
                        SquareSegments(options: versions.accounts, title: \.self, selection: Binding(
                            get: { versions.account },
                            set: { versions.account = $0 }
                        ))
                        .help("The GitHub account that owns the repository")
                    } else {
                        Text(versions.account.isEmpty ? "Sign in with “gh auth login” in Terminal" : versions.account)
                            .font(.system(size: Layout.chromeSize))
                            .foregroundStyle(Color(PaperTheme.ink))
                    }
                }
                SheetField(label: "Name", placeholder: versions.suggestedRepositoryName, text: $name)
    }

    private var existing: some View {
        GitActivity(sync: versions.sync, changes: versions.changes)
    }
}

/// Where a repository lives: on GitHub (through GitHub's own tool), or at any Git address.
enum RemoteHost: CaseIterable {
    case gitHub, other, folder
    var title: String {
        switch self {
        case .gitHub: return "GitHub"
        case .other: return "Another Remote"
        case .folder: return "Folder"
        }
    }
}

/// Choosing a folder on this Mac or a drive; nil if cancelled.
@MainActor func chooseFolder(prompt: String, message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = prompt
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
}

/// A chosen folder's path in a sheet, with Choose… beside it.
struct FolderChoice: View {
    let folder: URL?
    let choose: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "A folder on this Mac or a drive")
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(folder == nil ? PaperTheme.secondary : PaperTheme.ink))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Choose…", action: choose).buttonStyle(SquareButtonStyle())
        }
    }
}

// MARK: - Recent versions

private struct RecentVersions: View {
    @EnvironmentObject private var versions: VersionStore
    let points: [VersionStore.SavePoint]

    var body: some View {
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1).padding(.vertical, 18)
                Text("Recent commits")
                    .font(.system(size: Layout.detailSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .padding(.bottom, 8)
                ForEach(points.prefix(6)) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(when(point.date))
                            .foregroundStyle(Color(PaperTheme.secondary))
                            .frame(width: 128, alignment: .leading)
                        Text(point.note)
                            .foregroundStyle(Color(PaperTheme.ink))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        ForEach(point.drafts, id: \.self) { draft in
                            Text(draft)
                                .font(.system(size: Layout.detailSize, weight: .medium))
                                .foregroundStyle(Color(PaperTheme.ink))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
                        }
                    }
                    .font(.system(size: Layout.detailSize))
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func when(_ date: Date) -> String {
        Moment.text(date)
    }
}

// MARK: - Get Library from GitHub

/// From the welcome screen: choose an account and one of its libraries, then where to keep
/// it on this Mac. The library arrives with all its versions and stays backed up there.
struct GetLibrarySheet: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var versions: VersionStore
    @Environment(\.dismiss) private var dismiss
    /// Names to show without asking GitHub (pictures only).
    var preview: [String]?
    @State private var names: [String]?
    @State private var loading = false
    @State private var chosen: String?
    @State private var busy = false
    @State private var failure: String?
    @State private var host: RemoteHost = .gitHub
    @State private var address = ""
    @State private var repository: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(host == .gitHub ? "Clone from GitHub" : "Clone a Repository")
            SheetRow(label: "Remote") {
                SquareSegments(options: RemoteHost.allCases, title: \.title, selection: $host)
            }
            .padding(.bottom, 12)
            switch host {
            case .gitHub: gitHubChoice
            case .other:
                SheetField(label: "Address", placeholder: "git@example.com:you/novel.git", text: $address)
                    .help("Any Git remote this Mac can sign in to: SSH with a key, or HTTPS with a password saved in Keychain.")
            case .folder:
                SheetRow(label: "Repository") {
                    FolderChoice(folder: repository) {
                        repository = chooseFolder(prompt: "Choose", message: "Choose the repository (a folder ending in .git) on this Mac or a drive.")
                    }
                }
            }
            if let failure { SheetNote(failure, accent: true) }
            SheetButtons {
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Clone…") { fetch() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SquareButtonStyle(primary: true))
                    .disabled(busy || {
                        switch host {
                        case .gitHub: return chosen == nil
                        case .other: return address.trimmingCharacters(in: .whitespaces).isEmpty
                        case .folder: return repository == nil
                        }
                    }())
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 520)
        .background(Color(PaperTheme.paper))
        .onAppear {
            if let preview {
                names = preview
                chosen = preview.first
            } else {
                versions.loadAccounts { load() }
            }
        }
    }

    @ViewBuilder private var gitHubChoice: some View {
            SheetRow(label: "Account") {
                if versions.accounts.count > 1 {
                    SquareSegments(options: versions.accounts, title: \.self, selection: Binding(
                        get: { versions.account },
                        set: { versions.account = $0; load() }
                    ))
                } else {
                    Text(versions.account.isEmpty ? "Sign in with “gh auth login” in Terminal" : versions.account)
                        .font(.system(size: Layout.chromeSize))
                        .foregroundStyle(Color(PaperTheme.ink))
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Text("Library")
                    .font(.system(size: Layout.chromeSize))
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .frame(width: Layout.sheetLabel, alignment: .leading)
                    .padding(.top, 6)
                list
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            ProgressView().controlSize(.small)
        } else if let names, !names.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(names, id: \.self) { name in
                        Button { chosen = name } label: {
                            Text(name)
                                .font(.system(size: Layout.chromeSize, weight: name == chosen ? .medium : .regular))
                                .foregroundStyle(Color(PaperTheme.ink))
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                .background(rounded(Layout.rowRadius).fill(Color(name == chosen ? PaperTheme.selection : .clear)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(height: 176)
            .background(Color(PaperTheme.card))
            .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
        } else {
            Text(names == nil
                 ? (versions.account.isEmpty ? "Sign in to GitHub first: run “gh auth login” in Terminal." : "This Mac isn’t signed in to GitHub as \(versions.account).")
                 : "This account has no repositories yet.")
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.secondary))
        }
    }

    private func load() {
        let owner = versions.account
        loading = true
        chosen = nil
        failure = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let found = GitHub.repositories(owner: owner)
            Task { @MainActor in
                guard owner == versions.account else { return }
                names = found
                loading = false
            }
        }
    }

    private func fetch() {
        let other = host != .gitHub
        let typed = host == .folder ? (repository?.path ?? "") : address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = other ? Git.repositoryName(of: typed) : chosen else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Keep Here"
        panel.message = "Choose where to keep “\(name)”. Longhand makes a folder for it there."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let remote = other ? typed : GitHub.remote(owner: versions.account, name: name)
        busy = true
        failure = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Git.fetchLibrary(from: remote, named: name, into: parent)
            Task { @MainActor in
                busy = false
                if let folder = result.folder {
                    dismiss()
                    store.openLibrary(at: folder)
                } else {
                    failure = result.problem
                }
            }
        }
    }
}

// MARK: - Parts

private struct SheetTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Color(PaperTheme.ink))
            .padding(.bottom, 18)
    }
}

struct SheetRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.secondary))
                .frame(width: Layout.sheetLabel, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }
}

private struct SheetField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SheetRow(label: label) {
            TextField(placeholder, text: $text, prompt: .placeholder(placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.ink))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color(PaperTheme.card))
                .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
        }
    }
}

struct SheetNote: View {
    let text: String
    var accent = false
    init(_ text: String, accent: Bool = false) {
        self.text = text
        self.accent = accent
    }

    var body: some View {
        Text(text)
            .font(.system(size: Layout.detailSize))
            .foregroundStyle(Color(accent ? PaperTheme.accent : PaperTheme.secondary))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 104)
            .padding(.top, 12)
    }
}

struct SheetButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            content
        }
        .padding(.top, 22)
    }
}
