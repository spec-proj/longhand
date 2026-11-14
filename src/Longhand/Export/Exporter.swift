import AppKit

/// Gathers a book from the library and hands it to the right writer.
@MainActor
enum Exporter {
    /// The book to export: the one the selection is in, or the first.
    static func book(in store: LibraryStore) -> Book? {
        guard let library = store.library else { return nil }
        if let url = store.selection?.url {
            if let book = library.books.first(where: {
                $0.url == url || $0.chapters.contains { $0.url == url || $0.scenes.contains { $0.url == url } }
            }) {
                return book
            }
        }
        return library.books.first
    }

    static func manuscript(of book: Book, store: LibraryStore) -> ManuscriptBook {
        store.saveNow()
        let chapters = book.chapters.map { chapter in
            (title: chapter.title, scenes: chapter.scenes.map { (title: $0.title, text: store.fileText(at: $0.url)) })
        }
        // Scenes only, or one document: a single run of text, with no "Chapter 1" above it.
        let implicit = book.chapters.contains(where: \.implicit)
        return ManuscriptBuilder.make(title: book.title, chapters: chapters, words: store.wordCount(of: book),
                                      numbered: !implicit && store.margin.info(for: book.url).hideChapterNumbers != true)
    }

    static func export(_ book: Book, store: LibraryStore, settings: ExportSettings, to url: URL) throws {
        let manuscript = manuscript(of: book, store: store)
        switch settings.format {
        case .manuscriptWord: try DocxWriter.write(manuscript, settings: settings, to: url)
        case .manuscriptPDF: try PDFWriter.writeManuscript(manuscript, settings: settings, to: url)
        case .bookPDF:
            let picture = store.margin.cover(of: book.url)
            try BookWriter.write(manuscript, settings: settings, cover: picture,
                                 lettered: picture == nil ? settings.letteredCover.map { ($0, coverText(of: book, store: store)) } : nil,
                                 to: url)
        case .epub:
            let info = store.margin.info(for: book.url)
            try EPUBWriter.write(manuscript, settings: settings,
                                 details: .init(cover: cover(of: book, store: store, settings: settings),
                                                synopsis: info.synopsis, genre: info.genre),
                                 to: url)
        }
    }

    /// The story's cover picture, or the lettered cover chosen in the export sheet.
    static func cover(of book: Book, store: LibraryStore, settings: ExportSettings) -> NSImage? {
        if let picture = store.margin.cover(of: book.url) { return picture }
        guard let style = settings.letteredCover else { return nil }
        return LetteredCover.bitmap(style, coverText(of: book, store: store))
    }

    /// The words on a lettered cover: title, byline and form.
    static func coverText(of book: Book, store: LibraryStore) -> LetteredCover.Text {
        let info = store.margin.info(for: book.url)
        var author = ExportSettings()
        author.useAuthor(info)
        return .init(title: book.title, author: author.byline, form: LetteredCover.formLine(info.form))
    }

    static func suggestedName(_ book: Book, _ settings: ExportSettings) -> String {
        // An e-book is named as a book on a shelf is: just its title.
        if settings.format == .epub { return "\(FileNaming.sanitized(book.title)).epub" }
        let kind = settings.format == .bookPDF ? "book" : "manuscript"
        return "\(FileNaming.sanitized(book.title)) \(kind).\(settings.format.fileExtension)"
    }
}
