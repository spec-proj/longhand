import AppKit

/// Writes the standard manuscript as PDF (same layout as the Word file; the book PDF is
/// `BookWriter`). Pages are laid out by AppKit's text system, one text container per page, so line
/// breaking and hyphenation match the rest of the Mac.
enum PDFWriter {
    // MARK: - Manuscript

    static func writeManuscript(_ book: ManuscriptBook, settings: ExportSettings, to url: URL) throws {
        let page = settings.paper.size
        let margin: CGFloat = 72
        let font = NSFont(name: settings.typeface.fontName, size: 12) ?? NSFont.systemFont(ofSize: 12)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let ink = NSColor.black

        func style(indent: CGFloat = 36, align: NSTextAlignment = .natural, before: CGFloat = 0, sides: CGFloat = 0,
                   line: CGFloat = 24) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.minimumLineHeight = line
            s.maximumLineHeight = line
            s.firstLineHeadIndent = sides + indent
            s.headIndent = sides
            s.tailIndent = -sides
            s.alignment = align
            s.paragraphSpacingBefore = before
            return s
        }
        func text(_ runs: [ManuscriptBook.Run], _ paragraph: NSParagraphStyle) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for run in runs {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: run.bold ? bold : run.italic ? italic : font,
                    .foregroundColor: ink,
                    .paragraphStyle: paragraph
                ]
                if run.raised {
                    // A footnote's number: smaller and lifted, without opening up the line.
                    attributes[.font] = NSFontManager.shared.convert(font, toSize: (font.pointSize * 0.7).rounded())
                    attributes[.baselineOffset] = font.pointSize * 0.33
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
            return result
        }
        let plain = { (string: String) in [ManuscriptBook.Run(text: string)] }

        var sections: [Section] = []
        for (index, chapter) in book.chapters.enumerated() {
            let body = NSMutableAttributedString()
            // Sink the heading a third of the way down (an empty line of that height: AppKit
            // ignores space-before on the first paragraph of a text).
            body.append(text(plain(""), style(indent: 0, line: 144 - 24)))
            if let label = chapter.label { body.append(text(plain(label), style(indent: 0, align: .center))) }
            if let heading = chapter.heading {
                body.append(text(plain(heading), style(indent: 0, align: .center)))
            }
            body.append(text(plain(""), style(indent: 0)))
            let (blocks, notes) = chapter.numbered()
            for block in blocks {
                switch block {
                case .paragraph(let runs, _): body.append(text(runs, style()))
                case .heading(let runs): body.append(text(runs, style(indent: 0, align: .center)))
                case .quote(let runs): body.append(text(runs, style(indent: 0, sides: 36)))
                case .sceneBreak: body.append(text(plain("#"), style(indent: 0, align: .center)))
                case .stanza(let lines):
                    // Poetry manuscripts are single-spaced: each line as written, a wrapped
                    // line hanging under it, a blank line after the stanza.
                    for (number, line) in lines.enumerated() {
                        let s = NSMutableParagraphStyle()
                        s.minimumLineHeight = 14
                        s.maximumLineHeight = 14
                        let indent = CGFloat(line.indent) * 3.6
                        s.firstLineHeadIndent = indent
                        s.headIndent = indent + 36
                        s.paragraphSpacing = number == lines.count - 1 ? 14 : 0
                        body.append(text(line.runs, s))
                    }
                case .pageBreak:
                    // A form feed: the layout starts the next page here.
                    body.append(NSAttributedString(string: "\u{0C}", attributes: [.font: font]))
                case .table(let rows):
                    // A ruled table across the text width: each cell its own block.
                    let table = NSTextTable()
                    table.numberOfColumns = max(1, rows.map(\.count).max() ?? 1)
                    table.setContentWidth(100, type: .percentageValueType)
                    for (rowIndex, row) in rows.enumerated() {
                        for (column, cell) in row.enumerated() {
                            let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                            block.setBorderColor(ink)
                            block.setWidth(0.5, type: .absoluteValueType, for: .border)
                            block.setWidth(4, type: .absoluteValueType, for: .padding)
                            let cellStyle = style(indent: 0, line: 16).mutableCopy() as! NSMutableParagraphStyle
                            cellStyle.textBlocks = [block]
                            body.append(text(cell.map { piece in
                                var piece = piece
                                if rowIndex == 0 { piece.bold = true }
                                return piece
                            }, cellStyle))
                        }
                    }
                }
            }
            // The chapter's footnotes, numbered as called out, after its last line.
            for (number, note) in notes.enumerated() {
                body.append(text(plain("\(number + 1). ") + note.filter { $0.note == nil },
                                 style(indent: 0, before: number == 0 ? 24 : 0)))
            }
            if index == book.chapters.count - 1 {
                body.append(text(plain("THE END"), style(indent: 0, align: .center, before: 24)))
            }
            sections.append(Section(text: body, kind: .chapter))
        }

