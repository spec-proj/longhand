import Foundation

/// Versions belong to scenes (owner, 2026-11-08): a version is an intentional save of a scene,
/// with an optional note, numbered per scene (v1, v2, v3).
///
/// Underneath it is still Git, and every commit is still a snapshot of the whole library (so
/// renames, backups and rewrites work as before). What makes a commit a *version* of a scene:
///
/// - A commit whose message names scenes in `Longhand-Version: <path>` lines is a version of
///   those scenes only (Save Version, Save Versions for a chapter or book, Mark as Draft).
/// - Longhand's automatic commits (quitting, switching to a rewrite, before a restore …) are
///   never versions; they appear in a scene's history as automatic copies.
/// - Older commits made before this (the library-wide versions) are versions of the scenes
///   they changed, and the first commit is v1 of every scene in it.
struct SceneHistoryEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case version, automatic }
    var id: String { commit }
    let commit: String
    let date: Date
    /// The note (versions) or what happened (automatic copies).
    let note: String
    let kind: Kind
    /// 3 for v3; nil for an automatic copy.
    let number: Int?
    /// The scene's path in that commit (it may have been renamed or moved since).
    let path: String
    /// Draft names (tags) on the commit.
    let drafts: [String]
}

extension SceneHistoryEntry {
    /// The commit's id as GitHub shortens it: the first seven characters.
    var shortID: String { String(commit.prefix(7)) }
}

enum SceneVersions {
    static let trailer = "Longhand-Version: "

    /// What Longhand writes for its own automatic commits (never versions).
    static let automaticPrefixes = [
        "Writing session", "Switched from", "Before restoring", "Before changing ", "Restored ", "Before starting the rewrite",
        "Before keeping the rewrite", "Last of the rewrite", "Kept the rewrite", "Merge", "Auto-commit",
    ]

    /// A commit message for versions of these scenes.
    static func message(note: String, scenes: [String]) -> String {
        let subject = note.isEmpty ? (scenes.count == 1 ? "Saved version" : "Saved versions") : note
        return subject + "\n\n" + scenes.map { trailer + $0 }.joined(separator: "\n")
    }

    /// The note to show: the subject, unless it is only the default.
    static func shownNote(_ subject: String) -> String {
        subject == "Saved version" || subject == "Saved versions" ? "" : subject
    }

    /// The note to show in lists of versions: automatic ones in plain words.
    static func listedNote(_ subject: String) -> String {
        if subject.hasPrefix("Writing session") { return "Commit on quit" }
        if subject.hasPrefix("Auto-commit") { return "Auto-commit" }
        if subject.hasPrefix("Merge") { return "Merged a branch" }
        if subject.hasPrefix("Last of the rewrite ") {
            return "Branch " + subject.dropFirst("Last of the rewrite ".count) + " as it ended"
        }
        return shownNote(subject)
    }
}

