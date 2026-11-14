import Foundation

/// What changed since the last version, for the whole library: which scenes, by how many
/// words, where the writer is (the manuscript or a rewrite) and whether everything is backed
/// up. Shown in the status bar, as marks in the contents, in the margin's Changes tab and as
/// bars beside the paragraphs on the page.
///
/// `VersionStore` fills it in the background a moment after each save (never while typing),
/// and after every version, switch or restore. It is its own object so that only the views
/// that show changes redraw when they move.
@MainActor
final class ChangeState: ObservableObject {
    /// A scene's mark in the contents.
    enum Kind: Equatable, Sendable {
        case added, changed
    }

    enum Backup: Equatable, Sendable {
        /// No backup set up.
        case none
        /// Every version is on GitHub.
        case done
        /// The last backup failed, or versions are waiting to go.
        case behind
    }

    /// Changed scenes since the last version, in manuscript order.
    @Published private(set) var scenes: [Comparison.SceneChange] = []
    /// Scenes added or edited (not only moved), by file. Removed scenes have no row.
    @Published private(set) var marks: [URL: Kind] = [:]
    /// Chapters with any scene added, edited or removed.
    @Published private(set) var chapterMarks: Set<URL> = []
    /// Each scene's history, newest first (versions and automatic copies), by path in the
    /// library. Read with the changes, so the Versions tab needs no Git call of its own.
    @Published private(set) var histories: [String: [SceneHistoryEntry]] = [:]
    /// True once the first look has been taken.
    @Published private(set) var loaded = false

    /// A scene's history, by file.
    func history(of scene: URL) -> [SceneHistoryEntry] {
        relative(scene).flatMap { histories[$0] } ?? []
    }

    /// A scene's latest version.
    func lastVersion(of scene: URL) -> SceneHistoryEntry? {
        history(of: scene).first { $0.kind == .version }
    }

    /// The short id of the scene's last commit of yours ("a1b2c3d"), or nil with none yet.
    func label(of scene: URL) -> String? {
        lastVersion(of: scene)?.shortID
    }

    /// The scene's change since its last version, if any.
    func change(of scene: URL) -> Comparison.SceneChange? {
        relative(scene).flatMap { byPath[$0] }
    }

    /// Changes inside a folder (a chapter or a book), in manuscript order.
    func changes(inside folder: URL) -> [Comparison.SceneChange] {
        guard let base = relative(folder) else { return [] }
        return scenes.filter { $0.path.hasPrefix(base + "/") || ($0.oldPath?.hasPrefix(base + "/") ?? false) }
    }

    func relative(_ url: URL) -> String? {
        guard let root else { return nil }
        let base = root.canonical.path + "/"
        let path = url.canonical.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }
    /// The open rewrite's title; nil on the manuscript.
    @Published var branch: String?
    @Published var backup: Backup = .none
    /// Moves on every update, so pages re-read their baselines.
    @Published private(set) var generation = 0

    private(set) var root: URL?
    private var byPath: [String: Comparison.SceneChange] = [:]

    var count: Int { scenes.filter { !$0.onlyMoved }.count }
    var wordsAdded: Int { scenes.reduce(0) { $0 + $1.wordsAdded } }
    var wordsRemoved: Int { scenes.reduce(0) { $0 + $1.wordsRemoved } }

    /// Shows a scene's changes in the page (set by `VersionStore`).
    var openScene: ((URL) -> Void)?

    func clear(root: URL?) {
        self.root = root
        if !scenes.isEmpty { scenes = [] }
        if !marks.isEmpty { marks = [:] }
        if !chapterMarks.isEmpty { chapterMarks = [] }
        byPath = [:]
        histories = [:]
        loaded = false
        generation += 1
    }

    func update(root: URL, scenes new: [Comparison.SceneChange], histories: [String: [SceneHistoryEntry]], behind: Bool, hasBackup: Bool) {
        self.root = root
        if !loaded { loaded = true }
        if self.histories != histories { self.histories = histories }
        if !Self.same(scenes, new) {
            scenes = new
            byPath = Dictionary(new.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        }
        var nextMarks: [URL: Kind] = [:]
        var nextChapters = Set<URL>()
        for change in new where !change.onlyMoved {
            let url = root.appendingPathComponent(change.path).canonical
            if change.status != .removed { nextMarks[url] = change.status == .added ? .added : .changed }
            nextChapters.insert(url.deletingLastPathComponent().canonical)
        }
        if marks != nextMarks { marks = nextMarks }
        if chapterMarks != nextChapters { chapterMarks = nextChapters }
        let nextBackup: Backup = hasBackup ? (behind ? .behind : .done) : .none
        if backup != nextBackup { backup = nextBackup }
        generation += 1
    }

    /// Literal comparison: Swift's `==` on strings normalises Unicode, slow on whole scenes.
    private static func same(_ a: [Comparison.SceneChange], _ b: [Comparison.SceneChange]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            x.path == y.path && x.oldPath == y.oldPath && x.status == y.status
                && x.wordsAdded == y.wordsAdded && x.wordsRemoved == y.wordsRemoved
                && x.segments.count == y.segments.count
                && zip(x.segments, y.segments).allSatisfy { $0.kind == $1.kind && ($0.text as NSString).isEqual(to: $1.text) }
        }
    }

