import Foundation
import AppKit

/// Where the library stands against its remote, and a log of every Git command the sync ran.
/// Its own object, so only the status bar's sync item, the Git Activity sheet and Settings
/// redraw when it moves (never the page).
///
/// The pipeline: autosave writes files (400ms) → an automatic commit once typing has paused
/// (`commitIdle`, or `commitCap` during continuous writing) → a push after every commit →
/// a fetch on opening, on coming back to the app and every few minutes, pulling when the
/// remote has moved. Nothing is called "pushed" until Git said so.
@MainActor
final class SyncStatus: ObservableObject {
    enum Activity: Equatable { case idle, committing, pushing, fetching, pulling }

    enum Problem: Equatable {
        /// No network, or GitHub couldn't be reached. Retried by itself.
        case offline
        /// GitHub refused the sign-in. Needs the writer.
        case authentication
        /// Both this Mac and the remote have commits the other lacks, and they touch the same
        /// lines. Needs the writer (Git Activity › Keep Both).
        case diverged
        case other(String)
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let date: Date
        /// The command as Git was given it: "git push --all origin".
        let command: String
        let ok: Bool
        /// What Git answered, when it said anything worth reading.
        let detail: String
    }

    /// Whether the remote is on GitHub; the words name it ("GitHub") or say "the remote"
    /// (another host, or a folder on this Mac or a drive).
    @Published var onGitHub = true
    var place: String { onGitHub ? "GitHub" : "the remote" }
    var Place: String { onGitHub ? "GitHub" : "The remote" }

    /// What is running now. Commit, push and fetch can overlap, so each is counted on its
    /// own and the most telling one is shown.
    @Published fileprivate(set) var activity: Activity = .idle
    private var running: [Activity] = []

    fileprivate func begin(_ what: Activity) {
        running.append(what)
        show()
    }

    fileprivate func end(_ what: Activity) {
        if let index = running.firstIndex(of: what) { running.remove(at: index) }
        show()
    }

    fileprivate func isRunning(_ what: Activity) -> Bool { running.contains(what) }

    private func show() {
        let next = [Activity.pulling, .pushing, .fetching, .committing].first(where: running.contains) ?? .idle
        if activity != next { activity = next }
    }
    @Published fileprivate(set) var problem: Problem?
    @Published fileprivate(set) var lastCommit: Date?
    @Published fileprivate(set) var lastPush: Date?
    @Published fileprivate(set) var lastFetch: Date?
    /// Commits here that the remote lacks, and the other way round (the open branch).
    @Published fileprivate(set) var ahead = 0
    @Published fileprivate(set) var behind = 0
    /// Newest first.
    @Published fileprivate(set) var log: [Entry] = []
    private var nextID = 0

    fileprivate func record(_ command: String, _ result: Git.Result) {
        record(command, ok: result.ok, detail: result.ok ? "" : (result.error.isEmpty ? result.output : result.error))
    }

