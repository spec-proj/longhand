import Foundation

/// Pins and links between stories (issues #13 and #14). Both live in a story's own details
/// (`SceneInfo`), so they are saved with the library and reach another Mac through Git.
extension MarginStore {
    func isPinned(_ book: URL) -> Bool { info(for: book).pinned == true }

    func setPinned(_ pinned: Bool, for book: URL) {
        var info = self.info(for: book)
        info.pinned = pinned ? true : nil
        setInfo(info, for: book)
    }

    func link(_ book: URL, to title: String) {
        var info = self.info(for: book)
        var links = info.links ?? []
        guard !links.contains(title) else { return }
        links.append(title)
        info.links = links
        setInfo(info, for: book)
    }

    func unlink(_ book: URL, from title: String) {
        var info = self.info(for: book)
        info.links = (info.links ?? []).filter { $0 != title }
        if info.links?.isEmpty == true { info.links = nil }
        setInfo(info, for: book)
    }

    /// A story was renamed: every link to it takes the new title.
    func renameLinks(from old: String, to new: String) {
        for (book, info) in infos where info.links?.contains(old) == true {
            var changed = info
            changed.links = info.links?.map { $0 == old ? new : $0 }
            setInfo(changed, for: book)
        }
    }
}

extension LibraryStore {
    /// The stories pinned to the top of the Library, in the Library's order.
    var pinnedBooks: [Book] {
        (library?.books ?? []).filter { margin.isPinned($0.url) }
    }

    /// The stories this one links to, in the order they were linked. A link to a story that
    /// has gone is left out (and returns if a story with that title does).
    func links(from book: Book) -> [Book] {
        (margin.info(for: book.url).links ?? []).compactMap { title in
            library?.books.first { $0.title == title && $0.url != book.url }
        }
    }

    /// The stories that link to this one.
    func links(to book: Book) -> [Book] {
        (library?.books ?? []).filter { other in
            other.url != book.url && margin.info(for: other.url).links?.contains(book.title) == true
        }
    }
}
