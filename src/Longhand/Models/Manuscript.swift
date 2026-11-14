import Foundation

// MARK: - The manuscript, as it exists on disk
//
// Library/                       one folder the owner chooses
//   A Folder/                    optionally, a plain folder of books (see `LibraryFolders`)
//   01 Book Title/               a book is a folder
//     01 Chapter Title/         a chapter is a folder
//       01 Scene Title.md       a scene is a plain Markdown file
//
// A story can be divided four ways (`BookShape`, owner 2026-11-14): chapters and scenes as
// above; chapters only (each chapter folder holds one file, its text); scenes only (Markdown
// files straight in the story's folder, no chapters); or one document (a single file straight
// in the story's folder). Every shape is read into the same Book › Chapter › Scene tree:
// loose files sit in an `implicit` chapter whose URL is the story's own folder, and a
// chapters-only story's chapters each hold their one scene. The views hide the level a
// shape doesn't have.
//
// Order lives in the numeric filename prefix, so it survives outside Longhand (the Finder sorts by name).
// `.longhand/` at the library root holds only settings; deleting it never touches prose.

struct Library: Equatable {
    var url: URL
    var name: String
    /// Every book, those inside folders included (each says which folder it is in).
    var books: [Book]
    /// The folders at the top of the library, by name.
    var folders: [Folder] = []

    func books(in folder: URL?) -> [Book] { books.filter { $0.folder == folder } }
}

/// A plain folder of books at the top of the library, shown as a group.
struct Folder: Identifiable, Equatable {
    var id: URL { url }
    var url: URL
    var title: String
}

/// How a story is divided. Kept with the story's details (`SceneInfo.shape`); without one,
/// the files on disk decide (chapter folders: chapters and scenes; loose files: one document
/// if there is one, else scenes).
enum BookShape: String, Codable, CaseIterable {
    case chaptersAndScenes = "chapters-and-scenes", chapters, scenes, document

    var hasChapters: Bool { self == .chaptersAndScenes || self == .chapters }
    var hasScenes: Bool { self == .chaptersAndScenes || self == .scenes }

    init(chapters: Bool, scenes: Bool) {
        switch (chapters, scenes) {
        case (true, true): self = .chaptersAndScenes
        case (true, false): self = .chapters
        case (false, true): self = .scenes
        case (false, false): self = .document
        }
    }
}

struct Book: Identifiable, Equatable {
    var id: URL { url }
    var url: URL
    var title: String
    var order: Int
    var chapters: [Chapter]
    /// The folder the book is in, if any.
    var folder: URL? = nil
    var shape: BookShape = .chaptersAndScenes

    /// A scenes-only story or a single document: its files, straight in its folder.
    var looseScenes: [Scene] { chapters.first(where: \.implicit)?.scenes ?? [] }
    /// A single document's one file.
    var document: Scene? { shape == .document ? looseScenes.first : nil }
}

struct Chapter: Identifiable, Equatable {
    var id: URL { url }
    var url: URL
    var title: String
    var order: Int
    var scenes: [Scene]
    /// Not a folder of its own: the story's folder, holding a scenes-only story's scenes or a
    /// single document. Never shown as a chapter.
    var implicit = false
}

struct Scene: Identifiable, Equatable {
    var id: URL { url }
    var url: URL
    var title: String
    var order: Int
}

/// What a story calls its parts (owner, 2026-11-14): a notebook has folders and notes; every
/// other form, chapters and scenes. Only the words change, never the files.
struct PartNames: Equatable {
    let chapter: String
    let chapters: String
    let scene: String
    let scenes: String

    static let story = PartNames(chapter: "Chapter", chapters: "Chapters", scene: "Scene", scenes: "Scenes")
    static let notebook = PartNames(chapter: "Folder", chapters: "Folders", scene: "Note", scenes: "Notes")

    static func of(_ form: BookForm?) -> PartNames { form == .notebook ? .notebook : .story }

    /// "1 scene", "3 notes".
    func count(_ n: Int, chapters: Bool = false) -> String {
        let word = chapters ? (n == 1 ? chapter : self.chapters) : (n == 1 ? scene : scenes)
        return "\(n) \(word.lowercased())"
    }
}

// MARK: - Selection

enum Selection: Hashable {
    case book(URL)
    case chapter(URL)
    case scene(URL)

    var url: URL {
        switch self {
        case .book(let url), .chapter(let url), .scene(let url): return url
        }
    }
}

// MARK: - Rename / delete targets

enum ItemKind: String {
    case book, chapter, scene
}

struct ManuscriptItem: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let order: Int
    let kind: ItemKind
}

// MARK: - Save state

enum SaveState: Equatable {
    case idle
    case edited
    case saving
    case saved
}
