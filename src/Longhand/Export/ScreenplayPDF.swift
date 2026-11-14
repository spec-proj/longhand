import AppKit

/// The title page of a screenplay: the title a third of the way down with the credit and the
/// author under it, contact details at the foot on the left, the draft on the right.
struct ScreenplayTitlePage: Equatable {
    var title: String
    var credit = "Written by"
    var authors: [String] = []
    var source: [String] = []
    var contact: [String] = []
    var draft: [String] = []

    /// The file's own title page (`Title:`, `Credit:`, `Author:`…) where it has one; the
    /// story's title, author profile and draft fill what it leaves out.
    static func make(document: Fountain.Document, storyTitle: String, author: String?, contact: [String], draft: [String]) -> ScreenplayTitlePage {
        var page = ScreenplayTitlePage(title: storyTitle.uppercased())
        if let title = document.title("Title"), !title.isEmpty { page.title = title.joined(separator: "\n") }
        if let credit = document.title("Credit")?.first { page.credit = credit }
        if let authors = document.title("Author") ?? document.title("Authors") {
            page.authors = authors
        } else if let author, !author.isEmpty {
            page.authors = [author]
        }
        page.source = document.title("Source") ?? []
        page.contact = document.title("Contact") ?? contact
        page.draft = document.title("Draft date") ?? document.title("Draft") ?? draft
        // "Written by" only above a name.
        if page.authors.isEmpty, document.title("Credit") == nil { page.credit = "" }
        return page
    }

    /// As Fountain keys, for a `.fountain` export of a file that has no title page.
    var fountainKeys: [(key: String, lines: [String])] {
        [("Title", [title]), ("Credit", [credit]), ("Author", authors), ("Source", source),
         ("Draft date", draft), ("Contact", contact)].filter { !$0.1.isEmpty }
    }
}

/// Draws a screenplay's pages (`ScreenplayLayout`) into a PDF: the screenplay export, and the
/// Read page, which shows the same PDF.
enum ScreenplayPDF {
    static let size: CGFloat = 12
    /// Points per character (ten an inch) and per line (six an inch).
    static let column: CGFloat = 7.2
    static let row: CGFloat = 12

    struct Made {
        let data: Data
        let pageCount: Int
    }

    static func make(_ document: Fountain.Document, titlePage: ScreenplayTitlePage?, paper: ScreenplayLayout.Paper = .letter,
                     sceneNumbers: Bool = false, title: String = "", author: String = "") -> Made {
        let laid = ScreenplayLayout.paginate(document, paper: paper, sceneNumbers: sceneNumbers)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper.size)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextAuthor: author, kCGPDFContextCreator: "Longhand"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
            return Made(data: Data(), pageCount: 0)
        }
        let offset = titlePage == nil ? 0 : 1

        func page(_ draw: () -> Void) {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: paper.size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }

        if let titlePage {
            page { drawTitlePage(titlePage, paper: paper) }
        }
        for (index, sheet) in laid.pages.enumerated() {
            page { drawSheet(sheet, index: index) }
        }
        context.closePDF()
        return Made(data: data as Data, pageCount: laid.pages.count + offset)
    }

    /// A page of the script (0-based `index`), in the current (flipped) graphics context.
    static func drawSheet(_ sheet: ScreenplayLayout.Page, index: Int, ink: NSColor = .black) {
        // Page numbers from the second page, top right, half an inch down.
        if index > 0 {
            draw(ScreenplayLayout.Line(left: 15, width: 60, align: .right, runs: [Fountain.Run(text: "\(index + 1).")]), top: 36, ink: ink)
        }
        for (r, rowLines) in sheet.rows.enumerated() {
            for line in rowLines { draw(line, top: 72 + CGFloat(r) * row, ink: ink) }
        }
    }

    /// One line, its top `top` points down the page.
    static func draw(_ line: ScreenplayLayout.Line, top: CGFloat, ink: NSColor = .black) {
        let length = line.runs.reduce(0) { $0 + $1.text.count }
        var x = CGFloat(line.left) * column
        switch line.align {
        case .left: break
        case .right: x += CGFloat(max(0, line.width - length)) * column
        case .center: x += CGFloat(max(0, line.width - length)) * column / 2
        }
        let text = NSMutableAttributedString()
        for run in line.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: ScreenplayFont.font(size, style: run.style),
                .foregroundColor: ink
            ]
            if run.style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        text.draw(at: NSPoint(x: x, y: top))
    }

    static func drawTitlePage(_ page: ScreenplayTitlePage, paper: ScreenplayLayout.Paper, ink: NSColor = .black) {
        func lines(_ text: String, align: ScreenplayLayout.Align, left: Int = 15, width: Int = 60) -> [ScreenplayLayout.Line] {
            text.components(separatedBy: "\n").flatMap { piece in
                ScreenplayLayout.wrap(Fountain.runs(piece), width: width).map {
                    ScreenplayLayout.Line(left: left, width: width, align: align, runs: $0)
                }
            }
        }
        // The middle: title, credit, authors, source, from three and a half inches down.
        var middle: [ScreenplayLayout.Line?] = lines(page.title, align: .center)
        if !page.credit.isEmpty || !page.authors.isEmpty {
            middle += [nil, nil] + lines(page.credit, align: .center)
            middle.append(nil)
            for author in page.authors { middle += lines(author, align: .center) }
        }
        if !page.source.isEmpty {
            middle += [nil, nil]
            for line in page.source { middle += lines(line, align: .center) }
        }
        for (r, line) in middle.enumerated() {
            if let line { draw(line, top: 252 + CGFloat(r) * row, ink: ink) }
        }
        // The foot: contact on the left, the draft on the right, ending an inch from the bottom.
        let bottom = paper.size.height - 72
        let contact = page.contact.flatMap { lines($0, align: .left, width: 36) }
        for (r, line) in contact.enumerated() {
            draw(line, top: bottom - CGFloat(contact.count - r) * row, ink: ink)
        }
        let draft = page.draft.flatMap { lines($0, align: .right, left: 45, width: 30) }
        for (r, line) in draft.enumerated() {
            draw(line, top: bottom - CGFloat(draft.count - r) * row, ink: ink)
        }
    }
}
