import Foundation

/// Which view a document was last shown in (owner, 2026-11-15: "views remember which type of
/// view you had open in doc"): a chapter's read or write page, a story's contents page or
/// the whole story, or the cards. Remembered for each document, so a story opened again is
/// shown the way it was left, and one story's cards don't follow you into another.
///
/// The modes are kept in the settings, not in the library: they are how the writer likes to
/// look at their work, not part of the work itself.
final class ViewModes {
    /// The ways a document can be shown.
    enum Mode: String, CaseIterable {
        /// A chapter as the book will read it.
        case read
        /// A chapter for editing.
        case write
        /// A story's own contents page.
        case contents
        /// The whole story, to read.
        case page
        /// Index cards.
        case cards

        /// The two page views a chapter offers, and the two a story offers.
        static let chapterPages: [(title: String, mode: Mode)] = [("Read", .read), ("Write", .write)]
        static let storyPages: [(title: String, mode: Mode)] = [("Contents", .contents), ("Page", .page)]
    }

    /// The setting the modes are kept in.
    static let key = "viewModes"

    /// A mode every chapter is shown in, whatever it remembers (hidden runs and pictures).
    static var forcedChapter: Mode?
    /// A mode every story is shown in, whatever it remembers.
    static var forcedStory: Mode?

    private var stored: [String: Mode]

    init() {
        stored = [:]
        // A hidden run never reads the owner's own settings, nor writes them.
        guard !Snapshot.isBackgroundRun else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (document, value) in raw {
            if let mode = Mode(rawValue: value) { stored[document] = mode }
        }
    }

    /// The mode a document was last shown in.
    func mode(for document: String) -> Mode? { stored[document] }

    /// Remembers the mode for a document, and writes it down.
    func remember(_ mode: Mode, for document: String) {
        guard stored[document] != mode else { return }
        stored[document] = mode
        save()
    }

    private func save() {
        guard !Snapshot.isBackgroundRun else { return }
        let raw = stored.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
