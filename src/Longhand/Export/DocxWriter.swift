import Foundation

/// Writes a manuscript as a Word document in standard manuscript format (after William Shunn's
/// "Proper Manuscript Format", the form agents and editors expect):
///
/// - a title page: legal name and contact block top left, the rounded word count top right, the
///   title and byline centred halfway down; no header on it;
/// - every chapter on a new page, its heading a third of the way down;
/// - 12pt Times New Roman (or Courier), double-spaced, 1-inch margins, half-inch first-line
///   indents, no space between paragraphs;
/// - "#" centred between scenes, "THE END" after the last line;
/// - a "Surname / Title / page" header on every page after the title page, numbered from 1.
///
/// The file is WordprocessingML written by hand and zipped with the system's `zip`.
enum DocxWriter {
    static func write(_ book: ManuscriptBook, settings: ExportSettings, to url: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("longhand-docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        var notes: [[ManuscriptBook.Run]] = []
        let body = document(book, settings, notes: &notes)
        var files: [String: String] = [
            "[Content_Types].xml": contentTypes(footnotes: !notes.isEmpty),
            "_rels/.rels": rootRels,
            "docProps/core.xml": core(book, settings),
            "word/_rels/document.xml.rels": documentRels(footnotes: !notes.isEmpty),
            "word/styles.xml": styles(settings),
            "word/settings.xml": wordSettings,
            "word/header1.xml": header(book, settings),
            "word/document.xml": body
        ]
        if !notes.isEmpty { files["word/footnotes.xml"] = footnotes(notes) }
        for (path, text) in files {
            let file = work.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        let zipped = work.appendingPathComponent("out.docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = work
        process.arguments = ["-X", "-q", "-r", zipped.path, "[Content_Types].xml", "_rels", "docProps", "word"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: zipped, to: url)
    }

    // MARK: - Document

    /// `notes` collects the footnotes in the order they are called out; Word numbers them.
    private static func document(_ book: ManuscriptBook, _ settings: ExportSettings, notes: inout [[ManuscriptBook.Run]]) -> String {
        var body = ""
        var found: [[ManuscriptBook.Run]] = []
        // A footnote's call: a raised reference to the note with that id (ids 0 and 1 are
        // the separators Word expects, so notes start at 2).
        func run(_ run: ManuscriptBook.Run) -> String {
            guard let note = run.note else { return Self.run(run) }
            found.append(note)
            return "<w:r><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr><w:footnoteReference w:id=\"\(found.count + 1)\"/></w:r>"
        }
        func run(_ text: String) -> String { Self.run(text) }
        defer { notes = found }
        let twips = settings.paper.twips
        let textWidth = twips.width - 2 * 1440

        // Title page: name and word count on one line, contact below, title halfway down.
        let contact = settings.contact
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        body += paragraph(
            [run(settings.name), tab(), run(book.roundedWords)],
            properties: pPr(rightTab: textWidth, single: true, indent: 0)
        )
        for line in contact {
            body += paragraph([run(line)], properties: pPr(single: true, indent: 0))
        }
        body += paragraph([run(book.title)], properties: pPr(before: 4320, indent: 0, centred: true))
        if !settings.byline.isEmpty {
            body += paragraph([run("by " + settings.byline)], properties: pPr(indent: 0, centred: true))
        }

        // Chapters.
        for chapter in book.chapters {
            // The first line carries the page break: "Chapter 2", or the title when numbers are off.
            let lines = [chapter.label, chapter.heading].compactMap { $0 }
            for (index, line) in lines.enumerated() {
                body += paragraph([run(line)], properties: index == 0
                    ? pPr(pageBreak: true, before: 2880, indent: 0, centred: true)
                    : pPr(indent: 0, centred: true))
            }
            body += paragraph([], properties: pPr(indent: 0))
            for block in chapter.blocks {
                switch block {
                case .paragraph(let runs, _):
                    body += paragraph(runs.map { run($0) }, properties: "")
                case .heading(let runs):
                    body += paragraph(runs.map { run($0) }, properties: pPr(indent: 0, centred: true))
                case .quote(let runs):
                    body += paragraph(runs.map { run($0) }, properties: pPr(indent: 0, sides: 720))
                case .sceneBreak:
                    body += paragraph([run("#")], properties: pPr(indent: 0, centred: true))
                case .table(let rows):
                    // A plain ruled table across the text width, single-spaced, headings bold.
                    let columns = max(1, rows.map(\.count).max() ?? 1)
                    let width = textWidth / columns
                    let edge = { (name: String) in "<w:\(name) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/>" }
                    var table = "<w:tbl><w:tblPr><w:tblW w:w=\"\(width * columns)\" w:type=\"dxa\"/><w:tblBorders>"
                    table += ["top", "left", "bottom", "right", "insideH", "insideV"].map(edge).joined()
                    table += "</w:tblBorders><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
                    table += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
                    for (index, row) in rows.enumerated() {
                        table += "<w:tr>"
                        for cell in row {
                            let runs = cell.map { piece -> ManuscriptBook.Run in
                                var piece = piece
                                if index == 0 { piece.bold = true }
                                return piece
                            }
                            table += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>"
                            table += paragraph(runs.map { run($0) }, properties: pPr(single: true, indent: 0)) + "</w:tc>"
                        }
                        table += "</w:tr>"
                    }
                    // Word wants a paragraph after a table.
                    body += table + "</w:tbl>" + paragraph([], properties: pPr(single: true, indent: 0))
                }
            }
        }
        body += paragraph([run("THE END")], properties: pPr(before: 480, indent: 0, centred: true))

        let section = """
        <w:sectPr>
        <w:headerReference w:type="default" r:id="rIdHeader"/>
        <w:pgSz w:w="\(twips.width)" w:h="\(twips.height)"/>
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
        <w:pgNumType w:start="0"/>
        <w:titlePg/>
        </w:sectPr>
        """
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>\(body)\(section)</w:body>
        </w:document>
        """
    }

    /// True when a chapter's title is just its number ("Chapter 3", "3"), so it isn't said twice.
    static func isPlainNumber(_ title: String, _ number: Int) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        return t == "\(number)" || t == "chapter \(number)"
    }

    /// Paragraph properties, always in the order Word's schema requires (it may call a file
    /// damaged otherwise): page break, tabs, spacing, indent, alignment.
    private static func pPr(
        pageBreak: Bool = false, rightTab: Int? = nil, before: Int? = nil, single: Bool = false,
        indent: Int? = nil, sides: Int? = nil, centred: Bool = false
    ) -> String {
        var xml = ""
        if pageBreak { xml += "<w:pageBreakBefore/>" }
        if let rightTab { xml += "<w:tabs><w:tab w:val=\"right\" w:pos=\"\(rightTab)\"/></w:tabs>" }
        if before != nil || single {
            xml += "<w:spacing"
            if let before { xml += " w:before=\"\(before)\"" }
            if single { xml += " w:line=\"240\" w:lineRule=\"auto\"" }
            xml += "/>"
        }
        if indent != nil || sides != nil {
            xml += "<w:ind"
            if let sides { xml += " w:left=\"\(sides)\" w:right=\"\(sides)\"" }
            if let indent { xml += " w:firstLine=\"\(indent)\"" }
            xml += "/>"
        }
        if centred { xml += "<w:jc w:val=\"center\"/>" }
        return xml
    }

    private static func paragraph(_ runs: [String], properties: String) -> String {
        "<w:p><w:pPr>\(properties)</w:pPr>\(runs.joined())</w:p>"
    }

    private static func run(_ text: String) -> String {
        run(ManuscriptBook.Run(text: text))
    }

    private static func run(_ run: ManuscriptBook.Run) -> String {
        var properties = ""
        if run.bold { properties += "<w:b/>" }
        if run.italic { properties += "<w:i/>" }
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escape(run.text))</w:t></w:r>"
    }

    private static func tab() -> String { "<w:r><w:tab/></w:r>" }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // Control characters other than tab are not allowed in XML.
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20, scalar != "\t" { continue }
                out.append(character)
            }
        }
        return out
    }

    // MARK: - Parts

    /// The footnotes part: the two separators Word expects, then each note, single-spaced,
    /// starting with its own raised number.
    private static func footnotes(_ notes: [[ManuscriptBook.Run]]) -> String {
        let single = "<w:pPr><w:spacing w:line=\"240\" w:lineRule=\"auto\"/><w:ind w:firstLine=\"0\"/></w:pPr>"
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:footnote w:type="separator" w:id="0"><w:p>\(single)<w:r><w:separator/></w:r></w:p></w:footnote>
        <w:footnote w:type="continuationSeparator" w:id="1"><w:p>\(single)<w:r><w:continuationSeparator/></w:r></w:p></w:footnote>

        """
        for (index, note) in notes.enumerated() {
            let words = note.filter { $0.note == nil }.map { run($0) }.joined()
            xml += "<w:footnote w:id=\"\(index + 2)\"><w:p>\(single)<w:r><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr><w:footnoteRef/></w:r><w:r><w:t xml:space=\"preserve\"> </w:t></w:r>\(words)</w:p></w:footnote>\n"
        }
        return xml + "</w:footnotes>"
    }

    private static func header(_ book: ManuscriptBook, _ settings: ExportSettings) -> String {
        let label = escape([settings.surname, book.title].filter { !$0.isEmpty }.joined(separator: " / ") + " / ")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:p><w:pPr><w:spacing w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/><w:jc w:val="right"/></w:pPr>
        <w:r><w:t xml:space="preserve">\(label)</w:t></w:r>
        <w:r><w:fldChar w:fldCharType="begin"/></w:r>
        <w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>
        <w:r><w:fldChar w:fldCharType="separate"/></w:r>
        <w:r><w:t>1</w:t></w:r>
        <w:r><w:fldChar w:fldCharType="end"/></w:r>
        </w:p>
        </w:hdr>
        """
    }

    private static func styles(_ settings: ExportSettings) -> String {
        let font = escape(settings.typeface.fontName)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults>
        <w:rPrDefault><w:rPr><w:rFonts w:ascii="\(font)" w:hAnsi="\(font)" w:eastAsia="\(font)" w:cs="\(font)"/><w:sz w:val="24"/><w:szCs w:val="24"/><w:lang w:val="en-GB"/></w:rPr></w:rPrDefault>
        <w:pPrDefault><w:pPr><w:widowControl/><w:spacing w:before="0" w:after="0" w:line="480" w:lineRule="auto"/><w:ind w:firstLine="720"/></w:pPr></w:pPrDefault>
        </w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        </w:styles>
        """
    }

    private static func core(_ book: ManuscriptBook, _ settings: ExportSettings) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(escape(book.title))</dc:title>
        <dc:creator>\(escape(settings.byline))</dc:creator>
        </cp:coreProperties>
        """
    }

    private static func contentTypes(footnotes: Bool) -> String {
        footnotes ? contentTypesBase.replacingOccurrences(of: "</Types>", with: """
        <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>
        </Types>
        """) : contentTypesBase
    }

    private static func documentRels(footnotes: Bool) -> String {
        footnotes ? documentRelsBase.replacingOccurrences(of: "</Relationships>", with: """
        <Relationship Id="rIdFootnotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>
        </Relationships>
        """) : documentRelsBase
    }

    private static let contentTypesBase = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
    <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
    </Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    </Relationships>
    """

    private static let documentRelsBase = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    <Relationship Id="rIdSettings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
    <Relationship Id="rIdHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
    </Relationships>
    """

    private static let wordSettings = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:defaultTabStop w:val="720"/>
    <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>
    </w:settings>
    """
}