    /// A scene's text at the last version, as far as the page needs it.
    enum Baseline: Equatable {
        /// Unchanged since the last version (as of the last look): the page's own text is it.
        case unchanged
        /// New since the last version: nothing to compare with.
        case new
        case text(String)
    }

    func baseline(for scene: URL) -> Baseline {
        // Not looked yet: no bars rather than bars since opening.
        guard let root, loaded else { return .new }
        let base = root.canonical.path + "/"
        let path = scene.canonical.path
        guard path.hasPrefix(base) else { return .unchanged }
        guard let change = byPath[String(path.dropFirst(base.count))] else { return .unchanged }
        if change.status == .added { return .new }
        return .text(change.olderText)
    }

    func url(of change: Comparison.SceneChange) -> URL? {
        root?.appendingPathComponent(change.status == .removed ? (change.oldPath ?? change.path) : change.path).canonical
    }
}

extension Comparison.SceneChange {
    /// The scene as it was in the older version: everything but the added words.
    var olderText: String {
        segments.filter { $0.kind != .added }.map(\.text).joined()
    }
}

extension Git {
    /// Versions on this branch that no remote has yet.
    static func unpushedCount(_ root: URL) -> Int {
        let result = run(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: root)
        return result.ok ? Int(result.output) ?? 0 : 0
    }
}

// MARK: - Paragraphs changed on the page

/// A run of lines that differ from the last version, as a bar beside them on the page.
struct ChangeBar: Equatable, Identifiable {
    enum Kind: Equatable { case added, changed, removed }
    let kind: Kind
    /// The lines on the page, newlines included. Zero length for a cut: the bar marks where
    /// the cut text was, at the start of the line after it.
    let range: NSRange
    /// The page's text in `range`, to check nothing moved before putting the old back.
    let newText: String
    /// The lines as they were, newlines included ("" for lines that are new).
    let oldText: String
    /// The scene the lines belong to (a chapter's page holds several).
    var scene: URL? = nil

    var id: String { "\(kind)-\(range.location)-\(range.length)" }

    /// The lines without the last newline, for drawing.
    var drawRange: NSRange {
        guard range.length > 0, newText.hasSuffix("\n") else { return range }
        return NSRange(location: range.location, length: range.length - 1)
    }

    func offset(by delta: Int, scene: URL? = nil) -> ChangeBar {
        ChangeBar(kind: kind, range: NSRange(location: range.location + delta, length: range.length),
                  newText: newText, oldText: oldText, scene: scene ?? self.scene)
    }
}

enum ChangeBars {
    /// Compares a scene's lines with the last version's. Lines are matched on their words
    /// (their newline aside); blank lines alone never make a bar.
    static func bars(old: String, new: String) -> [ChangeBar] {
        let a = lines(old as NSString), b = lines(new as NSString)
        let (removed, inserted) = WordDiff.changes(a.map(\.content), b.map(\.content))
        let newString = new as NSString, oldString = old as NSString
        var bars: [ChangeBar] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            var gone: [Int] = [], come: [Int] = []
            while i < a.count, removed.contains(i) { gone.append(i); i += 1 }
            while j < b.count, inserted.contains(j) { come.append(j); j += 1 }
            if gone.isEmpty && come.isEmpty {
                guard i < a.count, j < b.count else { break }
                i += 1; j += 1
                continue
            }
            let goneText = gone.map { a[$0].content }.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let comeText = come.map { b[$0].content }.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard goneText || comeText else { continue }
            let start = come.first.map { b[$0].range.location } ?? (j < b.count ? b[j].range.location : newString.length)
            let end = come.last.map { NSMaxRange(b[$0].range) } ?? start
            let range = NSRange(location: start, length: end - start)
            let oldText = gone.isEmpty ? "" : oldString.substring(with: NSRange(
                location: a[gone[0]].range.location, length: NSMaxRange(a[gone[gone.count - 1]].range) - a[gone[0]].range.location))
            let kind: ChangeBar.Kind = !comeText ? .removed : !goneText ? .added : .changed
            bars.append(ChangeBar(kind: kind, range: range, newText: newString.substring(with: range), oldText: oldText))
        }
        return bars
    }

    private struct Line { let range: NSRange; let content: Substring }

    /// Each line's range, newline included, and its text without it.
    private static func lines(_ string: NSString) -> [Line] {
        var result: [Line] = []
        var start = 0
        let length = string.length
        while start < length {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: length - start))
            let end = newline.location == NSNotFound ? length : newline.location + 1
            let contentLength = (newline.location == NSNotFound ? length : newline.location) - start
            result.append(Line(range: NSRange(location: start, length: end - start),
                               content: Substring(string.substring(with: NSRange(location: start, length: contentLength)))))
            start = end
        }
        return result
    }
}
