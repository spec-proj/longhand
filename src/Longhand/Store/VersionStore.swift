import Foundation
import AppKit

/// Save points for the whole library, kept by Git in the library's own `.git` folder.
///
/// - **Save Version…** records every file in the library as it is now, with a note.
/// - Closing the library or quitting records one automatically if anything changed.
/// - **Mark as Draft…** saves a version and names it (`draft-2`), so a finished draft or the
///   text sent to an editor can always be found again.
/// - **Back Up to GitHub…** creates a private repository and sends every version there; after
///   that each new version is sent on its own.
///
/// The ten-minute autosaves of each scene are separate and keep working (see `HistoryStore`).
/// All Git work runs on one serial queue, so two commands never fight over Git's lock file.
@MainActor
final class VersionStore: ObservableObject {
    struct SavePoint: Identifiable, Equatable, Sendable {
        let id: String
        let date: Date
        let note: String
        let drafts: [String]
    }

    enum Sheet: String, Identifiable {
        case save, draft, backup, rewrite
        var id: String { rawValue }
    }

    @Published private(set) var recent: [SavePoint] = []
    /// `https://github.com/owner/name`, once the library is backed up.
    @Published private(set) var backupPage: String?
    /// The remote's address as Git has it (any host), once read.
    var remoteAddress: String? { remoteRead ? remoteCache : nil }
    /// True once the library has somewhere to send versions (GitHub, or any Git remote).
    @Published private(set) var hasBackup = false
    /// The backup address, read once per library (and again after a backup is set up).
    private var remoteCache: String?
    private var remoteRead = false
    @Published private(set) var lastBackup: Date?
    /// True while versions are on their way to the backup (the status bar's button turns).
    @Published private(set) var backingUp = false
    @Published private(set) var backupFailed = false {
        didSet { if backupFailed != oldValue { scheduleChanges(after: 0) } }
    }
    @Published private(set) var busy = false
    @Published private(set) var available = false
    @Published var sheet: Sheet?

    /// The comparison shown in place of the page (File › Compare Versions…).
    @Published var comparing = false {
        didSet { if !comparing { detail = nil } }
    }
    /// One scene from the comparison, shown whole.
    @Published var detail: Comparison.SceneChange?
    @Published private(set) var allPoints: [SavePoint] = []
    @Published private(set) var draftTitles: [String: String] = [:]
    /// The older side: a version's commit id.
    @Published private(set) var compareFrom: String?
    /// The newer side: a version's commit id, or nil for the library as it is now.
    @Published private(set) var compareTo: String?
    @Published private(set) var comparison: Comparison?
    @Published private(set) var comparingBusy = false
    /// Branch tips other than the one open, for comparing the manuscript with a rewrite.
    @Published private(set) var branchTips: [(title: String, id: String)] = []

    /// The rewrite open, or nil on the main manuscript.
    @Published private(set) var currentRewrite: Rewrite? {
        didSet { if changes.branch != currentRewrite?.title { changes.branch = currentRewrite?.title } }
    }
    @Published private(set) var rewrites: [Rewrite] = []
    /// Keeping a rewrite whose changes meet the manuscript's: the passages to choose.
    @Published var mergePlan: MergePlan?

    /// Keep or Discard This Rewrite, waiting to be confirmed.
    @Published var confirm: Confirm?
    enum Confirm: Identifiable { case keep, discard; var id: Self { self } }

    /// The GitHub account that owns new backups: the one chosen in a sheet, else the first one
    /// signed in on this Mac (never a built-in name: other people's Macs have their own).
    static let accountKey = "githubAccount"

    /// What changed since the last version (status bar, contents, Versions tab, page bars).
    let changes = ChangeState()

    /// One scene, in the page, compared with its last version (from the Versions tab, or a
    /// change bar on the page).
    func showSceneChanges(_ scene: URL) {
        guard let relative = changes.relative(scene), let last = changes.lastVersion(of: scene) else { return }
        openScene(relative, from: last.commit, label: last.shortID)
    }

    /// What the older side is called in a scene comparison ("v3"), when opened from a scene's
    /// history; nil for library-wide comparisons.
    @Published var compareLabel: String?
    private var changesTask: Task<Void, Never>?
    /// Moves when a look at the changes is no longer wanted (a newer one, or quitting), so
    /// one already waiting on the Git queue gives up instead of holding up what's behind it.
    private let changesTicket = Ticket()
    /// The look at the changes only reads (Git runs with optional locks off, and new scenes
    /// are found through a copy of the index), so it has its own queue: saving a version,
    /// switching or quitting never waits for it.
    private let changesQueue = DispatchQueue(label: "com.specproj.longhand.git.changes", qos: .utility)

    private(set) var root: URL?

    /// Where the library stands against its remote, and the log of what the sync did
    /// (`Sync.swift`).
    let sync = SyncStatus()
    /// The automatic commit waiting for typing to pause, and when uncommitted changes began.
    var commitTask: Task<Void, Never>?
    var dirtySince: Date?
    /// Commits arrived while a push was running: push once more when it ends.
    var pushAgain = false
    /// A push was rejected because the remote moved: push again once its commits are in,
    /// even with automatic pushing off (the writer asked for this push).
    var pushAfterSync = false
    /// The last push was rejected and a fetch-and-pull has been tried for it: a second
    /// rejection is reported, never retried again (it would loop).
    var rejectedOnce = false
    /// Callers that asked for a push while one was running: answered by the follow-up push.
    var pushWaiters: [@MainActor (Bool) -> Void] = []
    var fetchTask: Task<Void, Never>?
    /// The remote has commits this Mac lacks: `LibraryStore` saves, pulls and re-reads.
    var pullRequested: (() -> Void)?
    /// The first read of a newly opened library is followed by a fetch.
    private var syncAfterRefresh = false