        let label = [settings.surname, book.title].filter { !$0.isEmpty }.joined(separator: " / ")
        let headerStyle = style(indent: 0, align: .right, line: 14)

        try render(
            to: url,
            page: page,
            textRect: { _ in CGRect(x: margin, y: margin, width: page.width - 2 * margin, height: page.height - 2 * margin) },
            titlePage: { context in
                // Name and word count on one line, contact block below, title halfway down.
                let width = page.width - 2 * margin
                let left = style(indent: 0, line: 14)
                let name = NSAttributedString(string: settings.name, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: left])
                name.draw(in: CGRect(x: margin, y: margin, width: width, height: 20))
                NSAttributedString(string: book.lengthLine, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style(indent: 0, align: .right, line: 14)])
                    .draw(in: CGRect(x: margin, y: margin, width: width, height: 20))
                var y = margin + 14
                for line in settings.contact.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    NSAttributedString(string: line.trimmingCharacters(in: .whitespaces), attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: left])
                        .draw(in: CGRect(x: margin, y: y, width: width, height: 20))
                    y += 14
                }
                let centred = style(indent: 0, align: .center)
                let block = NSMutableAttributedString(string: book.title + "\n", attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: centred])
                if !settings.byline.isEmpty {
                    block.append(NSAttributedString(string: "by " + settings.byline, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: centred]))
                }
                block.draw(in: CGRect(x: margin, y: page.height / 2 - 24, width: width, height: 80))
                _ = context
            },
            sections: sections,
            decorate: { pageNumber, _, _ in
                // "Surname / Title / 1" in the top margin, numbered from the first chapter page.
                let header = NSAttributedString(string: "\(label) / \(pageNumber)", attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: headerStyle])
                header.draw(in: CGRect(x: margin, y: 36, width: page.width - 2 * margin, height: 16))
            }
        )
    }

    // MARK: - Pages

    struct Section {
        enum Kind { case chapter }
        let text: NSAttributedString
        let kind: Kind
    }

    /// Lays each section out from a new page and draws every page into a PDF. `decorate` draws
    /// running heads and page numbers: it gets the page number, the section's index, and
    /// whether the page opens its section.
    private static func render(
        to url: URL,
        page: CGSize,
        textRect: (Int) -> CGRect,
        titlePage: (CGContext) -> Void,
        blankAfterTitle: Bool = false,
        firstNumber: Int = 1,
        sections: [Section],
        decorate: (Int, Int, Bool) -> Void
    ) throws {
        var box = CGRect(origin: .zero, size: page)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        func drawPage(_ body: () -> Void) {
            context.beginPDFPage(nil)
            context.saveGState()
            // Flip, so drawing runs top-down like a page.
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            body()
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }

        drawPage { titlePage(context) }
        if blankAfterTitle { drawPage {} }

        var number = firstNumber
        for (index, section) in sections.enumerated() {
            let storage = NSTextStorage(attributedString: section.text)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            var containers: [(NSTextContainer, CGRect)] = []
            var pageNumber = number
            repeat {
                let rect = textRect(pageNumber)
                let container = NSTextContainer(size: rect.size)
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                containers.append((container, rect))
                pageNumber += 1
                let glyphs = layout.glyphRange(for: container)
                if NSMaxRange(glyphs) >= layout.numberOfGlyphs || containers.count > 2000 { break }
            } while true

            for (offset, (container, rect)) in containers.enumerated() {
                let glyphs = layout.glyphRange(for: container)
                if glyphs.length == 0, offset > 0 { continue }
                drawPage {
                    layout.drawBackground(forGlyphRange: glyphs, at: rect.origin)
                    layout.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
                    decorate(number, index, offset == 0)
                }
                number += 1
            }
        }
        context.closePDF()
    }
}
