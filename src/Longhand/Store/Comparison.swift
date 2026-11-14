import Foundation

/// What changed in the manuscript between two versions (or a version and the library as it is
/// now), word by word. Scenes only: notes, comments and settings are left out.
///
/// Git finds which scenes changed (and follows a scene that was renamed or moved, so a
/// reorder isn't shown as every scene deleted and written again); the words are compared
/// here, so a changed comma marks one word, not the whole paragraph.
struct Comparison: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        enum Kind: Sendable { case same, added, removed }
        let kind: Kind
        let text: String
    }

    struct SceneChange: Identifiable, Equatable, Sendable {
        enum Status: Sendable { case changed, added, removed }
        var id: String { path }
        /// The scene's path in the newer version (the older one, if it was removed).
        let path: String
        let oldPath: String?
        let status: Status
        let segments: [Segment]
        let wordsAdded: Int
        let wordsRemoved: Int

        /// "Chapter › Scene", without the order numbers.
        var title: String {
            let parts = path.split(separator: "/").map(String.init)
            let names = parts.suffix(2).map { part -> String in
                let base = part.lowercased().hasSuffix(".md") ? String(part.dropLast(3)) : part
                return FileNaming.decode(base).title
            }
            return names.joined(separator: " › ")
        }

        /// True if the scene only moved or was renamed, with its words untouched.
        var onlyMoved: Bool { wordsAdded == 0 && wordsRemoved == 0 && status == .changed }
    }

    let scenes: [SceneChange]

    var wordsAdded: Int { scenes.reduce(0) { $0 + $1.wordsAdded } }
    var wordsRemoved: Int { scenes.reduce(0) { $0 + $1.wordsRemoved } }
}

// MARK: - Finding the changes

extension Git {
    /// Compares two versions (commit ids); `to: nil` means the library as it is now.
    /// `now` is a snapshot of the library already taken with `snapshotTree` (or nil to take
    /// one). `workingTree` compares with the files as they are instead, which is right (and two
    /// Git calls quicker) when Git already knows every scene (`untrackedScenes` is empty):
    /// a snapshot is only needed to see new and renamed scenes.
    static func compare(_ root: URL, from: String, to: String?, now: String? = nil, workingTree: Bool = false) -> Comparison {
        let listing: Result
        if to == nil, workingTree {
            listing = run(["diff", "-z", "--name-status", "-M", "--no-ext-diff", from, "--", "*.md"], in: root)
        } else {
            guard let newer = to ?? now ?? snapshotTree(root) else { return Comparison(scenes: []) }
            listing = run(["diff", "-z", "--name-status", "-M", "--no-ext-diff", from, newer, "--", "*.md"], in: root)
        }
        guard listing.ok else { return Comparison(scenes: []) }

        var fields = listing.output.components(separatedBy: "\0")
        if fields.last == "" { fields.removeLast() }
        var entries: [(old: String?, new: String?)] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            index += 1
            var oldPath: String?
            var newPath: String?
            switch status.first {
            case "R", "C":
                guard index + 1 < fields.count else { break }
                oldPath = fields[index]; newPath = fields[index + 1]; index += 2
            case "A":
                guard index < fields.count else { break }
                newPath = fields[index]; index += 1
            case "D":
                guard index < fields.count else { break }
                oldPath = fields[index]; index += 1
            default:
                guard index < fields.count else { break }
                oldPath = fields[index]; newPath = fields[index]; index += 1
            }
            let path = newPath ?? oldPath ?? ""
            guard isScene(path) || (oldPath.map(isScene) ?? false) else { continue }
            entries.append((oldPath, newPath))
        }

        // Git pairs a renamed file with its old name only when most of the text is the same. A
        // short scene that was renumbered and rewritten would show as removed and added; pair
        // those by chapter folder and title instead.
        func key(_ path: String) -> String {
            let parts = path.split(separator: "/").map(String.init)
            guard (2...4).contains(parts.count), let last = parts.last else { return path }
            let base = last.lowercased().hasSuffix(".md") ? String(last.dropLast(3)) : last
            return parts.dropLast().joined(separator: "/") + "/" + FileNaming.decode(base).title
        }
        var removedAt: [String: Int] = [:]
        for (i, entry) in entries.enumerated() where entry.new == nil {
            if let old = entry.old { removedAt[key(old)] = i }
        }
        var dropped = Set<Int>()
        for (i, entry) in entries.enumerated() where entry.old == nil {
            guard let new = entry.new, let j = removedAt.removeValue(forKey: key(new)) else { continue }
            entries[i].old = entries[j].old
            dropped.insert(j)
        }

        // Every text in one Git call; "now" is read straight from the files.
        let kept = entries.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        var requests: [String] = kept.compactMap { $0.old.map { "\(from):\($0)" } }
        if let to { requests += kept.compactMap { $0.new.map { "\(to):\($0)" } } }
        let texts = blobs(root, requests)