    func setBackingUp(_ on: Bool) { if backingUp != on { backingUp = on } }
    func setPushed(_ ok: Bool) {
        backupFailed = !ok
        if ok { lastBackup = Date() }
    }
    private lazy var wiring: Void = { changes.openScene = { [weak self] in self?.showSceneChanges($0) } }()
    let queue = DispatchQueue(label: "com.specproj.longhand.git")
    /// Sending to GitHub has its own queue: a slow network must never hold up saving or
    /// switching (pushing reads Git's objects only, so it can run beside them).
    let pushQueue = DispatchQueue(label: "com.specproj.longhand.git.push")

    // MARK: - Opening

    /// Makes sure the library is a Git repository with Longhand's settings, records a first
    /// version if there is none, and sends anything not yet backed up.
    func open(root: URL?) {
        _ = wiring
        sessionEnded = false
        self.root = root
        remoteRead = false
        remoteCache = nil
        recent = []
        currentRewrite = nil
        rewrites = []
        mergePlan = nil
        comparing = false
        comparison = nil
        backupPage = nil
        hasBackup = false
        lastBackup = nil
        backupFailed = false
        available = false
        changesTask?.cancel()
        changes.clear(root: root)
        resetSync()
        fetchTask?.cancel()
        guard let root else { return }
        run(root) { root in
            guard Git.prepare(root) else { return false }
            if !Git.hasCommits(root) {
                Git.commitAll(root, message: "Initial commit")
            }
            return true
        } then: { [weak self] ready in
            guard let self, self.root == root else { return }
            self.available = ready
            // Once the remote is known: fetch, pull what another Mac pushed, push anything
            // committed while offline.
            self.syncAfterRefresh = true
            self.refresh()
            self.startFetchTimer()
        }
    }

    /// Records a version if anything changed, then backs up. Runs before this returns, because
    /// it is called as the app quits or the library closes.
    /// Set once quitting has committed and pushed in the background (`endSessionInBackground`),
    /// so the work isn't done twice as the app exits.
    private(set) var sessionEnded = false