    fileprivate func record(_ command: String, ok: Bool, detail: String = "") {
        nextID += 1
        log.insert(Entry(id: nextID, date: Date(), command: command, ok: ok,
                         detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    /// The repository was just created on GitHub and everything pushed to it.
    func notePublished() {
        problem = nil
        lastPush = Date()
        ahead = 0
        behind = 0
        record("gh repo create --private --push", ok: true)
    }

    fileprivate func reset() {
        running = []
        activity = .idle
        problem = nil
        lastCommit = nil
        lastPush = nil
        lastFetch = nil
        ahead = 0
        behind = 0
        log = []
    }

    /// What Git's complaint means, from its own words.
    nonisolated static func problem(from result: Git.Result) -> Problem {
        let text = (result.error + "\n" + result.output).lowercased()
        let offline = ["could not resolve host", "unable to access", "failed to connect", "network is unreachable",
                       "connection timed out", "operation timed out", "could not read from remote", "connection reset"]
        let auth = ["authentication failed", "could not read username", "permission denied", "403", "invalid username or",
                    "repository not found"]
        if auth.contains(where: text.contains) { return .authentication }
        if offline.contains(where: text.contains) { return .offline }
        // Stopped for taking too long (`Process.capture` gives -1 and no words): the network.
        if result.status == -1, result.error.isEmpty { return .offline }
        if text.contains("non-fast-forward") || text.contains("fetch first") || text.contains("rejected") { return .diverged }
        let line = (result.error.isEmpty ? result.output : result.error).split(separator: "\n").last.map(String.init)
        return .other(line ?? "Git stopped with status \(result.status)")
    }
}

extension VersionStore {
    /// Settings › Git. Both on unless switched off.
    static let autoCommitKey = "autoCommit"
    static let autoPushKey = "autoPush"
    static var autoCommit: Bool { UserDefaults.standard.object(forKey: autoCommitKey) as? Bool ?? true }
    static var autoPush: Bool { UserDefaults.standard.object(forKey: autoPushKey) as? Bool ?? true }

    /// Seconds without a save before the automatic commit, and the longest it waits while the
    /// writer keeps typing. (GitDoc commits 30s after a change; fixed timers bloat history.)
    static let commitIdle: TimeInterval = 30
    static let commitCap: TimeInterval = 300
    /// Seconds between looks at the remote while the app is in front (VS Code's autofetch).
    static let fetchEvery: TimeInterval = 180

    // MARK: - Automatic commits

    /// Whether a change is waiting for its automatic commit (the self-test looks at this).
    var hasPendingCommit: Bool { dirtySince != nil }

    /// The library's files changed (a save, a rename, a reorder). Commits once the writer has
    /// paused. Cheap: called a moment after every save.
    func filesChanged() {
        guard available, Self.autoCommit, root != nil else { return }
        let now = Date()
        if dirtySince == nil { dirtySince = now }
        let left = Self.commitCap - now.timeIntervalSince(dirtySince ?? now)
        let wait = max(1, min(Self.commitIdle, left))
        commitTask?.cancel()
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.commitNow()
        }
    }

    /// "Auto-commit 2026-11-11 14:32".
    nonisolated static func autoMessage(date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return "Auto-commit \(format.string(from: date))"
    }

    /// Commits whatever changed (nothing happens when nothing did), then pushes.
    /// `push`: nil follows the setting; true pushes whether or not anything was committed.
    func commitNow(push: Bool? = nil, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        commitTask?.cancel()
        dirtySince = nil
        guard let root, available else { return done(false) }
        let message = Self.autoMessage()
        let status = sync
        status.begin(.committing)
        queue.async { [weak self] in
            let committed = Git.commitAll(root, message: message)
            Task { @MainActor [weak self] in
                status.end(.committing)
                guard let self, self.root == root else { return }
                if committed {
                    self.sync.lastCommit = Date()
                    self.sync.record("git commit -m \"\(message)\"", ok: true)
                    self.refresh(branches: false, remote: false)
                    if push ?? Self.autoPush { self.pushNow() }
                } else if push == true {
                    self.pushNow()
                }
                done(committed)
            }
        }
    }

    /// Push, as the writer asks for it: commits anything uncommitted, then pushes once.
    func commitAndPush() {
        commitNow(push: true)
    }

    // MARK: - Push

    /// Pushes every branch and tag. One push runs at a time; commits made meanwhile go in one
    /// follow-up push. A push the remote rejects (it has commits this Mac lacks) fetches and
    /// pulls, then tries again.
    func pushNow(done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let root, available, hasBackup else { return done(false) }
        // Diverged, or known to be behind: the remote would reject it. The pull pushes after.
        guard sync.problem != .diverged, sync.behind == 0 else { return done(false) }
        if backingUp {
            pushAgain = true
            pushWaiters.append(done)
            return
        }
        setPushing(true)
        let gitQueue = queue
        pushQueue.async { [weak self] in
            let result = Git.pushResult(root, timeout: 60)
            // Branches merged or deleted here are deleted on the remote by name (never by
            // pruning: that would delete branches another Mac pushed).
            let deletes = result.ok ? Git.pushDeletes(root, timeout: 30) : []
            if !deletes.isEmpty { gitQueue.sync { Git.forgetDeleted(root, deletes.filter(\.result.ok).map(\.branch)) } }
            let counts = Git.aheadBehind(root)
            Task { @MainActor [weak self] in
                guard let self, self.root == root else { return }
                self.setPushing(false)
                self.sync.record("git push --all origin", result)
                for step in deletes { self.sync.record("git push origin --delete \(step.branch)", step.result) }
                self.finishPush(result, counts: counts)
                done(result.ok)
                let waiters = self.pushWaiters
                self.pushWaiters = []
                if result.ok, self.pushAgain {
                    self.pushAgain = false
                    self.pushNow { ok in waiters.forEach { $0(ok) } }
                } else {
                    waiters.forEach { $0(result.ok) }
                }
            }
        }
    }

    private func setPushing(_ on: Bool) {
        setBackingUp(on)
        if on { sync.begin(.pushing) } else { sync.end(.pushing) }
    }

    private func finishPush(_ result: Git.Result, counts: (ahead: Int, behind: Int)?) {
        if let counts { sync.ahead = counts.ahead; sync.behind = counts.behind }
        if result.ok {
            sync.problem = nil
            sync.lastPush = Date()
            rejectedOnce = false
            setPushed(true)
        } else {
            let problem = SyncStatus.problem(from: result)
            setPushed(false)
            if problem == .diverged, !rejectedOnce {
                // The remote moved: bring its commits in, then push again. Once: if that
                // doesn't cure it (another branch diverged, or GitHub declined the push),
                // it is reported rather than tried for ever.
                rejectedOnce = true
                pushAgain = false
                pushAfterSync = true
                syncNow()
            } else if problem == .diverged {
                pushAfterSync = false
                sync.problem = .other(Self.rejection(in: result))
            } else {
                sync.problem = problem
            }
        }
        scheduleChanges(after: 0)
    }

    /// Git's own line for the rejection ("! [rejected] rewrite/x -> rewrite/x (fetch first)"),
    /// in a sentence.
    nonisolated static func rejection(in result: Git.Result) -> String {
        let line = result.error.split(separator: "\n").first { $0.contains("rejected") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " !\t")) }
        return "The push was rejected" + (line.map { ": \($0)" } ?? ".")
    }

