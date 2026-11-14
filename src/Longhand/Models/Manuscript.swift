import Foundation

// MARK: - The manuscript, as it exists on disk
//
// Library/                       one folder the owner chooses
//   A Folder/                    optionally, a plain folder of books (see `LibraryFolders`)
//   01 Book Title/               a book is a folder
//     01 Chapter Title/         a chapter is a folder
//       01 Scene Title.md       a scene is a plain Markdown file
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

struct Book: Identifiable, Equatable {
    var id: URL { url }
    var url: URL
    var title: String
    var order: Int
    var chapters: [Chapter]
    /// The folder the book is in, if any.
    var folder: URL? = nil
}

struct Chapter: Identifiable, Equatable {
    var id: URL { url }
    var url: URL
    var title: String
    var order: Int
    var scenes: [Scene]
}

struct Scene: Identifiable, Equatable {
    var id: URL { url }
    var url: URL
    var title: String
    var order: Int
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