extension Git {
    /// Every current scene's history (newest first), found in one walk of the log: renames are
    /// followed, so a scene keeps its versions after it is renamed or moved.
    /// `scenes` are the scenes on disk now, as paths relative to the library.
    static func sceneHistories(_ root: URL, scenes: [String]) -> [String: [SceneHistoryEntry]] {
        let record = "\u{1e}", field = "\u{1f}"
        let result = run(["-c", "core.quotePath=false", "log", "-M30%", "--name-status", "-z",
                          "--format=\(record)%H\(field)%ct\(field)%D\(field)%B\(field)"], in: root, timeout: 60)
        guard result.ok else { return [:] }

        struct Commit {
            let id: String
            let date: Date
            let subject: String
            let trailers: Set<String>
            let drafts: [String]
            /// (status letter, old path, new path)
            let entries: [(Character, String?, String?)]
        }
        var commits: [Commit] = []
        for chunk in result.output.components(separatedBy: record) where !chunk.isEmpty {
            let parts = chunk.components(separatedBy: field)
            guard parts.count >= 5, let seconds = TimeInterval(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            let body = parts[3]
            let subject = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            var trailers = Set<String>()
            for line in body.split(separator: "\n") where line.hasPrefix(SceneVersions.trailer) {
                trailers.insert(String(line.dropFirst(SceneVersions.trailer.count)).trimmingCharacters(in: .whitespaces))
            }
            let drafts = parts[2].components(separatedBy: ", ").filter { $0.hasPrefix("tag: ") }.map { String($0.dropFirst(5)) }
            // The name-status part: NUL-separated status, path (and a second path for renames).
            var tokens = parts[4...].joined(separator: field).components(separatedBy: "\0")
                .map { $0.trimmingCharacters(in: .newlines) }
            tokens.removeAll { $0.isEmpty }
            var entries: [(Character, String?, String?)] = []
            var index = 0
            while index < tokens.count {
                let status = tokens[index]
                index += 1
                guard let letter = status.first else { continue }
                switch letter {
                case "R", "C":
                    guard index + 1 < tokens.count else { index = tokens.count; break }
                    entries.append((letter, tokens[index], tokens[index + 1])); index += 2
                case "D":
                    guard index < tokens.count else { break }
                    entries.append((letter, tokens[index], nil)); index += 1
                default:
                    guard index < tokens.count else { break }
                    entries.append((letter, nil, tokens[index])); index += 1
                }
            }
            commits.append(Commit(id: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                  date: Date(timeIntervalSince1970: seconds), subject: subject,
                                  trailers: trailers, drafts: drafts, entries: entries))
        }

        // Newest to oldest, following each scene's path back through renames.
        var alias: [String: String] = [:]            // current path → path in the commit being read
        for scene in scenes { alias[scene] = scene }
        var found: [String: [(entry: Commit, path: String, version: Bool)]] = [:]
        for commit in commits {
            let automatic = commit.trailers.isEmpty && SceneVersions.automaticPrefixes.contains { commit.subject.hasPrefix($0) }
            var touched: [String: (Character, String?)] = [:]
            for (letter, old, new) in commit.entries { if let new { touched[new] = (letter, old) } }
            for (scene, path) in alias {
                let change = touched[path]
                let version: Bool
                if !commit.trailers.isEmpty {
                    version = commit.trailers.contains(path)
                } else if automatic {
                    version = false
                } else {
                    // Older versions count for the scenes they changed (the first commit lists
                    // every scene it holds as added).
                    version = change != nil
                }
                if version || change != nil {
                    found[scene, default: []].append((commit, path, version))
                }
                if let (letter, old) = change {
                    if letter == "R" || letter == "C", let old { alias[scene] = old }
                    if letter == "A" { alias[scene] = nil }
                }
            }
        }

        var histories: [String: [SceneHistoryEntry]] = [:]
        for (scene, list) in found {
            let total = list.filter(\.version).count
            var number = total
            histories[scene] = list.map { item in
                let entry = SceneHistoryEntry(
                    commit: item.entry.id, date: item.entry.date,
                    note: item.version ? SceneVersions.shownNote(item.entry.subject) : item.entry.subject,
                    kind: item.version ? .version : .automatic,
                    number: item.version ? number : nil, path: item.path, drafts: item.entry.drafts)
                if item.version { number -= 1 }
                return entry
            }
        }
        return histories
    }

    /// Every scene on disk now, relative to the library.
    static func scenesOnDisk(_ root: URL) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        // A folder of books adds one level: "Folder/Book/Chapter/Scene.md".
        let groups = LibraryFolders.groups(in: root)
        var books: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !name.hasPrefix(".") {
            if groups.contains(name) {
                let inside = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(name).path)) ?? []
                books += inside.filter { !$0.hasPrefix(".") }.map { "\(name)/\($0)" }
            } else {
                books.append(name)
            }
        }
        for book in books {
            let bookURL = root.appendingPathComponent(book)
            for chapter in (try? fm.contentsOfDirectory(atPath: bookURL.path)) ?? [] where !chapter.hasPrefix(".") && chapter != "Notes" && chapter != StoryFolders.boneyard {
                // Scenes only, or one document: Markdown files straight in the story's folder.
                if ProseFile.isProse(chapter) {
                    paths.append("\(book)/\(chapter)")
                    continue
                }
                let chapterURL = bookURL.appendingPathComponent(chapter)
                for scene in (try? fm.contentsOfDirectory(atPath: chapterURL.path)) ?? [] where ProseFile.isProse(scene) {
                    paths.append("\(book)/\(chapter)/\(scene)")
                }
            }
        }
        return paths
    }

    /// Commits a snapshot of the library that is a version of `scenes`, even when nothing else
    /// changed since the last commit (a quit may already have recorded the text).
    @discardableResult
    static func commitVersions(_ root: URL, scenes: [String], note: String) -> Bool {
        guard !scenes.isEmpty, run(["add", "-A"], in: root).ok else { return false }
        return run(["commit", "-q", "--no-verify", "--allow-empty", "-m", SceneVersions.message(note: note, scenes: scenes)], in: root).ok
    }
}