    // MARK: - Fetch and pull

    /// Fetch, pull if the remote has commits this Mac lacks, push if this Mac has commits the
    /// remote lacks. Runs on opening a library, on coming back to the app, every few minutes
    /// in front, and from Push/Pull in the interface.
    func syncNow(done: @escaping @MainActor () -> Void = {}) {
        guard let root, available, hasBackup, !sync.isRunning(.fetching) else { return done() }
        let status = sync, gitQueue = queue
        status.begin(.fetching)
        pushQueue.async { [weak self] in
            let fetched = Git.run(["fetch", "-q", "--prune", "origin"], in: root, timeout: 30)
            // Branches another Mac made, moved or deleted (on the Git queue: it writes refs).
            let branchesMoved = fetched.ok ? gitQueue.sync { Git.reconcileBranches(root) } : false
            let counts = Git.aheadBehind(root)
            Task { @MainActor [weak self] in
                status.end(.fetching)
                guard let self, self.root == root else { return }
                self.sync.record("git fetch --prune origin", fetched)
                guard fetched.ok else {
                    // Nothing is known about what is or isn't pushed: say only what failed.
                    self.sync.problem = SyncStatus.problem(from: fetched)
                    return done()
                }
                if branchesMoved { self.refresh(remote: false) }
                self.sync.lastFetch = Date()
                if self.sync.problem == .offline || self.sync.problem == .authentication { self.sync.problem = nil }
                if let counts { self.sync.ahead = counts.ahead; self.sync.behind = counts.behind }
                let wasBehind = (counts?.behind ?? 0) > 0
                if wasBehind, self.sync.problem != .diverged {
                    // The files change under the editor: the library store saves first and
                    // re-reads afterwards.
                    self.sync.begin(.pulling)
                    self.pullRequested?()
                }
                // Behind: the pull pushes when it has finished (a push now would be rejected,
                // and one straight after the pull's own would be a second for nothing).
                if !wasBehind, self.sync.problem != .diverged, Self.autoPush || self.pushAfterSync {
                    self.pushAfterSync = false
                    self.pushNow()
                }
                done()
            }
        }
    }

    /// Looks at the remote if it hasn't been looked at for `fetchEvery` (coming back to the app).
    func syncIfStale() {
        guard hasBackup else { return }
        if let last = sync.lastFetch, Date().timeIntervalSince(last) < Self.fetchEvery { return }
        syncNow()
    }

