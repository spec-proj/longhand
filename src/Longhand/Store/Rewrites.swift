import os
import Foundation

/// Rewrites: a big change tried on the side (a Git branch, `rewrite/<name>`), while the main
/// manuscript stays as it was. Switch between them at any time; keep a rewrite (its changes go
/// into the manuscript) or discard it (it's kept as a named version, so it can still be found
/// in Compare Versions).
///
/// Keeping works the merge out with `git merge-tree` first, without touching the files. Where
/// the manuscript and the rewrite both changed the same paragraph, the writer chooses for each
/// passage; the files never contain Git's conflict markers.
struct Rewrite: Identifiable, Equatable, Sendable {
    /// The branch, `rewrite/first-person`.
    let id: String
    let title: String
}

/// Keeping a rewrite whose changes meet changes made to the manuscript since.
struct MergePlan: Equatable, Sendable {
    struct Passage: Identifiable, Equatable, Sendable {
        enum Choice: Sendable { case manuscript, rewrite, both }
        let id: Int
        let manuscript: String
        let rewrite: String
        var choice: Choice = .rewrite

        var resolved: String {
            switch choice {
            case .manuscript: return manuscript
            case .rewrite: return rewrite
            // Manuscript first, then the rewrite, as separate paragraphs.
            case .both:
                guard !manuscript.isEmpty else { return rewrite }
                return manuscript + (manuscript.hasSuffix("\n") ? "\n" : "\n\n") + rewrite
            }
        }
    }

    /// One scene's text: plain pieces and passages to choose between.
    enum Piece: Equatable, Sendable {
        case text(String)
        case passage(Int)
    }

    struct Scene: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String
        /// Nil when the whole scene is a choice (it was removed on one side, changed on the
        /// other): then `wholeManuscript`/`wholeRewrite` hold the two versions (nil = removed).
        let pieces: [Piece]?
        let wholeManuscript: String?
        let wholeRewrite: String?

        var title: String {
            Comparison.SceneChange(path: path, oldPath: nil, status: .changed, segments: [], wordsAdded: 0, wordsRemoved: 0).title
        }
    }

    let rewrite: Rewrite
    /// The merged result with every path that merged cleanly (a tree id).
    let tree: String
    let manuscriptCommit: String
    let rewriteCommit: String
    var scenes: [Scene]
    var passages: [Passage]
    /// For whole-scene choices: path → keep the rewrite's version (true) or the manuscript's.
    var wholeChoices: [String: Bool] = [:]

    var hasConflicts: Bool { !scenes.isEmpty }

    /// The text to write for a scene, or nil to leave it out.
    func resolved(_ scene: Scene) -> String? {
        if let pieces = scene.pieces {
            return pieces.map { piece in
                switch piece {
                case .text(let text): return text
                case .passage(let id): return passages.first { $0.id == id }?.resolved ?? ""
                }
            }.joined()
        }
        return (wholeChoices[scene.path] ?? true) ? scene.wholeRewrite : scene.wholeManuscript
    }
}

extension Git {
    static let rewritePrefix = "rewrite/"

    static func currentBranch(_ root: URL) -> String? {
        let result = run(["symbolic-ref", "--short", "-q", "HEAD"], in: root)
        return result.ok && !result.output.isEmpty ? result.output : nil
    }

    /// The main manuscript's branch: `main`, or what the repository used before Longhand.
    static func manuscriptBranch(_ root: URL) -> String {
        if let known = manuscriptCache.withLock({ $0[root.path] }) { return known }
        let configured = run(["config", "--get", "longhand.manuscript"], in: root).output
        if !configured.isEmpty {
            manuscriptCache.withLock { $0[root.path] = configured }
            return configured
        }
        if run(["rev-parse", "--verify", "-q", "refs/heads/main"], in: root).ok { return "main" }
        if run(["rev-parse", "--verify", "-q", "refs/heads/master"], in: root).ok { return "master" }
        return currentBranch(root) ?? "main"
    }

    /// The manuscript's branch per library, once read or set (it only changes when Longhand
    /// sets it, below), so each switch doesn't ask Git again.
    private static let manuscriptCache = OSAllocatedUnfairLock(initialState: [String: String]())

    static func rewrites(_ root: URL) -> [Rewrite] {
        branchState(root).rewrites
    }