    /// Quitting's commit and push, off the main thread so the window can say what's
    /// happening: `stage` reports pushing, `done` comes when both are finished (the push is
    /// stopped after 10 seconds, as before).
    func endSessionInBackground(words: Int, stage: @escaping @MainActor (Bool) -> Void,
                                done: @escaping @MainActor () -> Void) {
        guard let root, available, !sessionEnded else { return done() }
        sessionEnded = true
        changesTask?.cancel()
        commitTask?.cancel()
        fetchTask?.cancel()
        changesTicket.next()
        let message = Self.sessionNote(words: words)
        let remote = hasBackup
        queue.async {
            Git.commitAll(root, message: message)
            let pushes = remote || Git.remoteURL(root) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { stage(pushes) }
                guard pushes else { MainActor.assumeIsolated { done() }; return }
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = Git.pushResult(root, timeout: 10)
                    DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
                }
            }
        }
    }

    /// For the self-test: carry on after a background session end.
    func resumeSession() { sessionEnded = false }

    func endSession(words: Int) {
        guard let root, available, !sessionEnded else { return }
        changesTask?.cancel()
        commitTask?.cancel()
        fetchTask?.cancel()
        changesTicket.next()
        let message = Self.sessionNote(words: words)
        _ = queue.sync { Git.commitAll(root, message: message) }
        // Straight from here, not through the push queue: a fetch or push already stalling
        // there (no network) would hold the quit until it timed out. Two pushes at once are
        // safe; Git serialises them on the remote.
        if hasBackup || Git.remoteURL(root) != nil { _ = Git.pushResult(root, timeout: 10) }
    }

    static func sessionNote(words: Int, date: Date = Date()) -> String {
        let day = date.formatted(.dateTime.day().month(.wide).year())
        let count = words == 1 ? "1 word" : "\(words.formatted(.number.locale(Locale(identifier: "en_US")))) words"
        return "Writing session, \(day) (\(count))"
    }

    // MARK: - Saving

    /// Saves a version with the writer's note. Returns false (through `done`) if nothing had
    /// changed since the last version.
    /// Saves a version of every scene changed since its last version (a book or the library).
    /// What changed is worked out as the version is made, never from an older look. With no
    /// scene changed, a reorder or a deletion is still recorded (as an automatic copy).
    func save(note: String, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let root, available else { return done(false) }
        let note = Self.clean(note)
        run(root) { root in
            let changed = Git.changedScenes(root)
            return changed.isEmpty
                ? Git.commitAll(root, message: "Writing session, \(Date().formatted(.dateTime.day().month(.wide).year())) (reordered)")
                : Git.commitVersions(root, scenes: changed, note: note)
        } then: { [weak self] saved in
            self?.refresh(remote: false)
            if saved { self?.backUp() }
            done(saved)
        }
    }

    /// Saves a version of each of these scenes (paths in the library), with one note. False
    /// (through `done`) when there was nothing to save.
    func saveVersions(of scenes: [String], note: String, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let root, available, !scenes.isEmpty else { return done(false) }
        let note = Self.clean(note)
        run(root) { root in
            Git.commitVersions(root, scenes: scenes, note: note)
        } then: { [weak self] saved in
            self?.refresh(remote: false)
            if saved { self?.backUp() }
            done(saved)
        }
    }

    /// The name offered for the next draft: "Draft 1", "Draft 2"…
    var nextDraftName: String {
        let numbers = recent.flatMap(\.drafts).compactMap { name -> Int? in
            guard name.hasPrefix("draft-") else { return nil }
            return Int(name.dropFirst(6))
        }
        let known = (root.map(Git.draftNumbers) ?? []) + numbers
        return "Draft \((known.max() ?? 0) + 1)"
    }

    /// Saves a version (if anything changed) and names it.
    func markDraft(name: String, note: String, done: @escaping @MainActor (String?) -> Void) {
        guard let root, available else { return done("Git isn’t available for this library.") }
        let title = Self.clean(name).isEmpty ? nextDraftName : Self.clean(name)
        let tag = Self.tagName(title)
        let message = Self.clean(note).isEmpty ? title : "\(title): \(Self.clean(note))"
        run(root) { root -> String? in
            let changed = Git.changedScenes(root)
            if changed.isEmpty {
                Git.commitAll(root, message: message)
            } else {
                Git.commitVersions(root, scenes: changed, note: message)
            }
            let unique = Git.uniqueTag(root, tag)
            return Git.tag(root, unique, message: message) ? nil : "Couldn’t create the tag."
        } then: { [weak self] failure in
            self?.refresh(remote: false)
            if failure == nil { self?.backUp() }
            done(failure)
        }
    }

    /// `Draft 2` → `draft-2`; `Sent to Agent, Nov` → `sent-to-agent-nov`.
    nonisolated static func tagName(_ title: String) -> String {
        let lowered = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("-") && !out.isEmpty {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "draft" : out
    }

    private nonisolated static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - GitHub

    var account: String {
        get {
            let saved = UserDefaults.standard.string(forKey: Self.accountKey)
            if let saved, accounts.isEmpty || accounts.contains(saved) { return saved }
            return accounts.first ?? saved ?? ""
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.accountKey)
        }
    }

    /// GitHub accounts signed in on this Mac (read when the backup sheet opens).
    @Published private(set) var accounts: [String] = []

    func loadAccounts(then done: (@MainActor () -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = GitHub.accounts()
            Task { @MainActor [weak self] in
                self?.accounts = found
                done?()
            }
        }
    }

    var suggestedRepositoryName: String {
        Self.tagName(root?.lastPathComponent ?? "novel")
    }

    /// Creates a private repository on GitHub for this library and sends every version to it.
    func createBackup(name: String, done: @escaping @MainActor (String?) -> Void) {
        guard let root, available else { return done("Git isn’t available for this library.") }
        let owner = account
        let repo = Self.tagName(name)
        run(root) { root -> String? in
            GitHub.createPrivateRepository(owner: owner, name: repo, for: root)
        } then: { [weak self] failure in
            self?.remoteRead = false
            self?.refresh()
            if failure == nil {
                self?.setPushed(true)
                self?.sync.notePublished()
            }
            done(failure)
        }
    }

    /// Connects this library to a Git remote at any address (another host, a server, a
    /// folder) and pushes everything to it: for a writer who doesn't use GitHub's tool. The
    /// Mac signs in to it the way Git does (an SSH key, or a password kept in Keychain).
    func connectRemote(address: String, done: @escaping @MainActor (String?) -> Void) {
        guard let root, available else { return done("Git isn’t available for this library.") }
        run(root) { root -> String? in
            Git.connect(root, to: address)
        } then: { [weak self] failure in
            self?.remoteRead = false
            self?.refresh()
            if failure == nil {
                self?.setPushed(true)
                self?.sync.notePublished()
            }
            done(failure)
        }
    }

    /// Connects this library to a repository in a folder on this Mac or a drive (made there
    /// if needed, named after the library) and pushes everything to it.
    func connectFolder(_ parent: URL, done: @escaping @MainActor (String?) -> Void) {
        guard let root, available else { return done("Git isn’t available for this library.") }
        let name = suggestedRepositoryName
        run(root) { root -> String? in
            let made = Git.folderRemote(in: parent, named: name)
            guard let path = made.path else { return made.problem }
            return Git.connect(root, to: path)
        } then: { [weak self] failure in
            self?.remoteRead = false
            self?.refresh()
            if failure == nil {
                self?.setPushed(true)
                self?.sync.notePublished()
            }
            done(failure)
        }
    }

    /// Sends any versions GitHub doesn't have yet. Does nothing until a backup exists.
    func backUp(done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        pushNow(done: done)
    }

    func openBackupPage() {
        if let backupPage, let url = URL(string: backupPage) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Comparing

    /// Opens the comparison: from the latest draft (or, with no drafts, the latest version) to
    /// the library as it is now.
    func startComparing(from chosen: String? = nil) {
        guard let root, available else { return }
        compareLabel = nil
        comparing = true
        comparison = nil
        comparingBusy = true
        queue.async { [weak self] in
            // The snapshot of now and the branch list don't depend on which version is
            // compared: take them while the version list is read.
            // The branch list is only for the menus: it fills them when it arrives, without
            // holding up the comparison.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let tips = Git.branchTips(root)
                Task { @MainActor [weak self] in
                    guard let self, self.root == root else { return }
                    self.branchTips = tips
                }
            }
            nonisolated(unsafe) var untracked = true
            let group = DispatchGroup()
            DispatchQueue.global(qos: .userInitiated).async(group: group) { untracked = Git.untrackedScenes(root) }
            let (points, titles) = Git.allVersions(root)
            let from = chosen ?? points.first { !$0.drafts.isEmpty }?.id ?? points.first?.id
            group.wait()
            let result = from.map { Git.compare(root, from: $0, to: nil, workingTree: !untracked) }
            Task { @MainActor [weak self] in
                guard let self, self.root == root else { return }
                self.allPoints = points
                self.draftTitles = titles
                self.compareFrom = from
                self.compareTo = nil
                self.comparison = result
                self.comparingBusy = false
            }
        }
    }

    func compare(from: String?, to: String?) {
        guard let root, let from else { return }
        compareFrom = from
        compareTo = to
        comparingBusy = true
        detail = nil
        queue.async { [weak self] in
            let result = Git.compare(root, from: from, to: to)
            Task { @MainActor [weak self] in
                guard let self, self.root == root, self.compareFrom == from, self.compareTo == to else { return }
                self.comparison = result
                self.comparingBusy = false
            }
        }
    }

    /// From a scene's history in the Versions tab: one scene compared with a saved version, whole, ready to restore.
    func openScene(_ path: String, from: String, label: String? = nil) {
        guard let root, available else { return }
        compareLabel = label
        comparing = true
        comparingBusy = true
        compareFrom = from
        compareTo = nil
        queue.async { [weak self] in
            let (points, titles) = Git.allVersions(root)
            let tips = Git.branchTips(root)
            let result = Git.compare(root, from: from, to: nil)
            // Unchanged since: shown as it is, with nothing to restore.
            let change = result.scenes.first { $0.path == path || $0.oldPath == path } ?? {
                let text = String.prose(at: root.appendingPathComponent(path)) ?? ""
                return Comparison.SceneChange(path: path, oldPath: nil, status: .changed,
                                              segments: [.init(kind: .same, text: text)], wordsAdded: 0, wordsRemoved: 0)
            }()
            Task { @MainActor [weak self] in
                guard let self, self.root == root, self.compareFrom == from else { return }
                self.allPoints = points
                self.draftTitles = titles
                self.branchTips = tips
                self.comparison = result
                self.detail = change
                self.comparingBusy = false
            }
        }
    }

    /// Recomputes the comparison shown (after a restore changed the files).
    func recompare() {
        guard comparing else { return }
        let open = detail?.path
        compare(from: compareFrom, to: compareTo)
        if let open, let root, let from = compareFrom {
            let to = compareTo
            queue.async { [weak self] in
                let again = Git.compare(root, from: from, to: to).scenes.first { $0.path == open }
                Task { @MainActor [weak self] in self?.detail = again }
            }
        }
    }

    /// The older side's name: a draft's name, or when the version was saved.
    var fromTitle: String {
        if let tip = branchTips.first(where: { $0.id == compareFrom }) { return tip.title }
        guard let point = allPoints.first(where: { $0.id == compareFrom }) else { return "the earlier commit" }
        return compareLabel ?? label(of: point)
    }

    /// A draft's name, or when the version was saved (library-wide comparisons).
    func label(of point: SavePoint) -> String {
        point.drafts.isEmpty ? Self.when(point.date) : title(of: point)
    }

    /// "Today, 14:32", "Yesterday, 16:20", "4 Nov 2026, 21:12".
    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated).year())), \(time)"
    }

    /// A scene's text in the older version of the comparison.
    func olderText(of change: Comparison.SceneChange) -> String? {
        guard let root, let from = compareFrom, let path = change.oldPath ?? (change.status == .added ? nil : change.path) else { return nil }
        return queue.sync { Git.show(root, from, path) }
    }

    /// Puts every file in the library back as it was in the older version. The library as it
    /// is now is saved as a version first, so this can be undone the same way.
    func restoreAll(done: @escaping @MainActor (Bool) -> Void) {
        guard let root, available, let from = compareFrom else { return done(false) }
        let name = fromTitle
        run(root) { root in
            Git.restoreAll(root, to: from, title: name)
        } then: { [weak self] ok in
            self?.refresh(remote: false)
            if ok { self?.backUp() }
            done(ok)
        }
    }

    /// A draft's name, or the version's note.
    func title(of point: SavePoint) -> String {
        if let draft = point.drafts.first { return draftTitles[draft] ?? draft }
        return point.note
    }

    // MARK: - Reading

    /// Re-reads recent versions, and (unless the caller knows they didn't change) the branches
    /// and the backup address. Longhand's own saves and rewrites can't change the address, so
    /// they skip it: one Git call fewer, and the next action doesn't wait for it.
    func refresh(branches: Bool = true, remote rereadRemote: Bool = true) {
        guard let root else { return }
        let knownRemote = remoteRead && !rereadRemote ? (remote: remoteCache, read: true) : (remote: nil, read: false)
        queue.async { [weak self] in
            let points = Git.recent(root, limit: 60)
            let remote = knownRemote.read ? knownRemote.remote : Git.remoteURL(root)
            let page = remote.flatMap(GitHub.page(for:))
            let state = branches ? Git.branchState(root) : nil
            Task { @MainActor [weak self] in
                guard let self, self.root == root else { return }
                self.remoteCache = remote
                self.remoteRead = true
                if let (branch, rewrites) = state {
                    self.rewrites = rewrites
                    let open = rewrites.first { $0.id == branch }
                    if self.currentRewrite != open { self.currentRewrite = open }
                }
                self.recent = points
                self.hasBackup = remote != nil
                self.backupPage = page
                let onGitHub = remote == nil || page != nil
                if self.sync.onGitHub != onGitHub { self.sync.onGitHub = onGitHub }
                self.scheduleChanges(after: 0)
                if self.syncAfterRefresh {
                    self.syncAfterRefresh = false
                    self.syncNow()
                }
            }
        }
    }

    // MARK: - Changes since the last version

    /// Looks again at what changed, `ms` after the last call: saves come every few hundred
    /// milliseconds while writing, and one look after the writer pauses is enough.
    func scheduleChanges(after ms: Int = 900) {
        changesTask?.cancel()
        // Anything already being looked at is out of date now.
        changesTicket.next()
        changesTask = Task { @MainActor [weak self] in
            if ms > 0 { try? await Task.sleep(for: .milliseconds(ms)) }
            guard !Task.isCancelled else { return }
            self?.refreshChanges()
        }
    }

    private func refreshChanges() {
        guard let root, available else { return }
        let hasBackup = hasBackup, failed = backupFailed
        let ticket = changesTicket.next(), tickets = changesTicket
        changesQueue.async { [weak self] in
            guard tickets.current == ticket else { return }
            let (scenes, histories) = Git.sceneChanges(root)
            let unpushed = hasBackup ? Git.unpushedCount(root) : 0
            Task { @MainActor [weak self] in
                // Dropped if a newer look was asked for meanwhile (the files may have changed).
                guard let self, self.root == root, tickets.current == ticket else { return }
                self.changes.update(root: root, scenes: scenes, histories: histories,
                                    behind: failed || unpushed > 0, hasBackup: hasBackup)
            }
        }
    }


    // MARK: - Rewrites
    //
    // These run before returning (a tenth of a second or so): the files change under the
    // editor, so nothing else may write while they do. `LibraryStore` saves first and reads
    // the files again afterwards.

    func startRewrite(title: String) -> Bool {
        guard let root, available else { return false }
        let made = queue.sync { Git.startRewrite(root, title: title) }
        if let made {
            settleRewrites(known: (made.id, [made] + rewrites.filter { $0.id != made.id }))
        } else {
            settleRewrites()
        }
        return made != nil
    }

    /// Moves to a rewrite, or to the manuscript with nil.
    func switchTo(_ rewrite: Rewrite?) -> Bool {
        guard let root, available else { return false }
        let from = currentRewrite?.title ?? "the manuscript"
        let branch = queue.sync { rewrite?.id ?? Git.manuscriptBranch(root) }
        let ok = queue.sync { Git.switchTo(root, branch: branch, note: "Switched from \(from)") }
        // Switching changes which branch is open, not the list: no need to ask Git again.
        if ok { settleRewrites(known: (branch, rewrites)) } else { settleRewrites() }
        return ok
    }

    /// Works out keeping the open rewrite. Nil plan with true: nothing in the way, done.
    func planKeep() -> MergePlan? {
        guard let root, available, let rewrite = currentRewrite else { return nil }
        return queue.sync { Git.planKeep(root, rewrite) }
    }

    func finishKeep(_ plan: MergePlan) -> Bool {
        guard let root, available else { return false }
        let ok = queue.sync { Git.finishKeep(root, plan) }
        mergePlan = nil
        if ok {
            settleRewrites(known: (queue.sync { Git.manuscriptBranch(root) }, rewrites.filter { $0.id != plan.rewrite.id }))
        } else {
            settleRewrites()
        }
        return ok
    }

    func discardRewrite() -> Bool {
        guard let root, available, let rewrite = currentRewrite else { return false }
        let ok = queue.sync { Git.discard(root, rewrite) }
        if ok {
            settleRewrites(known: (queue.sync { Git.manuscriptBranch(root) }, rewrites.filter { $0.id != rewrite.id }))
        } else {
            settleRewrites()
        }
        return ok
    }

    /// Reads the branch state straight away (the views must show where the writer is now),
    /// then the rest in the background.
    /// `known` is the state the operation just produced, when it knows it (saving two Git calls).
    private func settleRewrites(known: (current: String?, rewrites: [Rewrite])? = nil) {
        guard let root else { return }
        let (branch, list) = known ?? queue.sync { Git.branchState(root) }
        rewrites = list
        currentRewrite = list.first { $0.id == branch }
        comparing = false
        refresh(branches: false, remote: false)
        backUp()
    }

    /// Waits for queued Git work (the self-test uses this).
    func waitUntilIdle() {
        queue.sync {}
        pushQueue.sync {}
        changesQueue.sync {}
    }

    private func run<T: Sendable>(_ root: URL,
                                  _ work: @escaping @Sendable (URL) -> T,
                                  then: @escaping @MainActor (T) -> Void) {
        busy = true
        queue.async { [weak self] in
            let result = work(root)
            Task { @MainActor [weak self] in
                self?.busy = false
                then(result)
            }
        }
    }
}