    /// Looks at the remote every few minutes while Longhand is in front.
    func startFetchTimer() {
        fetchTask?.cancel()
        fetchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.fetchEvery))
                guard !Task.isCancelled, let self else { return }
                if NSApp.isActive { self.syncIfStale() }
            }
        }
    }

    enum PullOutcome: Equatable { case upToDate, updated, conflict, failed }

    func endPulling() { sync.end(.pulling) }

    /// Brings the remote's commits into the open branch. Runs before returning (the files
    /// change), after `LibraryStore` has saved; true when files changed and must be re-read.
    /// Fast-forwards when this Mac has nothing new; otherwise replays this Mac's commits on
    /// top of the remote's (`rebase`). If the two changed the same lines, nothing is touched
    /// and the state becomes `.diverged`.
    func pull() -> PullOutcome {
        guard let root, available else {
            sync.end(.pulling)
            return .failed
        }
        if !sync.isRunning(.pulling) { sync.begin(.pulling) }
        defer { sync.end(.pulling) }
        let (outcome, steps) = queue.sync { Git.pull(root, message: Self.autoMessage()) }
        for step in steps { sync.record(step.command, step.result) }
        switch outcome {
        case .updated:
            sync.behind = 0
            sync.problem = nil
            refresh(remote: false)
            pushAfterPull()
        case .conflict:
            sync.problem = .diverged
            setPushed(false)
        case .upToDate:
            sync.behind = 0
            pushAfterPull()
        case .failed:
            // Said, not swallowed: nothing is pushed while the remote's commits are missing.
            let reason = steps.last.map { $0.result.error.isEmpty ? $0.result.output : $0.result.error } ?? ""
            let line = reason.split(separator: "\n").last.map(String.init)
            sync.problem = .other("Couldn’t pull from origin" + (line.map { ": \($0)" } ?? "."))
        }
        return outcome
    }

    private func pushAfterPull() {
        guard Self.autoPush || pushAfterSync else { return }
        pushAfterSync = false
        pushNow()
    }

    /// Out of `.diverged` without losing either side: the remote's copy becomes a branch
    /// ("GitHub copy, 11 Nov 14:32") that can be compared and merged like any other, and this
    /// Mac's commits are pushed in its place (`--force-with-lease`: only if the remote is
    /// still where the last fetch saw it).
    func keepBoth(done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let root, available, sync.problem == .diverged else { return done(false) }
        let title = "\(sync.onGitHub ? "GitHub" : "Remote") copy, \(Date().formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
        let status = sync, gitQueue = queue, network = pushQueue
        status.begin(.pushing)
        // The branch and its title are written on the Git queue (the only writer of refs and
        // settings); the pushes run on the network queue.
        gitQueue.async { [weak self] in
            var steps: [Git.Step] = []
            let prepared = Git.keepBothBranch(root, title: title, steps: &steps)
            let start = steps
            network.async { [weak self] in
                var steps = start
                if let prepared {
                    if !Git.keepBothPush(root, prepared, steps: &steps) {
                        gitQueue.sync { _ = Git.run(["branch", "-q", "-D", prepared.copy], in: root) }
                    }
                }
                let all = steps
                let counts = Git.aheadBehind(root)
                Task { @MainActor [weak self] in
                    status.end(.pushing)
                    guard let self, self.root == root else { return }
                    for step in all { self.sync.record(step.command, step.result) }
                    let ok = prepared != nil && all.allSatisfy(\.result.ok)
                    if ok {
                        self.sync.problem = nil
                        self.sync.lastPush = Date()
                        self.rejectedOnce = false
                        self.setPushed(true)
                    } else if let failed = all.last(where: { !$0.result.ok }) {
                        let problem = SyncStatus.problem(from: failed.result)
                        // Still diverged (the remote moved again): leave it to be tried again.
                        self.sync.problem = problem == .diverged ? .diverged : problem
                    }
                    if let counts { self.sync.ahead = counts.ahead; self.sync.behind = counts.behind }
                    self.refresh(remote: false)
                    done(ok)
                }
            }
        }
    }

    func resetSync() {
        // A push still under way belongs to the library just closed; its end is ignored, so
        // say here that none is running (left set, nothing was pushed again until quitting).
        if backingUp { setPushing(false) }
        sync.end(.pulling)
        commitTask?.cancel()
        dirtySince = nil
        pushAgain = false
        pushAfterSync = false
        rejectedOnce = false
        pushWaiters = []
        sync.reset()
    }
}

