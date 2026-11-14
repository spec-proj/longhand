import Foundation

/// Earlier versions of each scene, so a bad afternoon is recoverable.
///
///     .longhand/history/<Book>/<Chapter>/<Scene>/<yyyy-MM-dd HH.mm.ss>.md
///
/// Before Longhand overwrites a scene file, it copies what was there, at most once every ten
/// minutes per scene (so a session of typing leaves one version, not hundreds). Restoring a
/// version first keeps the current text as a version too, so a restore can be undone. Each
/// scene keeps its 200 most recent versions. The folder moves with the scene (see
/// `MarginStore.relocate`).
@MainActor
final class HistoryStore {
    struct Version: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        let date: Date
        let words: Int
    }

    static let interval: TimeInterval = 10 * 60
    static let keep = 200

    private var root: URL?
    /// When each scene was last copied in this run, so a save needn't list the folder.
    private var lastCopied: [URL: Date] = [:]

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    func open(root: URL?) {
        self.root = root
        lastCopied = [:]
    }

    func folder(for scene: URL) -> URL? {
        guard let root else { return nil }
        let base = root.path + "/"
        guard scene.path.hasPrefix(base) else { return nil }
        var key = String(scene.path.dropFirst(base.count))
        if key.lowercased().hasSuffix(".md") { key.removeLast(3) }
        return root.appendingPathComponent(".longhand/history/\(key)", isDirectory: true)
    }

    /// Called just before a scene file is overwritten with `newText`: keeps what is on disk, if
    /// the last copy is old enough and the text really changes.
    func keepBeforeWriting(_ scene: URL, newText: String) {
        let now = Date()
        if let last = lastCopied[scene], now.timeIntervalSince(last) < Self.interval { return }
        if lastCopied[scene] == nil, let newest = versions(of: scene).first,
           now.timeIntervalSince(newest.date) < Self.interval {
            lastCopied[scene] = newest.date
            return
        }
        guard let old = String.prose(at: scene),
              !(old as NSString).isEqual(to: newText),
              !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keep(old, of: scene, at: now)
    }

    /// Keeps `text` as a version of `scene` now, whatever the interval (used before a restore).
    func keep(_ text: String, of scene: URL, at date: Date = Date()) {
        guard let folder = folder(for: scene) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never overwrite: two versions in the same second get "… 2.md".
        let file = FileNaming.unique(folder.appendingPathComponent(Self.stamp.string(from: date) + ".md"))
        try? text.write(to: file, atomically: true, encoding: .utf8)
        lastCopied[scene] = date
        prune(folder)
    }

    /// Newest first.
    func versions(of scene: URL) -> [Version] {
        guard let folder = folder(for: scene),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".md") }
            .compactMap { name -> Version? in
                guard let date = Self.stamp.date(from: String(name.prefix(19))) else { return nil }
                let url = folder.appendingPathComponent(name)
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return Version(url: url, date: date, words: LibraryStore.wordCount(text))
            }
            .sorted { ($0.date, $0.url.lastPathComponent.count, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent.count, $1.url.lastPathComponent) }
    }

    func text(of version: Version) -> String {
        (try? String(contentsOf: version.url, encoding: .utf8)) ?? ""
    }

    private func prune(_ folder: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let sorted = names.filter { $0.hasSuffix(".md") }.sorted { ($0.prefix(19), $0.count, $0) > ($1.prefix(19), $1.count, $1) }
        for name in sorted.dropFirst(Self.keep) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