// MARK: - Git

/// Runs `/usr/bin/git` in a library folder. Everything here is synchronous and is called from
/// `VersionStore`'s queue (or straight from the quit handler).
enum Git {
    static let executable = "/usr/bin/git"

    static let attributes = """
    # Written by Longhand. Scenes are Markdown: Git shows changes under the nearest heading.
    *.md     text eol=lf diff=markdown
    *.json   text eol=lf
    *.docx   binary
    *.pdf    binary
    *.jpg    binary

    """

    static let ignore = """
    # Written by Longhand.
    .DS_Store
    *.tmp
    ~$*.docx
    # Longhand's own ten-minute copies of each scene (the History tab); Git keeps versions.
    .longhand/history/
    # Where you were in each scene: changes all the time, not part of the book.
    .longhand/places.json

    """

    /// Covers were left out of Git until 2026-11-12, so they never reached GitHub or another
    /// Mac. They are committed now; this rule is taken out of libraries that have it.
    static let coversRule = ".longhand/covers/"
    static let placesRule = ".longhand/places.json"

    struct Result: Sendable {
        let status: Int32
        let output: String
        let error: String
        var ok: Bool { status == 0 }
    }

    /// Initialises the repository if needed and writes Longhand's settings files if missing.
    @discardableResult
    static func prepare(_ root: URL) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable) else { return false }
        if !fm.fileExists(atPath: root.appendingPathComponent(".git").path) {
            guard run(["init", "-q", "-b", "main"], in: root).ok else { return false }
        }
        let attributesFile = root.appendingPathComponent(".gitattributes")
        if !fm.fileExists(atPath: attributesFile.path) {
            try? attributes.write(to: attributesFile, atomically: true, encoding: .utf8)
        } else if let existing = try? String(contentsOf: attributesFile, encoding: .utf8), !existing.contains("*.jpg") {
            // Covers are pictures: Git must not try to merge or re-end their lines.
            try? (existing + (existing.hasSuffix("\n") ? "" : "\n") + "*.jpg    binary\n")
                .write(to: attributesFile, atomically: true, encoding: .utf8)
        }
        let ignoreFile = root.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignoreFile.path) {
            try? ignore.write(to: ignoreFile, atomically: true, encoding: .utf8)
        } else if var existing = try? String(contentsOf: ignoreFile, encoding: .utf8) {
            // Libraries made before these were left out of versions: leave them out now, and
            // stop tracking any already recorded (the files themselves stay).
            let rules = [(placesRule, "Where you were in each scene.", ".longhand/places.json")]
            var changed = false
            if existing.contains(coversRule) {
                // Covers sync with the rest of the library now: stop ignoring them.
                existing = existing.components(separatedBy: "\n")
                    .filter { $0.trimmingCharacters(in: .whitespaces) != coversRule && !$0.hasPrefix("# Book covers") }
                    .joined(separator: "\n")
                changed = true
            }
            for (rule, note, path) in rules where !existing.contains(rule) {
                existing += (existing.hasSuffix("\n") ? "" : "\n") + "# \(note)\n\(rule)\n"
                run(["rm", "-r", "-q", "--cached", "--ignore-unmatch", path], in: root)
                changed = true
            }
            if changed { try? existing.write(to: ignoreFile, atomically: true, encoding: .utf8) }
        }
        // Versions are signed with the Mac's user name, never a work account's details.
        if run(["config", "--local", "user.email"], in: root).output.isEmpty {
            let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
            run(["config", "--local", "user.name", name], in: root)
            run(["config", "--local", "user.email", "\(NSUserName())@longhand.local"], in: root)
        }
        run(["config", "--local", "core.quotePath", "false"], in: root)
        return true
    }

    static func hasCommits(_ root: URL) -> Bool {
        run(["rev-parse", "--verify", "-q", "HEAD"], in: root).ok
    }

    /// Stages every change and commits. Returns false if there was nothing to record.
    @discardableResult
    static func commitAll(_ root: URL, message: String) -> Bool {
        guard run(["add", "-A"], in: root).ok else { return false }
        // `commit` itself refuses (status 1) when nothing changed, so there's no need to ask
        // first: two Git calls instead of four, on every save, switch and quit.
        return run(["commit", "-q", "--no-verify", "-m", message], in: root).ok
    }

    /// Saves the present as a version, puts every tracked file back as it was in `revision`
    /// (removing files that didn't exist then), and records that as a version too.
    static func restoreAll(_ root: URL, to revision: String, title: String) -> Bool {
        commitAll(root, message: "Before restoring \(title)")
        let folders = Set(run(["ls-files", "-z"], in: root).output.components(separatedBy: "\0")
            .filter { !$0.isEmpty }
            .map { ($0 as NSString).deletingLastPathComponent }
            .filter { !$0.isEmpty })
        guard run(["restore", "--source", revision, "--staged", "--worktree", "--", ":/"], in: root).ok else { return false }
        // Folders emptied by the restore (a chapter that didn't exist then) go too; Git keeps no
        // empty folders, so nothing is lost. Deepest first, so a book folder can follow.
        let fm = FileManager.default
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            let url = root.appendingPathComponent(folder)
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: url) }
        }
        commitAll(root, message: "Restored \(title)")
        return true
    }

    static func tag(_ root: URL, _ name: String, message: String) -> Bool {
        run(["tag", "-a", name, "-m", message], in: root).ok
    }

    static func uniqueTag(_ root: URL, _ name: String) -> String {
        let existing = Set(run(["tag", "--list"], in: root).output.split(separator: "\n").map(String.init))
        if !existing.contains(name) { return name }
        var n = 2
        while existing.contains("\(name)-\(n)") { n += 1 }
        return "\(name)-\(n)"
    }

    static func draftNumbers(_ root: URL) -> [Int] {
        run(["tag", "--list", "draft-*"], in: root).output
            .split(separator: "\n")
            .compactMap { Int($0.dropFirst(6)) }
    }

    static func recent(_ root: URL, limit: Int) -> [VersionStore.SavePoint] {
        let sep = "\u{1f}"
        let result = run(["log", "-n", "\(limit)", "--format=%H\(sep)%ct\(sep)%s\(sep)%D"], in: root)
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: sep)
            guard parts.count == 4, let seconds = TimeInterval(parts[1]) else { return nil }
            let drafts = parts[3].components(separatedBy: ", ")
                .filter { $0.hasPrefix("tag: ") }
                .map { String($0.dropFirst(5)) }
            return .init(id: parts[0], date: Date(timeIntervalSince1970: seconds), note: SceneVersions.listedNote(parts[2]), drafts: drafts)
        }
    }

    /// The manuscript's and every rewrite's latest version, except the branch that's open.
    static func branchTips(_ root: URL) -> [(title: String, id: String)] {
        // Every branch and discarded rewrite, with what it points at, in one listing (this
        // was a Git call per branch). Fields: ref, "*" if open, id, tag's commit, subject.
        let sep = "\u{1f}"
        let listing = run(["for-each-ref", "--sort=-creatordate",
                           "--format=%(refname)\(sep)%(HEAD)\(sep)%(objectname)\(sep)%(*objectname)\(sep)%(contents:subject)",
                           "refs/heads", "refs/tags/discarded-*"], in: root).output
        var current: String?
        var heads: [String: String] = [:]
        var discarded: [(title: String, id: String)] = []
        for line in listing.split(separator: "\n") {
            let parts = line.components(separatedBy: sep)
            guard parts.count == 5 else { continue }
            if parts[0].hasPrefix("refs/heads/") {
                let name = String(parts[0].dropFirst("refs/heads/".count))
                heads[name] = parts[2]
                if parts[1] == "*" { current = name }
            } else if !parts[3].isEmpty {
                discarded.append((parts[4], parts[3]))
            }
        }
        let manuscript = manuscriptBranch(root)
        var tips: [(title: String, id: String)] = []
        if current != manuscript, let id = heads[manuscript] { tips.append((manuscript, id)) }
        if heads.keys.contains(where: { $0.hasPrefix(rewritePrefix) && $0 != current }) {
            for rewrite in branchState(root).rewrites where rewrite.id != current {
                if let id = heads[rewrite.id] { tips.append(("Branch: \(rewrite.title)", id)) }
            }
        }
        return tips + discarded
    }

    /// Fetches a library kept at `remote` into a new folder `name` inside `parent`, with all
    /// its versions. Never writes into a folder that already exists. Returns the new folder,
    /// or a sentence saying what went wrong.
    static func fetchLibrary(from remote: String, named name: String, into parent: URL) -> (folder: URL?, problem: String?) {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            return (nil, "There’s already a folder called “\(name)” there. Choose another place.")
        }
        let result = run(["clone", "--quiet", remote, folder.path], in: parent, timeout: 300,
                         environment: quietSSH)
        guard result.ok, FileManager.default.fileExists(atPath: folder.path) else {
            try? FileManager.default.removeItem(at: folder)
            return (nil, "Couldn’t fetch the library. Check the connection and try again.")
        }
        // Mark it as a library, so opening it doesn't ask whether to adopt the folder.
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".longhand"),
                                                 withIntermediateDirectories: true)
        return (folder, nil)
    }

    /// SSH for a first look at a remote: never asks on a terminal (there is none), and
    /// remembers a host it hasn't met (as answering yes would).
    static let quietSSH = ["GIT_TERMINAL_PROMPT": "0",
                           "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"]

    /// Whether this Mac can reach and sign in to the remote at `address`.
    static func canReach(_ address: String, from directory: URL) -> Bool {
        run(["ls-remote", "--heads", address], in: directory, timeout: 45, environment: quietSSH).ok
    }

    /// Makes `address` this library's remote and pushes everything to it. Returns nil on
    /// success, or a sentence saying what went wrong; on failure the library is left as it was.
    static func connect(_ root: URL, to address: String) -> String? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "Type the remote’s address." }
        guard canReach(address, from: root) else {
            return "Couldn’t reach that remote. Check the address, and that this Mac can sign in to it (an SSH key, or a password saved in Keychain)."
        }
        let before = remoteURL(root)
        if before == nil {
            run(["remote", "add", "origin", address], in: root)
        } else {
            run(["remote", "set-url", "origin", address], in: root)
        }
        let pushed = pushResult(root, timeout: 180)
        guard pushed.ok else {
            // Put the library back as it was: no half-connected remote.
            if let before { run(["remote", "set-url", "origin", before], in: root) } else { run(["remote", "remove", "origin"], in: root) }
            let refused = pushed.error.contains("rejected") || pushed.error.contains("fetch first") || pushed.error.contains("non-fast-forward")
            return refused
                ? "That remote already holds other work. Use an empty repository, or clone it from the welcome screen."
                : "Couldn’t push to that remote. Check that this Mac may write to it."
        }
        return nil
    }

    /// A repository in a folder on this Mac or a drive: `<parent>/<name>.git`, made if it
    /// isn't there. Returns its path, or a sentence saying what went wrong.
    static func folderRemote(in parent: URL, named name: String) -> (path: String?, problem: String?) {
        let folder = parent.appendingPathComponent(name.hasSuffix(".git") ? name : name + ".git", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            // Only an existing repository (a bare one) may be used; never another folder.
            guard run(["rev-parse", "--is-bare-repository"], in: folder).output == "true" else {
                return (nil, "There’s already a folder called “\(folder.lastPathComponent)” there. Choose another place.")
            }
            return (folder.path, nil)
        }
        guard run(["init", "-q", "--bare", folder.path], in: parent).ok else {
            return (nil, "Couldn’t make a repository there. Check that this Mac may write to that folder.")
        }
        return (folder.path, nil)
    }

    /// Whether a remote's address is a folder on this Mac (or a drive).
    static func isFolder(_ address: String) -> Bool {
        address.hasPrefix("/") || address.hasPrefix("file://")
    }

    /// "novel" from `git@example.com:me/novel.git` or `https://host/me/novel`.
    static func repositoryName(of address: String) -> String {
        var last = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while last.hasSuffix("/") { last.removeLast() }
        last = String(last.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last.isEmpty ? "Library" : last
    }

    static func remoteURL(_ root: URL) -> String? {
        let result = run(["remote", "get-url", "origin"], in: root)
        return result.ok && !result.output.isEmpty ? result.output : nil
    }

    /// Paths for helpers Git may call (GitHub's sign-in helper lives in Homebrew's folder,
    /// which apps opened from the Finder don't see).
    static var searchPath: String {
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL, timeout: TimeInterval = 30,
                    environment extra: [String: String] = [:]) -> Result {
        Process.capture(executable, arguments, in: directory, timeout: timeout, environment: extra)
    }
}

