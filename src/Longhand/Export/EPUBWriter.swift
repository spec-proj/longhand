import AppKit
import CryptoKit

/// An EPUB 3 e-book, for reading in Apple Books, Kobo, or Kindle (by Send to Kindle):
///
/// - the story's cover, if it has one; a title page; a copyright page; the contents;
/// - one file per chapter: an italic "Chapter N" (when the story's numbers are on), the title,
///   the first line in small capitals, indented paragraphs, `* * *` between scenes;
/// - footnotes as the format's own pop-up notes, listed again at the chapter's end;
/// - the synopsis and genre in the book's details, which readers' libraries show.
///
/// The files are packed with the Mac's own `zip` (the EPUB rule: `mimetype` first and
/// uncompressed).
enum EPUBWriter {
    struct Details {
        var cover: NSImage?
        var synopsis = ""
        var genre: String?
    }

    static func write(_ book: ManuscriptBook, settings: ExportSettings, details: Details, to url: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("longhand-epub-\(UUID().uuidString)")
        let text = work.appendingPathComponent("OEBPS")
        try fm.createDirectory(at: work.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: text, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        func put(_ string: String, _ path: String) throws {
            try string.write(to: work.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        try put("application/epub+zip", "mimetype")
        try put("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """, "META-INF/container.xml")
        try put(stylesheet, "OEBPS/style.css")

        // The pages, in reading order: (file, title for the contents or nil, extra properties).
        var spine: [(file: String, properties: String?)] = []
        var manifest: [String] = []

        // Cover.
        var hasCover = false
        if let cover = details.cover, let jpeg = jpegData(cover) {
            try jpeg.write(to: text.appendingPathComponent("cover.jpg"))
            manifest.append(#"<item id="cover-image" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#)
            try put(page(title: "Cover", body: #"<div class="cover"><img src="cover.jpg" alt="\#(escape(book.title))"/></div>"#, type: "cover"),
                    "OEBPS/cover.xhtml")
            manifest.append(#"<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>"#)
            spine.append(("cover", nil))
            hasCover = true
        }

        // Title and copyright.
        let byline = settings.byline
        var title = #"<section class="titlepage" epub:type="titlepage"><h1 class="title">\#(escape(book.title))</h1>"#
        if !byline.isEmpty { title += #"<p class="byline">\#(escape(byline))</p>"# }
        title += "</section>"
        try put(page(title: book.title, body: title, type: "titlepage"), "OEBPS/title.xhtml")
        manifest.append(#"<item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>"#)
        spine.append(("title", nil))

        let year = Calendar.current.component(.year, from: Date())
        let notice = #"<section class="copyright" epub:type="copyright-page"><p>Copyright © \#(year)\#(byline.isEmpty ? "" : " " + escape(byline))</p><p>All rights reserved.</p></section>"#
        try put(page(title: "Copyright", body: notice, type: "copyright-page"), "OEBPS/copyright.xhtml")
        manifest.append(#"<item id="copyright" href="copyright.xhtml" media-type="application/xhtml+xml"/>"#)
        spine.append(("copyright", nil))

        // Contents: the format's own navigation, also shown as a page.
        var nav = #"<nav epub:type="toc" id="toc"><h2 class="contents">Contents</h2><ol>"#
        for (index, chapter) in book.chapters.enumerated() {
            let name = chapter.showsNumber && chapter.heading != nil ? "\(chapter.number). \(chapter.name)" : chapter.name
            nav += #"<li><a href="chapter-\#(index + 1).xhtml">\#(escape(name))</a></li>"#
        }
        nav += "</ol></nav>"
        nav += #"<nav epub:type="landmarks" hidden="hidden"><ol>"#
        if hasCover { nav += #"<li><a epub:type="cover" href="cover.xhtml">Cover</a></li>"# }
        nav += #"<li><a epub:type="toc" href="nav.xhtml">Contents</a></li>"#
        if !book.chapters.isEmpty { nav += #"<li><a epub:type="bodymatter" href="chapter-1.xhtml">Begin Reading</a></li>"# }
        nav += "</ol></nav>"
        try put(page(title: "Contents", body: nav, type: nil), "OEBPS/nav.xhtml")
        manifest.append(#"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#)
        spine.append(("nav", nil))

        // Chapters.
        for (index, chapter) in book.chapters.enumerated() {
            let id = "chapter-\(index + 1)"
            try put(page(title: chapter.name, body: body(of: chapter), type: "chapter"), "OEBPS/\(id).xhtml")
            manifest.append(#"<item id="\#(id)" href="\#(id).xhtml" media-type="application/xhtml+xml"/>"#)
            spine.append((id, nil))
        }
        manifest.append(#"<item id="css" href="style.css" media-type="text/css"/>"#)

        // The package: what the book is and the order of its pages.
        let modified = ISO8601DateFormatter().string(from: Date())
        var metadata = """
            <dc:identifier id="book-id">urn:uuid:\(identifier(book.title, byline))</dc:identifier>
            <dc:title>\(escape(book.title))</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
            """
        if !byline.isEmpty { metadata += "\n<dc:creator>\(escape(byline))</dc:creator>" }
        let synopsis = details.synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !synopsis.isEmpty { metadata += "\n<dc:description>\(escape(synopsis))</dc:description>" }
        if let genre = details.genre, !genre.isEmpty { metadata += "\n<dc:subject>\(escape(genre))</dc:subject>" }
        if hasCover { metadata += #"\#n<meta name="cover" content="cover-image"/>"# }

        try put("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="en">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata)
              </metadata>
              <manifest>
            \(manifest.joined(separator: "\n"))
              </manifest>
              <spine>
            \(spine.map { #"<itemref idref="\#($0.file)"/>"# }.joined(separator: "\n"))
              </spine>
            </package>
            """, "OEBPS/content.opf")

        // Pack: mimetype first and stored, then the rest compressed.
        let packed = work.appendingPathComponent("book.epub")
        try zip(["-X0", packed.path, "mimetype"], in: work)
        try zip(["-Xr9D", packed.path, "META-INF", "OEBPS"], in: work)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: packed, to: url)
    }

    // MARK: Chapters

    private static func body(of chapter: ManuscriptBook.Chapter) -> String {
        var html = #"<section epub:type="chapter">"#
        html += "<header>"
        if let label = chapter.label { html += #"<p class="label">\#(escape(label))</p>"# }
        if let heading = chapter.heading { html += #"<h1 class="chapter">\#(escape(heading))</h1>"# }
        html += "</header>"
        var notes: [[ManuscriptBook.Run]] = []
        func inline(_ runs: [ManuscriptBook.Run]) -> String {
            runs.map { run -> String in
                if let note = run.note {
                    notes.append(note)
                    let n = notes.count
                    return ##"<sup><a epub:type="noteref" id="ref-\##(n)" href="#note-\##(n)">\##(n)</a></sup>"##
                }
                var piece = escape(run.text)
                if run.italic { piece = "<em>\(piece)</em>" }
                if run.bold { piece = "<strong>\(piece)</strong>" }
                return piece
            }.joined()
        }
        var first = true
        for block in chapter.blocks {
            switch block {
            case .paragraph(let runs, let opening):
                let kind = first ? "first" : opening ? "open" : nil
                html += kind.map { #"<p class="\#($0)">"# } ?? "<p>"
                html += inline(runs) + "</p>"
            case .heading(let runs):
                html += "<h2>\(inline(runs))</h2>"
            case .quote(let runs):
                html += "<blockquote><p>\(inline(runs))</p></blockquote>"
            case .sceneBreak:
                html += #"<p class="break" role="separator">*&#8194;*&#8194;*</p>"#
            case .table(let rows):
                html += "<table>"
                for (index, row) in rows.enumerated() {
                    let cell = index == 0 ? "th" : "td"
                    html += "<tr>" + row.map { "<\(cell)>\(inline($0))</\(cell)>" }.joined() + "</tr>"
                }
                html += "</table>"
            }
            first = false
        }
        // Each note as the format's own footnote: readers show it where it is called out, and
        // print it here at the chapter's end.
        if !notes.isEmpty {
            html += #"<section class="notes"><h2 class="notes">Notes</h2>"#
            for (index, note) in notes.enumerated() {
                let n = index + 1
                html += ##"<aside epub:type="footnote" id="note-\##(n)"><p><a href="#ref-\##(n)">\##(n).</a> \##(inline(note.filter { $0.note == nil }))</p></aside>"##
            }
            html += "</section>"
        }
        return html + "</section>"
    }

    // MARK: Pieces

    private static func page(title: String, body: String, type: String?) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
        <head>
        <meta charset="UTF-8"/>
        <title>\(escape(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body\(type.map { #" epub:type="\#($0)""# } ?? "")>
        \(body)
        </body>
        </html>
        """
    }

    /// Set like the book PDF: a serif the reader's own (the reader may change it), indented
    /// paragraphs, the first line of a chapter in small capitals.
    private static let stylesheet = """
        body { font-family: "New York", Georgia, serif; line-height: 1.45; margin: 0 5%; }
        p { margin: 0; text-indent: 1.5em; text-align: justify; hyphens: auto; -webkit-hyphens: auto; }
        p.first, p.open, p.break { text-indent: 0; }
        p.first::first-line { font-variant: small-caps; letter-spacing: 0.03em; }
        p.break { text-align: center; margin: 1em 0; }
        header { margin: 18% 0 2.5em; text-align: center; page-break-before: always; }
        p.label { text-indent: 0; text-align: center; font-style: italic; margin-bottom: 0.4em; }
        h1.chapter { font-weight: normal; font-size: 1.75em; margin: 0; }
        h2 { font-weight: normal; font-style: italic; font-size: 1em; text-align: center; margin: 1.5em 0 0.75em; }
        blockquote { margin: 0.75em 1.5em; }
        blockquote p { text-indent: 0; }
        table { border-collapse: collapse; margin: 1em auto; }
        th, td { border: 0.5px solid currentColor; padding: 0.2em 0.5em; text-align: left; }
        sup { font-size: 0.7em; line-height: 0; }
        sup a { text-decoration: none; }
        section.notes { margin-top: 2em; font-size: 0.9em; }
        section.notes p { text-indent: 0; text-align: left; margin-bottom: 0.4em; }
        section.titlepage { text-align: center; margin-top: 30%; }
        h1.title { font-weight: normal; font-size: 2.2em; margin: 0 0 0.6em; }
        p.byline { text-indent: 0; text-align: center; font-style: italic; font-size: 1.2em; }
        section.copyright { margin-top: 60%; font-size: 0.85em; }
        section.copyright p { text-indent: 0; text-align: left; }
        h2.contents { margin-top: 15%; }
        nav ol { list-style: none; padding: 0; margin: 1.5em 0; }
        nav li { margin: 0.4em 0; }
        nav a { text-decoration: none; color: inherit; }
        div.cover { text-align: center; height: 100%; margin: 0; padding: 0; }
        div.cover img { max-width: 100%; max-height: 100%; }
        """

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The same identifier each time a story is exported, so a reader replaces the old copy
    /// rather than shelving a second one.
    static func identifier(_ title: String, _ byline: String) -> String {
        let digest = Array(Insecure.MD5.hash(data: Data("longhand:\(title):\(byline)".utf8)))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x30   // version 3 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    private static func jpegData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func zip(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q"] + arguments
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