        // Each scene's word diff is independent: spread them over the cores.
        var results = [Comparison.SceneChange?](repeating: nil, count: kept.count)
        results.withUnsafeMutableBufferPointer { slots in
            nonisolated(unsafe) let slots = slots
            DispatchQueue.concurrentPerform(iterations: kept.count) { index in
                let entry = kept[index]
                let oldText = entry.old.map { texts["\(from):\($0)"] ?? "" } ?? ""
                let newText = entry.new.map { path -> String in
                    if let to { return texts["\(to):\(path)"] ?? "" }
                    return String.prose(at: root.appendingPathComponent(path)) ?? ""
                } ?? ""
                let segments = WordDiff.segments(from: oldText, to: newText)
                let kind: Comparison.SceneChange.Status = entry.new == nil ? .removed : entry.old == nil ? .added : .changed
                slots[index] = .init(
                    path: entry.new ?? entry.old ?? "",
                    oldPath: entry.old == entry.new ? nil : entry.old,
                    status: kind,
                    segments: segments,
                    wordsAdded: WordDiff.words(in: segments, .added),
                    wordsRemoved: WordDiff.words(in: segments, .removed)
                )
            }
        }
        let changes = results.compactMap { $0 }
        return Comparison(scenes: changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    /// A scene is `Book/Chapter/Scene.md`, or `Folder/Book/Chapter/Scene.md` for a book kept
    /// in a folder; a scenes-only story's scene or a single document is `Book/Scene.md` (or
    /// `Folder/Book/Scene.md`). A book's `Notes` folder holds notes, not scenes.
    static func isScene(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard (2...4).contains(parts.count) else { return false }
        return !parts[0].hasPrefix(".") && !parts.dropFirst().dropLast().contains("Notes")
            && parts[parts.count - 1].lowercased().hasSuffix(".md")
    }

    /// Scenes Git doesn't know yet (new, or renamed since the last version).
    static func untrackedScenes(_ root: URL) -> Bool {
        let result = run(["ls-files", "--others", "--exclude-standard", "-z", "--", "*.md"], in: root)
        return !result.ok || result.output.split(separator: "\0").contains { isScene(String($0)) }
    }

    /// The library as it is now, recorded as a Git tree without touching the real index, so
    /// new and renamed scenes are found as well as edited ones.
    static func snapshotTree(_ root: URL) -> String? {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("longhand-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        // Start from a copy of the real index (the way `git stash` and autosave tools do): it
        // remembers each file's size and date, so `add -A` re-reads only the files that
        // changed. `read-tree` forgot that and made Git read every scene again.
        let real = root.appendingPathComponent(".git/index")
        if (try? FileManager.default.copyItem(at: real, to: index)) == nil, hasCommits(root) {
            run(["read-tree", "HEAD"], in: root, environment: env)
        }
        guard run(["add", "-A"], in: root, environment: env).ok else { return nil }
        let tree = run(["write-tree"], in: root, environment: env)
        return tree.ok && !tree.output.isEmpty ? tree.output : nil
    }

    /// Reads many `revision:path` texts with one `git cat-file --batch`.
    static func blobs(_ root: URL, _ requests: [String]) -> [String: String] {
        guard !requests.isEmpty else { return [:] }
        let input = Data((requests.joined(separator: "\n") + "\n").utf8)
        let result = Process.captureData(executable, ["cat-file", "--batch"], in: root, timeout: 60, input: input)
        guard result.status == 0 else { return [:] }
        let data = result.output
        var texts: [String: String] = [:]
        var cursor = data.startIndex
        for request in requests {
            guard let newline = data[cursor...].firstIndex(of: 0x0A) else { break }
            let header = String(decoding: data[cursor..<newline], as: UTF8.self).split(separator: " ")
            cursor = data.index(after: newline)
            // "<sha> blob <size>", or "<name> missing".
            guard header.count == 3, let size = Int(header[2]) else { continue }
            let end = data.index(cursor, offsetBy: size)
            texts[request] = String(decoding: data[cursor..<end], as: UTF8.self)
            cursor = data.index(after: end)
        }
        return texts
    }

    static func show(_ root: URL, _ revision: String, _ path: String) -> String {
        // Not `run`: its output is trimmed, and a scene's own spacing must be kept.
        let result = Process.capture(executable, ["cat-file", "blob", "\(revision):\(path)"], in: root,
                                     timeout: 30, trim: false)
        return result.ok ? result.output : ""
    }

    /// Every version, newest first, with the names of drafts.
    static func allVersions(_ root: URL, limit: Int = 500) -> (points: [VersionStore.SavePoint], draftTitles: [String: String]) {
        let points = limit > 0 ? recent(root, limit: limit) : []
        let sep = "\u{1f}"
        let refs = run(["for-each-ref", "refs/tags", "--format=%(refname:short)\(sep)%(contents:subject)"], in: root)
        var titles: [String: String] = [:]
        for line in refs.output.split(separator: "\n") {
            let parts = line.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            let subject = parts[1].components(separatedBy: ": ").first ?? ""
            titles[parts[0]] = subject.isEmpty ? parts[0] : subject
        }
        return (points, titles)
    }
}

// MARK: - Comparing words

enum WordDiff {
    /// Words and the spaces between them, as separate pieces, so spacing changes don't swallow
    /// the words around them.
    static func tokens(_ text: String) -> [Substring] {
        var tokens: [Substring] = []
        var start = text.startIndex
        var inSpace: Bool?
        for index in text.indices {
            let space = text[index].isWhitespace
            if let current = inSpace, current != space {
                tokens.append(text[start..<index])
                start = index
            }
            inSpace = space
        }
        if start < text.endIndex { tokens.append(text[start...]) }
        return tokens
    }

    /// Compares paragraph by paragraph first, then word by word inside the paragraphs that
    /// changed: much less work than comparing the whole scene word by word, and it keeps an
    /// edit inside the paragraph it belongs to.
    static func segments(from old: String, to new: String) -> [Comparison.Segment] {
        var out: [Comparison.Segment] = []
        func emit(_ kind: Comparison.Segment.Kind, _ text: Substring) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.kind == kind {
                out[out.count - 1] = .init(kind: kind, text: last.text + text)
            } else {
                out.append(.init(kind: kind, text: String(text)))
            }
        }

        let a = paragraphs(old), b = paragraphs(new)
        let (removed, inserted) = changes(a, b)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            // A run of changed paragraphs: pair them up in order and compare their words.
            var gone: [Substring] = [], come: [Substring] = []
            while i < a.count, removed.contains(i) { gone.append(a[i]); i += 1 }
            while j < b.count, inserted.contains(j) { come.append(b[j]); j += 1 }
            if gone.isEmpty && come.isEmpty {
                guard i < a.count, j < b.count else { break }
                emit(.same, b[j]); i += 1; j += 1
                continue
            }
            let pairs = min(gone.count, come.count)
            for k in 0..<pairs { words(from: gone[k], to: come[k], into: emit) }
            for k in pairs..<gone.count { emit(.removed, gone[k]) }
            for k in pairs..<come.count { emit(.added, come[k]) }
        }
        return out
    }