extension Git {
    struct Step: Sendable {
        let command: String
        let result: Result
    }

    /// Like `push`, with Git's answer: every branch, then the tags. Each branch remembers its
    /// remote counterpart (`-u`), which is how a branch deleted on another Mac is recognised.
    /// Never `--prune`: it would delete branches another Mac pushed and this one hasn't got.
    static func pushResult(_ root: URL, timeout: TimeInterval) -> Result {
        let branches = run(["push", "-q", "-u", "--all", "origin"], in: root, timeout: timeout)
        guard branches.ok else { return branches }
        return run(["push", "-q", "--tags", "origin"], in: root, timeout: timeout)
    }

    private static let deletedKey = "longhand.deleted"

    /// A branch was merged or deleted here: its remote counterpart is to be deleted by name.
    static func noteDeleted(_ root: URL, _ branch: String) {
        run(["config", "--local", "--add", deletedKey, branch], in: root)
    }

    static func pendingDeletes(_ root: URL) -> [String] {
        run(["config", "--local", "--get-all", deletedKey], in: root).output
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func forgetDeleted(_ root: URL, _ branches: [String]) {
        for branch in branches {
            run(["config", "--local", "--fixed-value", "--unset-all", deletedKey, branch], in: root)
        }
    }

    /// Deletes, on the remote, the branches merged or deleted here. A branch already gone
    /// there counts as done.
    static func pushDeletes(_ root: URL, timeout: TimeInterval) -> [(branch: String, result: Result)] {
        pendingDeletes(root).map { branch in
            let result = run(["push", "-q", "origin", "--delete", branch], in: root, timeout: timeout)
            let gone = result.error.contains("remote ref does not exist")
            return (branch, gone ? Result(status: 0, output: "", error: "") : result)
        }
    }

    /// After a fetch, brings this Mac's branches into line with what another Mac did, without
    /// touching the open one (that is `pull`): a branch new on the remote is created here; one
    /// that is only behind is moved up; one deleted on the remote is closed here the way
    /// Delete Branch does (its last commit kept under a `discarded-` tag). True if any changed.
    static func reconcileBranches(_ root: URL) -> Bool {
        let current = currentBranch(root)
        let refs = run(["for-each-ref", "--format=%(refname)%09%(objectname)%09%(upstream:track)",
                        "refs/heads", "refs/remotes/origin"], in: root)
        var heads: [String: (id: String, gone: Bool)] = [:]
        var remotes: [String: String] = [:]
        for line in refs.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            if parts[0].hasPrefix("refs/heads/") {
                heads[String(parts[0].dropFirst("refs/heads/".count))] = (parts[1], parts.count > 2 && parts[2].contains("gone"))
            } else if parts[0].hasPrefix("refs/remotes/origin/"), !parts[0].hasSuffix("/HEAD") {
                remotes[String(parts[0].dropFirst("refs/remotes/origin/".count))] = parts[1]
            }
        }
        let deleted = Set(pendingDeletes(root))
        var changed = false
        for (name, id) in remotes where name != current {
            if let local = heads[name] {
                // Only behind: move it up. Ahead or diverged is left for when it is opened.
                if local.id != id, run(["merge-base", "--is-ancestor", local.id, id], in: root).ok,
                   run(["branch", "-q", "-f", name, "refs/remotes/origin/\(name)"], in: root).ok {
                    changed = true
                }
            } else if name.hasPrefix(rewritePrefix), !deleted.contains(name),
                      run(["branch", "-q", name, "refs/remotes/origin/\(name)"], in: root).ok {
                changed = true
            }
        }
        for (name, local) in heads where local.gone && name != current && name.hasPrefix(rewritePrefix) && remotes[name] == nil {
            let title = String(name.dropFirst(rewritePrefix.count))
            let tag = uniqueTag(root, "discarded-" + VersionStore.tagName(title))
            guard run(["tag", "-a", tag, name, "-m", "Discarded rewrite “\(title)”"], in: root).ok else { continue }
            if run(["branch", "-q", "-D", name], in: root).ok { changed = true }
        }
        return changed
    }