extension Git {
    /// Each scene compared with its own last version: the changed ones (with their words),
    /// new ones (no version yet) and deleted ones; and every scene's history.
    static func sceneChanges(_ root: URL) -> (changes: [Comparison.SceneChange], histories: [String: [SceneHistoryEntry]]) {
        let onDisk = scenesOnDisk(root)
        let present = Set(onDisk)
        // Scenes the last commit had that are gone now: deleted, or renamed and not yet recorded.
        let listed = run(["-c", "core.quotePath=false", "ls-tree", "-r", "-z", "--name-only", "HEAD"], in: root)
        let gone = listed.ok ? listed.output.components(separatedBy: "\0").filter { isScene($0) && !present.contains($0) } : []
        var histories = sceneHistories(root, scenes: onDisk + gone)

        func baseline(_ history: [SceneHistoryEntry]?) -> SceneHistoryEntry? { history?.first { $0.kind == .version } }
        var requests: [String] = []
        for scene in onDisk + gone { if let base = baseline(histories[scene]) { requests.append("\(base.commit):\(base.path)") } }
        let old = blobs(root, requests)
        func oldText(_ scene: String) -> String? {
            baseline(histories[scene]).flatMap { old["\($0.commit):\($0.path)"] }
        }
        func now(_ scene: String) -> String {
            String.prose(at: root.appendingPathComponent(scene)) ?? ""
        }

        // A new scene whose text is mostly that of a vanished one was renamed or moved: it keeps
        // the vanished one's history.
        var vanished = gone.filter { oldText($0) != nil }
        var renamedFrom: [String: String] = [:]
        for scene in onDisk where baseline(histories[scene]) == nil && !vanished.isEmpty {
            let text = now(scene)
            if let match = vanished.first(where: { candidate in
                let segments = WordDiff.segments(from: oldText(candidate) ?? "", to: text)
                let same = WordDiff.words(in: segments, .same)
                let total = same + WordDiff.words(in: segments, .removed)
                return total > 0 && Double(same) / Double(total) > 0.6
            }) {
                renamedFrom[scene] = match
                histories[scene] = histories[match]
                vanished.removeAll { $0 == match }
            }
        }

        var changes = [Comparison.SceneChange?](repeating: nil, count: onDisk.count)
        changes.withUnsafeMutableBufferPointer { slots in
            nonisolated(unsafe) let slots = slots
            DispatchQueue.concurrentPerform(iterations: onDisk.count) { index in
                let scene = onDisk[index]
                let text = now(scene)
                guard let before = oldText(scene) else {
                    let segments: [Comparison.Segment] = text.isEmpty ? [] : [.init(kind: .added, text: text)]
                    slots[index] = .init(path: scene, oldPath: nil, status: .added, segments: segments,
                                         wordsAdded: WordDiff.words(in: segments, .added), wordsRemoved: 0)
                    return
                }
                let basePath = baseline(histories[scene])?.path
                let moved = basePath != nil && basePath != scene
                guard !(before as NSString).isEqual(to: text) else {
                    if moved {
                        slots[index] = .init(path: scene, oldPath: basePath, status: .changed,
                                             segments: [.init(kind: .same, text: text)], wordsAdded: 0, wordsRemoved: 0)
                    }
                    return
                }
                let segments = WordDiff.segments(from: before, to: text)
                slots[index] = .init(path: scene, oldPath: moved ? basePath : nil, status: .changed, segments: segments,
                                     wordsAdded: WordDiff.words(in: segments, .added),
                                     wordsRemoved: WordDiff.words(in: segments, .removed))
            }
        }
        var result = changes.compactMap { $0 }
        for scene in vanished {
            let before = oldText(scene) ?? ""
            let segments: [Comparison.Segment] = before.isEmpty ? [] : [.init(kind: .removed, text: before)]
            result.append(.init(path: scene, oldPath: scene, status: .removed, segments: segments,
                                wordsAdded: 0, wordsRemoved: WordDiff.words(in: segments, .removed)))
        }
        return (result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, histories)
    }
}

extension Git {
    /// The scenes changed since their last versions (new ones included), worked out now.
    /// Texts only, no word counts: this runs as a version is saved.
    static func changedScenes(_ root: URL) -> [String] {
        let onDisk = scenesOnDisk(root)
        let histories = sceneHistories(root, scenes: onDisk)
        var baselines: [String: String] = [:]
        for scene in onDisk {
            if let base = histories[scene]?.first(where: { $0.kind == .version }) { baselines[scene] = "\(base.commit):\(base.path)" }
        }
        let old = blobs(root, Array(baselines.values))
        return onDisk.filter { scene in
            guard let key = baselines[scene], let before = old[key] else { return true }
            let now = String.prose(at: root.appendingPathComponent(scene)) ?? ""
            return !(before as NSString).isEqual(to: now)
        }
    }
}