    /// The branch that's open and every rewrite, newest first, in two Git calls (one listed
    /// every branch, then one more call per rewrite read its title).
    static func branchState(_ root: URL) -> (current: String?, rewrites: [Rewrite]) {
        // Name, a tab, then "*" on the open branch. (The marker goes last: `run` trims the
        // output, and a leading space marking "not open" would be trimmed off the first line.)
        let refs = run(["for-each-ref", "refs/heads", "--sort=-committerdate", "--format=%(refname:short)%09%(HEAD)"], in: root)
        var current: String?
        var branches: [String] = []
        for line in refs.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first else { continue }
            let name = String(first)
            if parts.count > 1, parts[1].trimmingCharacters(in: .whitespaces) == "*" { current = name }
            if name.hasPrefix(rewritePrefix) { branches.append(name) }
        }
        var titles: [String: String] = [:]
        if !branches.isEmpty {
            // "branch.rewrite/first-person.description First person", one per line.
            let config = run(["config", "--get-regexp", #"^branch\..*\.description$"#], in: root).output
            for line in config.split(separator: "\n") {
                guard let space = line.firstIndex(of: " ") else { continue }
                let key = line[..<space]
                guard key.hasPrefix("branch."), key.hasSuffix(".description") else { continue }
                let branch = String(key.dropFirst("branch.".count).dropLast(".description".count))
                titles[branch] = String(line[line.index(after: space)...])
            }
        }
        let rewrites = branches.map { branch in
            Rewrite(id: branch, title: titles[branch] ?? String(branch.dropFirst(rewritePrefix.count)))
        }
        return (current, rewrites)
    }

    /// Saves what's there as a version, then makes a rewrite from it and moves onto it.
    static func startRewrite(_ root: URL, title: String) -> Rewrite? {
        commitAll(root, message: "Before starting the rewrite “\(title)”")
        let existing = Set(rewrites(root).map(\.id))
        var branch = rewritePrefix + VersionStore.tagName(title)
        var n = 2
        while existing.contains(branch) { branch = rewritePrefix + VersionStore.tagName(title) + "-\(n)"; n += 1 }
        if run(["config", "--get", "longhand.manuscript"], in: root).output.isEmpty, let current = currentBranch(root),
           !current.hasPrefix(rewritePrefix) {
            run(["config", "--local", "longhand.manuscript", current], in: root)
            manuscriptCache.withLock { $0[root.path] = current }
        }
        guard run(["switch", "-q", "-c", branch], in: root).ok else { return nil }
        run(["config", "--local", "branch.\(branch).description", title], in: root)
        return Rewrite(id: branch, title: title)
    }

    /// Saves what's there as a version, then moves to `branch` (the files change to match).
    static func switchTo(_ root: URL, branch: String, note: String) -> Bool {
        commitAll(root, message: note)
        return run(["switch", "-q", branch], in: root).ok
    }

    /// Works out keeping `rewrite` in the manuscript, without touching any file.
    static func planKeep(_ root: URL, _ rewrite: Rewrite) -> MergePlan? {
        let manuscript = manuscriptBranch(root)
        commitAll(root, message: "Before keeping the rewrite “\(rewrite.title)”")
        let ids = run(["rev-parse", manuscript, rewrite.id], in: root).output.split(separator: "\n").map(String.init)
        guard ids.count == 2, !ids[0].isEmpty, !ids[1].isEmpty else { return nil }
        let ours = ids[0], theirs = ids[1]
        let merged = run(["-c", "merge.conflictStyle=merge", "merge-tree", "--write-tree", "-z", "--name-only", ours, theirs], in: root)
        // Status 0: clean; 1: conflicts. Output: tree id, then the conflicted paths, each
        // ending in NUL, then an empty field and messages.
        guard merged.status == 0 || merged.status == 1 else { return nil }
        let fields = merged.output.components(separatedBy: "\0")
        guard let tree = fields.first, !tree.isEmpty else { return nil }
        var paths: [String] = []
        for field in fields.dropFirst() {
            if field.isEmpty { break }
            if !paths.contains(field) { paths.append(field) }
        }

        var plan = MergePlan(rewrite: rewrite, tree: tree, manuscriptCommit: ours, rewriteCommit: theirs,
                             scenes: [], passages: [])
        let texts = blobs(root, paths.flatMap { ["\(tree):\($0)", "\(ours):\($0)", "\(theirs):\($0)"] })
        for path in paths {
            let inTree = texts["\(tree):\(path)"]
            if let inTree, inTree.contains("<<<<<<< ") {
                let pieces = parseConflicts(inTree, startingAt: plan.passages.count)
                plan.passages += pieces.passages
                plan.scenes.append(.init(path: path, pieces: pieces.pieces, wholeManuscript: nil, wholeRewrite: nil))
            } else {
                plan.scenes.append(.init(path: path, pieces: nil,
                                         wholeManuscript: texts["\(ours):\(path)"], wholeRewrite: texts["\(theirs):\(path)"]))
            }
        }
        return plan
    }

    /// Splits a file with conflict markers into plain text and passages.
    static func parseConflicts(_ text: String, startingAt first: Int) -> (pieces: [MergePlan.Piece], passages: [MergePlan.Passage]) {
        var pieces: [MergePlan.Piece] = []
        var passages: [MergePlan.Passage] = []
        var plain = ""
        var ours = "", theirs = ""
        enum Side { case none, ours, base, theirs }
        var side = Side.none
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            switch side {
            case .none:
                if line.hasPrefix("<<<<<<< ") {
                    if !plain.isEmpty { pieces.append(.text(plain)); plain = "" }
                    side = .ours
                } else {
                    plain += line + "\n"
                }
            case .ours:
                if line.hasPrefix("||||||| ") { side = .base }
                else if line == "=======" { side = .theirs }
                else { ours += line + "\n" }
            case .base:
                if line == "=======" { side = .theirs }
            case .theirs:
                if line.hasPrefix(">>>>>>> ") {
                    let id = first + passages.count
                    passages.append(.init(id: id, manuscript: ours, rewrite: theirs))
                    pieces.append(.passage(id))
                    ours = ""; theirs = ""
                    side = .none
                } else {
                    theirs += line + "\n"
                }
            }
        }
        // Each line got a newline back; the last one never had one.
        if plain.hasSuffix("\n") { plain.removeLast() }
        if !plain.isEmpty { pieces.append(.text(plain)) }
        return (pieces, passages)
    }

