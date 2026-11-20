import Foundation

/// How Longhand lets go of a file. What someone wrote goes to the Mac's Trash, one item for
/// what they deleted, so it can be put back. Longhand's own bookkeeping beside it (comments,
/// notes, scene details, covers cut to size) is removed quietly: it would only be clutter in
/// the Trash, and Git keeps its history. A background run (tests, pictures) never touches the
/// Trash at all.
enum Discard {
    /// What was let go since launch, oldest first: `kept` is true for what would have gone to
    /// the Trash. The self-test reads it.
    nonisolated(unsafe) private(set) static var log: [(url: URL, kept: Bool)] = []

    static func toTrash(_ url: URL) throws {
        log.append((url, true))
        if Snapshot.isBackgroundRun {
            try FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func bookkeeping(_ url: URL) {
        log.append((url, false))
        try? FileManager.default.removeItem(at: url)
    }
}
