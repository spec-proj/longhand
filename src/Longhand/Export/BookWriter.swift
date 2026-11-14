import AppKit

/// The printed-book PDF, set like a trade paperback:
///
/// - front matter: title page; copyright page on its back; contents (chapter, title, page);
///   a blank page if needed, so the text starts on a right-hand page;
/// - every chapter on a right-hand page (a blank left-hand page before it if need be), with a
///   sunk italic "Chapter N" and the title;
/// - New York, justified and hyphenated, mirrored margins (wider on the inside);
/// - running heads in italic (the book's title on left pages, the chapter's on right pages),
///   none on openers or blank pages; page numbers centred at the foot, from 1 at chapter one.
///
/// Chapters are laid out first, so the contents page can give real page numbers.
enum BookWriter {
    static func write(_ book: ManuscriptBook, settings: ExportSettings, cover: NSImage? = nil,
                      lettered: (LetteredCover.Style, LetteredCover.Text)? = nil, to url: URL) throws {
        let trim = settings.trim
        let page = trim.size
        let inside = (page.width * 0.159).rounded(), outside = (page.width * 0.114).rounded()
        let top = (page.height * 0.095).rounded(), bottom = (page.height * 0.108).rounded()
        let textSize = CGSize(width: page.width - inside - outside, height: page.height - top - bottom)
        let size = trim.bodySize
        let leading = (size * 1.35).rounded()
        let ink = NSColor.black

        // New York, Apple's serif (it allows embedding), as in the editor.
        func serif(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            var font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            return font
        }
        let roman = serif(size)
        let italic = serif(size, italic: true)
        let bold = serif(size, weight: .semibold)
        func style(first: CGFloat = size, align: NSTextAlignment = .justified, before: CGFloat = 0, after: CGFloat = 0,
                   sides: CGFloat = 0, line: CGFloat = leading, tabs: [NSTextTab] = []) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.minimumLineHeight = line
            s.maximumLineHeight = line
            s.firstLineHeadIndent = sides + first
            s.headIndent = sides
            s.tailIndent = -sides
            s.alignment = align
            s.paragraphSpacingBefore = before
            s.paragraphSpacing = after
            s.hyphenationFactor = align == .justified ? 0.9 : 0
            s.tabStops = tabs
            return s
        }
        func text(_ runs: [ManuscriptBook.Run], _ paragraph: NSParagraphStyle, font base: NSFont? = nil) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for run in runs {
                let font = base ?? (run.bold ? bold : run.italic ? italic : roman)
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
                if run.raised {
                    // A footnote's number: smaller and lifted, without opening up the line.
                    attributes[.font] = NSFontManager.shared.convert(font, toSize: (font.pointSize * 0.7).rounded())
                    attributes[.baselineOffset] = font.pointSize * 0.33
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: base ?? roman, .paragraphStyle: paragraph]))
            return result
        }
        let plain = { (string: String) in [ManuscriptBook.Run(text: string)] }
        /// The opening words of a chapter, in small capitals, as trade books set them.
        let smallCaps: NSFont = {
            let features: [[NSFontDescriptor.FeatureKey: Int]] = [
                [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]
            ]
            let descriptor = roman.fontDescriptor.addingAttributes([.featureSettings: features])
            return NSFont(descriptor: descriptor, size: size) ?? roman
        }()
        /// Splits a chapter's first paragraph so its first words (up to four, within the first
        /// sentence) are set in small capitals.
        func opener(_ runs: [ManuscriptBook.Run]) -> NSAttributedString {
            let set = NSMutableAttributedString(attributedString: text(runs, style(first: 0)))
            let string = set.string as NSString
            var words = 0, end = 0
            string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byWords) { _, range, _, stop in
                let between = string.substring(with: NSRange(location: end, length: range.location - end))
                if words > 0, between.contains(where: { ".!?;:—–".contains($0) }) { stop.pointee = true; return }
                words += 1
                end = NSMaxRange(range)
                if words == 4 { stop.pointee = true }
            }
            guard end > 0 else { return set }
            set.enumerateAttribute(.font, in: NSRange(location: 0, length: end)) { value, range, _ in
                // Italic or bold words keep their face; plain ones take small capitals.
                if (value as? NSFont) == roman { set.addAttribute(.font, value: smallCaps, range: range) }
            }
            return set
        }


        // MARK: Chapters, laid out first.

        struct Laid {
            let storage: NSTextStorage
            let layout: NSLayoutManager
            let pages: [NSTextContainer]
            let title: String
            /// True when the chapter has no title of its own ("Chapter 3").
            let untitled: Bool
        }
        func lay(_ string: NSAttributedString) -> (NSTextStorage, NSLayoutManager, [NSTextContainer]) {
            let storage = NSTextStorage(attributedString: string)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            var pages: [NSTextContainer] = []
            repeat {
                let container = NSTextContainer(size: textSize)
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                pages.append(container)
                if NSMaxRange(layout.glyphRange(for: container)) >= layout.numberOfGlyphs || pages.count > 3000 { break }
            } while true
            return (storage, layout, pages)
        }

        var chapters: [Laid] = []
        for chapter in book.chapters {
            let body = NSMutableAttributedString()
            body.append(text(plain(""), style(first: 0, line: (textSize.height * 0.22).rounded())))
            body.append(text(plain(chapter.label ?? ""), style(first: 0, align: .center), font: serif(size + 0.5, italic: true)))
            let heading = chapter.heading ?? ""
            body.append(text(plain(heading), style(first: 0, align: .center, before: 6, after: leading * 2, line: (size * 2.2).rounded()),
                             font: serif((size * 1.75).rounded())))
            let (blocks, notes) = chapter.numbered()
            for (index, block) in blocks.enumerated() {
                switch block {
                case .paragraph(let runs, _) where index == 0:
                    body.append(opener(runs))
                case .paragraph(let runs, let opening):
                    body.append(text(runs, style(first: opening ? 0 : size)))
                case .heading(let runs):
                    body.append(text(runs, style(first: 0, align: .center, before: leading, after: leading / 2), font: italic))
                case .quote(let runs):
                    body.append(text(runs, style(first: 0, before: leading / 2, after: leading / 2, sides: size * 1.5)))
                case .sceneBreak:
                    // Three spaced asterisks, as printed books set a break (owner,
                    // 2026-11-12). Half a line above and below: with its own line that
                    // is two lines, so the text after it stays on the page's grid.
                    body.append(text(plain("*\u{2002}*\u{2002}*"), style(first: 0, align: .center, before: leading / 2, after: leading / 2)))
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
                            let cellStyle = style(first: 0, align: .left).mutableCopy() as! NSMutableParagraphStyle
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
                                 style(first: 0, align: .left, before: number == 0 ? leading : 0)))
            }
            let (storage, layout, pages) = lay(body)
            chapters.append(Laid(storage: storage, layout: layout, pages: pages,
                                 title: chapter.name, untitled: heading.isEmpty))
        }

        // MARK: Planning: which physical page each chapter starts on.

        func contents(numbers: [Int]) -> NSAttributedString {
            let result = NSMutableAttributedString()
            result.append(text(plain(""), style(first: 0, line: (textSize.height * 0.12).rounded())))
            result.append(text(plain("Contents"), style(first: 0, align: .center, after: leading * 1.5), font: serif(size + 1.5, italic: true)))
            let tabs = [NSTextTab(textAlignment: .left, location: size * 2), NSTextTab(textAlignment: .right, location: textSize.width)]
            for (index, chapter) in chapters.enumerated() {
                // "3  The Admiral  29", or "Chapter 3  29" when the chapter has no title.
                let row = chapter.untitled
                    ? "\(chapter.title)\t\t\(numbers[index])"
                    : "\(index + 1)\t\(chapter.title)\t\(numbers[index])"
                result.append(text(plain(row), style(first: 0, align: .left, tabs: tabs)))
            }
            return result
        }
        // The contents page count doesn't depend on the numbers, so measure it with placeholders.
        let contentsPages = lay(contents(numbers: Array(repeating: 888, count: chapters.count))).2.count
        var front = 2 + contentsPages
        if front % 2 == 1 { front += 1 }

        var starts: [Int] = []          // physical page (1-based) where each chapter starts
        var physical = front + 1
        for chapter in chapters {
            if physical % 2 == 0 { physical += 1 }      // right-hand pages are odd
            starts.append(physical)
            physical += chapter.pages.count
        }
        let folio = { (physical: Int) in physical - front }
        let (contentsStorage, contentsLayout, contentsContainers) = lay(contents(numbers: starts.map(folio)))
        _ = contentsStorage

        // MARK: Drawing.

        var box = CGRect(origin: .zero, size: page)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        var drawn = 0
        func drawPage(_ body: () -> Void) {
            drawn += 1
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            body()
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        func origin(_ physical: Int) -> CGPoint {
            CGPoint(x: physical % 2 == 1 ? inside : outside, y: top)
        }
        let centred = style(first: 0, align: .center, line: 12)
        let small = serif((size * 0.82).rounded())
        let headFont = serif((size * 0.82).rounded(), italic: true)

        // The cover, if the story has one, filling a page of its own before the book's
        // pages (outside the count, so right-hand pages stay right-hand).
        if let cover, let image = cover.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.beginPDFPage(nil)
            let ratio = max(page.width / CGFloat(image.width), page.height / CGFloat(image.height))
            let shown = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
            context.draw(image, in: CGRect(x: (page.width - shown.width) / 2, y: (page.height - shown.height) / 2,
                                           width: shown.width, height: shown.height))
            context.endPDFPage()
        } else if let (style, text) = lettered {
            // No picture: the lettered cover chosen in the export sheet, drawn as type (sharp
            // at any size) to the page's shape.
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            LetteredCover.draw(style, text, in: CGRect(origin: .zero, size: page))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }

        // Title page.
        drawPage {
            let block = NSMutableAttributedString(string: book.title + "\n", attributes: [
                .font: serif((size * 2.3).rounded()), .foregroundColor: ink,
                .paragraphStyle: style(first: 0, align: .center, after: 18, line: (size * 2.8).rounded())
            ])
            if !settings.byline.isEmpty {
                block.append(NSAttributedString(string: settings.byline, attributes: [
                    .font: serif((size * 1.2).rounded(), italic: true), .foregroundColor: ink,
                    .paragraphStyle: style(first: 0, align: .center, line: (size * 1.6).rounded())
                ]))
            }
            block.draw(in: CGRect(x: inside, y: page.height * 0.3, width: textSize.width, height: 200))
        }
        // Copyright page, on the back of the title page.
        drawPage {
            let year = Calendar.current.component(.year, from: Date())
            let holder = settings.byline.isEmpty ? "" : " " + settings.byline
            let notice = NSAttributedString(string: "Copyright © \(year)\(holder)\nAll rights reserved.", attributes: [
                .font: small, .foregroundColor: ink, .paragraphStyle: style(first: 0, align: .left, line: (size * 1.15).rounded())
            ])
            notice.draw(in: CGRect(x: outside, y: page.height - bottom - 40, width: textSize.width, height: 40))
        }
        // Contents.
        for (offset, container) in contentsContainers.enumerated() {
            let range = contentsLayout.glyphRange(for: container)
            drawPage { contentsLayout.drawGlyphs(forGlyphRange: range, at: origin(3 + offset)) }
        }
        while drawn < front { drawPage {} }

        // Chapters.
        for (index, chapter) in chapters.enumerated() {
            while drawn + 1 < starts[index] { drawPage {} }
            for (offset, container) in chapter.pages.enumerated() {
                let range = chapter.layout.glyphRange(for: container)
                if range.length == 0, offset > 0 { continue }
                let physical = drawn + 1
                drawPage {
                    chapter.layout.drawGlyphs(forGlyphRange: range, at: origin(physical))
                    NSAttributedString(string: "\(folio(physical))", attributes: [.font: small, .foregroundColor: ink, .paragraphStyle: centred])
                        .draw(in: CGRect(x: 0, y: page.height - bottom + bottom * 0.33, width: page.width, height: 14))
                    if offset > 0 {
                        let running = physical % 2 == 0 ? book.title : chapter.title
                        NSAttributedString(string: running, attributes: [.font: headFont, .foregroundColor: ink, .paragraphStyle: centred])
                            .draw(in: CGRect(x: 0, y: top * 0.55, width: page.width, height: 14))
                    }
                }
            }
        }
        context.closePDF()
    }
}