    /// Commits on the open branch that `origin` lacks, and the other way round. Nil when the
    /// branch isn't on the remote yet (or there is no remote).
    static func aheadBehind(_ root: URL) -> (ahead: Int, behind: Int)? {
        guard let branch = currentBranch(root) else { return nil }
        let result = run(["rev-list", "--left-right", "--count", "HEAD...refs/remotes/origin/\(branch)"], in: root)
        let parts = result.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard result.ok, parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// See `VersionStore.pull`. Never leaves a rebase half done.
    static func pull(_ root: URL, message: String) -> (VersionStore.PullOutcome, [Step]) {
        var steps: [Step] = []
        guard let branch = currentBranch(root) else { return (.failed, steps) }
        let remote = "refs/remotes/origin/\(branch)"
        guard run(["rev-parse", "--verify", "-q", remote], in: root).ok,
              let counts = aheadBehind(root) else { return (.upToDate, steps) }
        guard counts.behind > 0 else { return (.upToDate, steps) }
        // Whatever is on disk is committed first, so nothing uncommitted is in the way.
        if commitAll(root, message: message) {
            steps.append(Step(command: "git commit -m \"\(message)\"", result: Result(status: 0, output: "", error: "")))
        }
        let ahead = (aheadBehind(root) ?? counts).ahead
        if ahead == 0 {
            let merged = run(["merge", "-q", "--ff-only", remote], in: root)
            steps.append(Step(command: "git merge --ff-only origin/\(branch)", result: merged))
            return (merged.ok ? .updated : .failed, steps)
        }
        // Tags on the commits about to be replayed (a tag made while offline) are moved to
        // the replayed commits afterwards, so they stay on the branch.
        let before = run(["rev-list", "--reverse", "\(remote)..HEAD"], in: root).output.split(separator: "\n").map(String.init)
        let rebased = run(["rebase", "-q", remote], in: root, timeout: 20)
        steps.append(Step(command: "git rebase origin/\(branch)", result: rebased))
        if rebased.ok {
            let after = run(["rev-list", "--reverse", "\(remote)..HEAD"], in: root).output.split(separator: "\n").map(String.init)
            if before.count == after.count {
                for (old, new) in zip(before, after) where old != new {
                    for tag in run(["tag", "--points-at", old], in: root).output.split(separator: "\n").map(String.init) {
                        let message = run(["tag", "-l", "--format=%(contents)", tag], in: root).output
                        run(["tag", "-f", "-a", tag, new, "-m", message.isEmpty ? tag : message], in: root)
                    }
                }
            }
            return (.updated, steps)
        }
        let aborted = run(["rebase", "--abort"], in: root)
        steps.append(Step(command: "git rebase --abort", result: aborted))
        return (.conflict, steps)
    }

    struct KeepBoth: Sendable {
        let branch: String
        let copy: String
        /// Where the remote branch stood when its copy was made (the force-push's lease).
        let lease: String
    }

    /// See `VersionStore.keepBoth`. The remote's copy as a local branch (Git queue).
    static func keepBothBranch(_ root: URL, title: String, steps: inout [Step]) -> KeepBoth? {
        guard let branch = currentBranch(root) else { return nil }
        let remote = "refs/remotes/origin/\(branch)"
        let existing = Set(rewrites(root).map(\.id))
        var copy = rewritePrefix + VersionStore.tagName(title)
        var n = 2
        while existing.contains(copy) { copy = rewritePrefix + VersionStore.tagName(title) + "-\(n)"; n += 1 }
        let lease = run(["rev-parse", remote], in: root).output
        let made = run(["branch", "--no-track", copy, remote], in: root)
        steps.append(Step(command: "git branch \(copy) origin/\(branch)", result: made))
        guard made.ok, !lease.isEmpty else { return nil }
        run(["config", "--local", "branch.\(copy).description", title], in: root)
        return KeepBoth(branch: branch, copy: copy, lease: lease)
    }

    /// This Mac's commits in the remote branch's place, then everything else (network queue).
    static func keepBothPush(_ root: URL, _ kept: KeepBoth, steps: inout [Step]) -> Bool {
        let forced = run(["push", "-q", "--force-with-lease=\(kept.branch):\(kept.lease)", "origin", kept.branch], in: root, timeout: 60)
        steps.append(Step(command: "git push --force-with-lease origin \(kept.branch)", result: forced))
        guard forced.ok else { return false }
        let rest = pushResult(root, timeout: 60)
        steps.append(Step(command: "git push --all origin", result: rest))
        return true
    }
}