    /// Lines, each with its newline.
    private static func paragraphs(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        var start = text.startIndex
        var index = start
        while index < text.endIndex {
            if text[index] == "\n" {
                let next = text.index(after: index)
                lines.append(text[start..<next])
                start = next
            }
            index = text.index(after: index)
        }
        if start < text.endIndex { lines.append(text[start...]) }
        return lines
    }

    /// Which items were removed from `a` and inserted into `b`, compared as numbers (fast).
    static func changes(_ a: [Substring], _ b: [Substring]) -> (Set<Int>, Set<Int>) {
        var ids: [Substring: Int] = [:]
        func id(_ s: Substring) -> Int {
            if let known = ids[s] { return known }
            ids[s] = ids.count
            return ids.count - 1
        }
        let x = a.map(id), y = b.map(id)
        // Common start and end first: most edits touch a little in the middle.
        var head = 0
        while head < x.count, head < y.count, x[head] == y[head] { head += 1 }
        var tail = 0
        while tail < x.count - head, tail < y.count - head, x[x.count - 1 - tail] == y[y.count - 1 - tail] { tail += 1 }
        let middleA = Array(x[head..<(x.count - tail)]), middleB = Array(y[head..<(y.count - tail)])
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in middleB.difference(from: middleA) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset + head)
            case .insert(let offset, _, _): inserted.insert(offset + head)
            }
        }
        return (removed, inserted)
    }

    private static func words(from old: Substring, to new: Substring,
                              into emit: (Comparison.Segment.Kind, Substring) -> Void) {
        let a = tokens(String(old)), b = tokens(String(new))
        let (removed, inserted) = changes(a, b)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                emit(.removed, a[i]); i += 1
            } else if j < b.count, inserted.contains(j) {
                emit(.added, b[j]); j += 1
            } else if i < a.count, j < b.count {
                emit(.same, b[j]); i += 1; j += 1
            } else {
                break
            }
        }
    }

    static func words(in segments: [Comparison.Segment], _ kind: Comparison.Segment.Kind) -> Int {
        segments.filter { $0.kind == kind }.reduce(0) { $0 + LiveCount.words(in: $1.text as NSString) }
    }
}