    /// Records the merge as a version on the manuscript (two parents), moves onto the
    /// manuscript, and closes the rewrite.
    static func finishKeep(_ root: URL, _ plan: MergePlan) -> Bool {
        let manuscript = manuscriptBranch(root)
        var tree = plan.tree
        if plan.hasConflicts {
            let index = FileManager.default.temporaryDirectory.appendingPathComponent("longhand-index-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: index) }
            let env = ["GIT_INDEX_FILE": index.path]
            guard run(["read-tree", plan.tree], in: root, environment: env).ok else { return false }
            for scene in plan.scenes {
                if let text = plan.resolved(scene) {
                    let blob = Process.captureData(executable, ["hash-object", "-w", "--stdin"], in: root, timeout: 30,
                                                   input: Data(text.utf8))
                    let id = String(decoding: blob.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard blob.status == 0, !id.isEmpty else { return false }
                    // Clears the conflict stages and puts the chosen text in their place.
                    run(["update-index", "--force-remove", scene.path], in: root, environment: env)
                    guard run(["update-index", "--add", "--cacheinfo", "100644,\(id),\(scene.path)"], in: root, environment: env).ok else { return false }
                } else {
                    run(["update-index", "--force-remove", scene.path], in: root, environment: env)
                }
            }
            let written = run(["write-tree"], in: root, environment: env)
            guard written.ok, !written.output.isEmpty else { return false }
            tree = written.output
        }
        let commit = run(["commit-tree", tree, "-p", plan.manuscriptCommit, "-p", plan.rewriteCommit,
                          "-m", "Kept the rewrite “\(plan.rewrite.title)”"], in: root)
        guard commit.ok, !commit.output.isEmpty else { return false }
        // Point the manuscript at the merge and move onto it, in one call (the Git queue is the
        // only writer, so the manuscript can't have moved since the plan was made).
        guard run(["switch", "-q", "-C", manuscript, commit.output], in: root).ok else { return false }
        // Deleting a branch also removes its settings (its title).
        run(["branch", "-q", "-D", plan.rewrite.id], in: root)
        noteDeleted(root, plan.rewrite.id)
        return true
    }

    /// Moves back to the manuscript and closes the rewrite, naming its last version
    /// "Discarded: <title>" so it can still be compared or restored.
    static func discard(_ root: URL, _ rewrite: Rewrite) -> Bool {
        commitAll(root, message: "Last of the rewrite “\(rewrite.title)”")
        let name = uniqueTag(root, "discarded-" + VersionStore.tagName(rewrite.title))
        guard run(["tag", "-a", name, rewrite.id, "-m", "Discarded rewrite “\(rewrite.title)”"], in: root).ok else { return false }
        guard run(["switch", "-q", manuscriptBranch(root)], in: root).ok else { return false }
        // Deleting a branch also removes its settings (its title).
        run(["branch", "-q", "-D", rewrite.id], in: root)
        noteDeleted(root, rewrite.id)
        return true
    }
}
