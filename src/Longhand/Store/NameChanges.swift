import Foundation

/// Counting a tracked name and changing it everywhere (issue #24).
extension LibraryStore {
    /// Every scene of a story, in order: what a name is looked for in and changed in.
    func scenes(of book: Book) -> [Scene] { book.chapters.flatMap(\.scenes) }

    /// How many places hold each character across the story (any of its names, a place
    /// counted once), and in how many scenes; keyed by the main name. Reads each scene's file,
    /// so call it off the typing path (the Names tab does, after each save).
    func occurrences(ofGroups groups: [[String]], in book: Book) async -> [String: (places: Int, scenes: Int)] {
        let urls = scenes(of: book).map(\.url)
        return await Task.detached(priority: .utility) {
            let texts = urls.map { String.prose(at: $0) ?? "" }
            return Dictionary(groups.compactMap { names in names.first.map { ($0, NameMatch.count(ofAny: names, in: texts)) } },
                              uniquingKeysWith: { first, _ in first })
        }.value
    }

    /// The same for a single name (what the change sheet says it will change).
    func occurrences(of names: [String], in book: Book) async -> [String: (places: Int, scenes: Int)] {
        await occurrences(ofGroups: names.map { [$0] }, in: book)
    }

    /// Changes a name in every scene, and in the story's notes, synopses and comments. The
    /// story is committed first (so Restore can undo this) and again after, as "John was
    /// changed to Adam": a version of each scene it touched. The name stays tracked, as its
    /// new self. Returns how many places changed in how many scenes.
    @discardableResult
    func renameName(_ old: String, to new: String, in book: Book, done: @escaping @MainActor (Bool) -> Void = { _ in }) -> (places: Int, scenes: Int) {
        let oldName = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = libraryURL, !oldName.isEmpty, !newName.isEmpty, oldName != newName else { done(false); return (0, 0) }
        saveNow()
        let all = scenes(of: book)
        func plan() -> [(url: URL, edits: [NameMatch.Edit], text: String)] {
            all.map { scene in
                let text = String.prose(at: scene.url) ?? ""
                return (scene.url, NameMatch.edits(replacing: oldName, with: newName, in: text), text)
            }
        }
        let message = "\(oldName) was changed to \(newName)"
        let preview = plan().filter { !$0.edits.isEmpty }

        versions.record("Before changing \(oldName) to \(newName)") { [self] _ in
            // What was typed while the first commit ran is saved and read again, so the change
            // is made to the text as it is now, never to the text as it was.
            saveNow()
            let edits = plan()
            let changed = edits.filter { !$0.edits.isEmpty }
            for scene in changed {
                try? NameMatch.apply(scene.edits, to: scene.text).write(to: scene.url, atomically: true, encoding: .utf8)
            }
            let items = all.map(\.url) + book.chapters.filter { !$0.implicit }.map(\.url) + [book.url]
            margin.renameEverywhere(oldName, to: newName, scenes: edits.map { ($0.url, $0.edits) }, items: items, book: book.url)
            margin.renameTracked(oldName, to: newName, in: book.url)
            filesReplaced()
            let paths = changed.compactMap { Self.relativePath($0.url, in: root) }
            if paths.isEmpty {
                versions.record(message, done: done)
            } else {
                versions.saveVersions(of: paths, note: message, done: done)
            }
        }
        return (preview.reduce(0) { $0 + $1.edits.count }, preview.count)
    }
}