// MARK: - GitHub

/// Uses the GitHub command-line tool (`gh`), already signed in on this Mac, to create the
/// private repository. Pushing afterwards goes through plain Git.
enum GitHub {
    static var executable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The accounts `gh` is signed in to for github.com.
    static func accounts() -> [String] {
        guard let gh = executable else { return [] }
        let status = Process.capture(gh, ["auth", "status", "--hostname", "github.com"],
                                     in: FileManager.default.homeDirectoryForCurrentUser, timeout: 15)
        var names: [String] = []
        for line in (status.output + "\n" + status.error).split(separator: "\n") {
            guard let range = line.range(of: "Logged in to github.com account ") else { continue }
            let rest = line[range.upperBound...]
            let name = rest.split(separator: " ").first.map(String.init) ?? ""
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// `https://owner@github.com/owner/name.git` → `https://github.com/owner/name`.
    static func page(for remote: String) -> String? {
        guard var url = URLComponents(string: remote), url.host == "github.com" else { return nil }
        url.user = nil
        url.password = nil
        if url.path.hasSuffix(".git") { url.path.removeLast(4) }
        return url.string
    }

    /// The names of the account's repositories, newest first; nil if GitHub can't be asked.
    static func repositories(owner: String) -> [String]? {
        guard let gh = executable else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let token = Process.capture(gh, ["auth", "token", "--user", owner], in: home, timeout: 15)
        guard token.ok, !token.output.isEmpty else { return nil }
        let env = ["GH_TOKEN": token.output, "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"]
        let list = Process.capture(gh, ["repo", "list", owner, "--limit", "200", "--json", "name", "-q", ".[].name"],
                                   in: home, timeout: 30, environment: env)
        guard list.ok else { return nil }
        return list.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// The address Git uses for a backup; the account name in it picks the sign-in.
    static func remote(owner: String, name: String) -> String {
        "https://\(owner)@github.com/\(owner)/\(name).git"
    }

    /// Returns nil on success, or a sentence saying what went wrong.
    static func createPrivateRepository(owner: String, name: String, for root: URL) -> String? {
        guard let gh = executable else {
            return "GitHub’s command-line tool (gh) isn’t installed on this Mac."
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let token = Process.capture(gh, ["auth", "token", "--user", owner], in: home, timeout: 15)
        guard !owner.isEmpty, token.ok, !token.output.isEmpty else {
            return owner.isEmpty
                ? "Sign in to GitHub first: run “gh auth login” in Terminal, then try again."
                : "This Mac isn’t signed in to GitHub as \(owner)."
        }
        let env = ["GH_TOKEN": token.output, "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"]
        let full = "\(owner)/\(name)"
        let exists = Process.capture(gh, ["repo", "view", full, "--json", "isPrivate", "-q", ".isPrivate"],
                                     in: home, timeout: 30, environment: env)
        if exists.ok {
            // Never send a novel to a public repository that happens to share the name.
            guard exists.output == "true" else {
                return "\(full) already exists on GitHub and is public. Choose another name."
            }
        } else {
            let created = Process.capture(gh, ["repo", "create", full, "--private",
                                               "--description", "Longhand library"],
                                          in: home, timeout: 60, environment: env)
            guard created.ok else {
                return "GitHub couldn’t create the repository. Try again later."
            }
        }
        // The account name in the address tells GitHub's sign-in helper which account to use.
        let remote = "https://\(owner)@github.com/\(full).git"
        if Git.remoteURL(root) == nil {
            Git.run(["remote", "add", "origin", remote], in: root)
        } else {
            Git.run(["remote", "set-url", "origin", remote], in: root)
        }
        return Git.pushResult(root, timeout: 120).ok ? nil : "The repository was created, but the push failed. Choose Push to try again."
    }
}

// MARK: - Running a command

extension Process {
    /// Runs a command to completion, capturing its output (through files, so a large output
    /// can never fill a pipe and stall). Stops it after `timeout` seconds.
    static func capture(_ executable: String, _ arguments: [String], in directory: URL,
                        timeout: TimeInterval, environment extra: [String: String] = [:],
                        trim: Bool = true) -> Git.Result {
        let raw = captureData(executable, arguments, in: directory, timeout: timeout, environment: extra)
        let output = String(decoding: raw.output, as: UTF8.self)
        return .init(status: raw.status,
                     output: trim ? output.trimmingCharacters(in: .whitespacesAndNewlines) : output,
                     error: raw.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The same, with the output as bytes and optional input on stdin. Waits for the command
    /// to finish (no polling), so a quick Git call costs a few milliseconds.
    static func captureData(_ executable: String, _ arguments: [String], in directory: URL,
                            timeout: TimeInterval, environment extra: [String: String] = [:],
                            input: Data? = nil) -> (status: Int32, output: Data, error: String) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("longhand-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        let inURL = base.appendingPathExtension("in")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        if let input { fm.createFile(atPath: inURL.path, contents: input) }
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
            if input != nil { try? fm.removeItem(at: inURL) }
        }
        guard let out = try? FileHandle(forWritingTo: outURL),
              let err = try? FileHandle(forWritingTo: errURL) else {
            return (-1, Data(), "Couldn’t start \(executable).")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Git.searchPath
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "en_US.UTF-8"
        for (key, value) in extra { env[key] = value }
        process.environment = env
        process.standardInput = input == nil ? FileHandle.nullDevice : (FileHandle(forReadingAtPath: inURL.path) ?? FileHandle.nullDevice)
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        try? out.close()
        try? err.close()
        let output = (try? Data(contentsOf: outURL)) ?? Data()
        let error = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        let status = process.isRunning || process.terminationReason == .uncaughtSignal ? -1 : process.terminationStatus
        return (status, output, error)
    }
}

/// A counter shared with the Git queue: work that took a ticket checks it is still current.
final class Ticket: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int { lock.withLock { value } }

    @discardableResult
    func next() -> Int { lock.withLock { value += 1; return value } }
}
