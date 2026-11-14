import SwiftUI
import AppKit

/// A chapter as it will read in the book (owner, 2026-11-12: "viewing a chapter should look
/// WYSIWYG, so the writer can check formatting and flow"): the opener, then every scene set
/// like a printed page. Markdown symbols are gone, paragraphs are justified and indented, a
/// heading that only repeats the scene's name is left out (as in export), and every break,
/// between scenes or typed as `---`, is three spaced asterisks. Read only: the toolbar's
/// Write shows the same chapter for editing.
///
/// A whole story reads the same way (its Page, owner 2026-11-13): its title page, then each
/// chapter in turn.
struct ChapterReader: NSViewRepresentable {
    let chapters: [ReadingChapter]
    /// A whole story's page opens with its title and author.
    var heading: StoryHeading?
    var margin: MarginStore

    init(title: String, number: Int?, scenes: [ChapterSceneText], margin: MarginStore) {
        chapters = [ReadingChapter(title: title, number: number, scenes: scenes)]
        heading = nil
        self.margin = margin
    }

    init(story chapters: [ReadingChapter], heading: StoryHeading, margin: MarginStore) {
        self.chapters = chapters
        self.heading = heading
        self.margin = margin
    }

    private var scenes: [ChapterSceneText] { chapters.flatMap(\.scenes) }

    func makeCoordinator() -> Coordinator { Coordinator(margin: margin) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = PaperTheme.paper

        let textView = HighlightTextView.page()
        textView.identifier = ChapterReader.identifier
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: Layout.gutter, height: 28)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.selectedTextAttributes = [.backgroundColor: PaperTheme.selection]
        scroll.documentView = textView
        context.coordinator.attach(textView)
        show(in: textView, coordinator: context.coordinator)
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        show(in: textView, coordinator: context.coordinator)
    }

    static let identifier = NSUserInterfaceItemIdentifier("chapter-reader")

    /// The reading page shows the chapter's comments as the writing page does: highlighted
    /// on the page, focused by a click in the margin, and new ones made from a selection.
    /// Comments keep their place in each scene's own Markdown; `ReadingMap` finds that place
    /// on the page, where symbols, blank lines and a repeated title are gone.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, CommentPage {
        var chapters: [ReadingChapter]?
        var heading: StoryHeading?
        var scenes: [ChapterSceneText]? { chapters?.flatMap(\.scenes) }
        /// Each scene on the page, where it sits and how its text maps there.
        var maps: [URL: ReadingMap] = [:]
        let margin: MarginStore
        weak var textView: HighlightTextView?
        private var overlay: CommentOverlay?

        init(margin: MarginStore) { self.margin = margin }

        func attach(_ textView: HighlightTextView) {
            self.textView = textView
            textView.delegate = self
            margin.page = self
            overlay = CommentOverlay(textView: textView, margin: margin)
        }

        func detach() {
            // Leaving for Write: it opens at the first words on show here.
            if let textView, let top = scenePoint(textView.currentPlace.top) {
                margin.readingAnchor = MarginStore.ReadingAnchor(top: top, caret: nil)
            }
            overlay?.detach()
            if margin.page === self { margin.page = nil }
        }

        /// A place on the reading page as a place in its scene's own text.
        private func scenePoint(_ location: Int) -> (scene: URL, location: Int)? {
            let point = NSRange(location: location, length: 0)
            guard let (url, map) = maps.first(where: { $0.value.covers(point) }) else { return nil }
            return (url, map.source(point).location)
        }

        /// Come from Write (⌘R): show the same words at the top, then forget them.
        func applyAnchor() {
            guard let textView, let anchor = margin.readingAnchor,
                  let top = (anchor.top ?? anchor.caret).flatMap({ maps[$0.scene]?.page(NSRange(location: $0.location, length: 0)) }) else { return }
            margin.readingAnchor = nil
            textView.restore(Places.Place(caret: top.location, top: top.location))
        }

        /// Highlights follow new text.
        func pageChanged() { overlay?.invalidate() }

        var pageTextView: NSTextView? { textView }

        func pageRange(scene: URL, local: NSRange) -> NSRange? {
            maps[scene]?.page(local)
        }

        func selectionInScene() -> (scene: URL, range: NSRange)? {
            guard let selection = textView?.selectedRange(), selection.length > 0,
                  let (url, map) = maps.first(where: { $0.value.covers(selection) }) else { return nil }
            return (url, map.source(selection))
        }

        func text(of scene: URL) -> String? {
            scenes?.first { $0.url == scene }?.text
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let location = textView?.selectedRange().location,
                  let (url, map) = maps.first(where: { $0.value.covers(NSRange(location: location, length: 0)) }) else { return }
            margin.caretMoved(scene: url, location: map.source(NSRange(location: location, length: 0)).location)
        }
    }

    /// Sets the page again only when the chapter or its text changed.
    private func show(in textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.chapters != chapters || coordinator.heading != heading else { return }
        let sameChapter = coordinator.scenes?.map(\.url) == scenes.map(\.url)
        coordinator.chapters = chapters
        coordinator.heading = heading
        let scenes = self.scenes
        let started = Date()
        let (page, maps) = Self.reading(chapters: chapters, heading: heading)
        coordinator.maps = maps
        textView.textStorage?.setAttributedString(page)
        // Speed check: LONGHAND_READ_TIMING=/file appends how long setting the page took.
        if let path = ProcessInfo.processInfo.environment["LONGHAND_READ_TIMING"] {
            let line = "\(scenes.count) scenes, \(page.length) characters: \(Int(Date().timeIntervalSince(started) * 1000)) ms\n"
            if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
            else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        if !sameChapter { textView.scrollToBeginningOfDocument(nil) }
        // Laid out first, then to where Write was.
        DispatchQueue.main.async { [weak coordinator] in coordinator?.applyAnchor() }
        // The margin lists the chapter's comments, as it does beside the page for writing.
        margin.page = coordinator
        margin.openChapterPage(scenes: scenes.map(\.url))
        for scene in scenes { margin.anchor(scene: scene.url, text: scene.text) }
        coordinator.pageChanged()
    }

    // MARK: - Setting the page

    private static let rule = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let heading = try! NSRegularExpression(pattern: #"^#[ \t]+(.*?)[ \t]*$"#)

    /// The whole chapter, set for reading.
    static func page(title: String, number: Int?, scenes: [ChapterSceneText]) -> NSAttributedString {
        reading(title: title, number: number, scenes: scenes).page
    }

    /// The whole chapter, set for reading, and where each scene's text landed on it. Tables
    /// are set in columns with their headings in bold; footnotes are raised numbers, counted
    /// through the chapter, with the notes after its last scene (as the book PDF sets them).
    static func reading(title: String, number: Int?, scenes: [ChapterSceneText]) -> (page: NSAttributedString, maps: [URL: ReadingMap]) {
        reading(chapters: [ReadingChapter(title: title, number: number, scenes: scenes)], heading: nil)
    }

    /// Chapters one after another, each with its opener and its notes; a story's title page first.
    static func reading(chapters: [ReadingChapter], heading: StoryHeading?) -> (page: NSAttributedString, maps: [URL: ReadingMap]) {
        let page = NSMutableAttributedString()
        if let heading { page.append(heading.text()) }
        var maps: [URL: ReadingMap] = [:]
        for (index, chapter) in chapters.enumerated() {
            let opener = NSMutableAttributedString(attributedString: ChapterOpener.text(title: chapter.title, number: chapter.number))
            // A chapter after another (or after the title page) starts well down, as on a new page.
            if index > 0 || heading != nil, opener.length > 0,
               let style = (opener.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                style.paragraphSpacingBefore = 140
                opener.addAttribute(.paragraphStyle, value: style, range: (opener.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)))
            }
            page.append(opener)
            appendChapter(chapter.scenes, to: page, maps: &maps)
        }
        return (page, maps)
    }

    /// One chapter's scenes, with a break between them and its notes after them.
    private static func appendChapter(_ scenes: [ChapterSceneText], to page: NSMutableAttributedString, maps: inout [URL: ReadingMap]) {
        var notes: [String] = []
        var first = true
        for scene in scenes {
            let readable = readableLines(scene.text, sceneTitle: scene.title, notes: &notes)
            guard !readable.text.isEmpty else { continue }
            if !first {
                page.append(NSAttributedString(string: SceneBreak.ornament + "\n", attributes: SceneBreak.attributes))
            }
            first = false
            let storage = NSTextStorage(string: readable.text + "\n")
            let removed = MarkdownStyler.applyReader(to: storage, removing: readable.removed)
            // Where a place in the readable text is once the symbols are gone.
            func kept(_ index: Int) -> Int { index - removed.count(in: 0..<index) }
            setTables(readable.tableRows.map { row in
                (NSRange(location: kept(row.range.location), length: kept(NSMaxRange(row.range)) - kept(row.range.location)), row.heading, row.table)
            }, in: storage)
            for call in readable.calls {
                raise(NSRange(location: kept(call.location), length: call.length), in: storage)
            }
            maps[scene.url] = ReadingMap(base: page.length, length: storage.length - 1, pieces: readable.pieces, removed: removed)
            page.append(storage)
        }
        if !notes.isEmpty { page.append(Self.notes(notes)) }
    }

    /// A scene's Markdown as the lines a reader sees: no blank lines (paragraphs are told
    /// apart by their indent), no heading that only repeats the scene's name, and every
    /// break written as three spaced asterisks.
    static func readable(_ markdown: String, sceneTitle: String) -> String {
        var notes: [String] = []
        return readableLines(markdown, sceneTitle: sceneTitle, notes: &notes).text
    }

    /// A scene made ready for the reading page. `text` keeps every character of the lines it
    /// shows (a table's inner bars become tabs, a footnote call's first characters its number),
    /// so a place in the Markdown is found by `pieces`; what the page leaves out is `removed`.
    struct Readable {
        var text = ""
        var pieces: [ReadingMap.Piece] = []
        var removed = IndexSet()
        /// Each table row in `text`, whether it is the heading row, and which table it is in.
        var tableRows: [(range: NSRange, heading: Bool, table: Int)] = []
        /// Footnote numbers in `text`.
        var calls: [NSRange] = []
    }

    private enum LineKind { case text, row(heading: Bool, table: Int) }

    // The same rules as export (`ManuscriptBuilder`), so Read shows what the book will.
    private static let notePattern = try! NSRegularExpression(pattern: #"^[ ]{0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#)
    private static let tableRule = try! NSRegularExpression(pattern: #"^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?$"#)
    private static let callPattern = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)

    /// `readable`, and which stretches of the Markdown each kept line came from. Footnotes
    /// this scene calls out are added to `notes`, numbered on from the scenes before it.
    private static func readableLines(_ markdown: String, sceneTitle: String, notes: inout [String]) -> Readable {
        let source = markdown as NSString
        var all: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            all.append(range)
        }
        func text(_ index: Int) -> String { source.substring(with: all[index]) }
        func blank(_ index: Int) -> Bool { text(index).trimmingCharacters(in: .whitespaces).isEmpty }
        func matches(_ pattern: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
            pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        }

        // Footnotes: "[^1]: the note" (and indented lines carrying it on) leave the text.
        var noteWords: [String: String] = [:]
        var skipped = Set<Int>()
        var open: String?
        for index in all.indices {
            let line = text(index)
            if let match = matches(notePattern, line) {
                let name = (line as NSString).substring(with: match.range(at: 1))
                noteWords[name] = (line as NSString).substring(with: match.range(at: 2))
                open = name
                skipped.insert(index)
            } else if let name = open, line.hasPrefix("    ") || line.hasPrefix("\t"), !blank(index) {
                noteWords[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                skipped.insert(index)
            } else {
                open = nil
            }
        }

        // Tables: a paragraph whose first line has bars and whose second is all dashes.
        var kinds: [Int: LineKind] = [:]
        var tables = 0
        var index = 0
        while index < all.count {
            guard !blank(index), !skipped.contains(index) else { index += 1; continue }
            var end = index
            while end + 1 < all.count, !blank(end + 1), !skipped.contains(end + 1) { end += 1 }
            if end > index, text(index).contains("|"), matches(tableRule, text(index + 1).trimmingCharacters(in: .whitespaces)) != nil {
                kinds[index] = .row(heading: true, table: tables)
                skipped.insert(index + 1)
                if end >= index + 2 { for row in (index + 2)...end { kinds[row] = .row(heading: false, table: tables) } }
                tables += 1
            }
            index = end + 1
        }

        var lines: [(text: String, from: NSRange?, kind: LineKind)] = []
        for index in all.indices where !skipped.contains(index) && !blank(index) {
            let raw = text(index)
            let line = raw.trimmingCharacters(in: .whitespaces)
            let whole = NSRange(location: 0, length: (line as NSString).length)
            if lines.isEmpty, let match = heading.firstMatch(in: line, range: whole),
               (line as NSString).substring(with: match.range(at: 1)).caseInsensitiveCompare(sceneTitle) == .orderedSame {
                continue
            }
            if kinds[index] == nil, rule.firstMatch(in: line, range: whole) != nil {
                lines.append((SceneBreak.ornament, nil, .text))
            } else {
                lines.append((raw, all[index], kinds[index] ?? .text))
            }
        }
        // A break at the very start or end of a scene would double the one between scenes.
        while let line = lines.first, line.from == nil { lines.removeFirst() }
        while let line = lines.last, line.from == nil { lines.removeLast() }

        var result = Readable()
        var out: [String] = []
        var at = 0
        for (position, line) in lines.enumerated() {
            if position > 0 { at += 1 }
            var units = Array(line.text.utf16)
            if case .row(let heading, let table) = line.kind {
                result.removed.formUnion(IndexSet(cellBars(&units).map { $0 + at }))
                result.tableRows.append((NSRange(location: at, length: units.count), heading, table))
            }
            // Footnote calls with a note: the number in place of the call's first characters.
            let lineText = String(utf16CodeUnits: units, count: units.count) as NSString
            for match in callPattern.matches(in: lineText as String, range: NSRange(location: 0, length: lineText.length)) {
                guard let words = noteWords[lineText.substring(with: match.range(at: 1))] else { continue }
                let digits = Array(String(notes.count + 1).utf16)
                guard digits.count <= match.range.length else { continue }
                notes.append(words)
                for (offset, unit) in digits.enumerated() { units[match.range.location + offset] = unit }
                result.removed.insert(integersIn: (at + match.range.location + digits.count)..<(at + NSMaxRange(match.range)))
                result.calls.append(NSRange(location: at + match.range.location, length: digits.count))
            }
            if let from = line.from { result.pieces.append(.init(source: from.location, page: at, length: from.length)) }
            out.append(String(utf16CodeUnits: units, count: units.count))
            at += units.count
        }
        result.text = out.joined(separator: "\n")
        return result
    }

    /// A table row's bars: the inner ones become tabs (one character for one, so places
    /// still line up); the outer ones and the spaces around each cell go. Returns what goes.
    private static func cellBars(_ units: inout [UInt16]) -> IndexSet {
        let bar = UInt16(UInt8(ascii: "|")), space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))
        let backslash = UInt16(UInt8(ascii: "\\"))
        var removed = IndexSet()
        func isSpace(_ i: Int) -> Bool { units[i] == space || units[i] == tab }
        guard var start = units.firstIndex(where: { $0 != space && $0 != tab }),
              var end = units.lastIndex(where: { $0 != space && $0 != tab }) else { return removed }
        removed.insert(integersIn: 0..<start)
        removed.insert(integersIn: (end + 1)..<units.count)
        if units[start] == bar { removed.insert(start); start += 1 }
        if end >= start, units[end] == bar, end == 0 || units[end - 1] != backslash { removed.insert(end); end -= 1 }
        guard end >= start else { return removed }
        var i = start
        while i <= end {
            if units[i] == backslash, i < end, units[i + 1] == bar {
                removed.insert(i)
                i += 2
                continue
            }
            if units[i] == bar {
                units[i] = tab
                var before = i - 1
                while before >= start, isSpace(before), !removed.contains(before) { removed.insert(before); before -= 1 }
                var after = i + 1
                while after <= end, isSpace(after) { removed.insert(after); after += 1 }
            }
            i += 1
        }
        // Spaces just inside the outer bars.
        var lead = start
        while lead <= end, isSpace(lead), units[lead] != tab || removed.contains(lead) { removed.insert(lead); lead += 1 }
        var trail = end
        while trail >= start, isSpace(trail), units[trail] != tab || removed.contains(trail) { removed.insert(trail); trail -= 1 }
        return removed
    }

    /// Sets each table's rows in columns, the heading row in bold, flush with the text.
    private static func setTables(_ rows: [(range: NSRange, heading: Bool, table: Int)], in storage: NSTextStorage) {
        let string = storage.string as NSString
        let gap = Layout.textSize * 1.4
        for table in Set(rows.map(\.table)) {
            let mine = rows.filter { $0.table == table && NSMaxRange($0.range) <= string.length }
            for row in mine where row.heading {
                storage.enumerateAttribute(.font, in: row.range) { value, range, _ in
                    guard let font = value as? NSFont else { return }
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
                }
            }
            // The widest cell in each column sets where the next column starts.
            var widths: [CGFloat] = []
            for row in mine {
                var cell = row.range.location
                var column = 0
                for (offset, unit) in Array(string.substring(with: row.range).utf16).enumerated().map({ ($0.offset, Int($0.element)) }) + [(row.range.length, 9)] where unit == 9 {
                    let width = storage.attributedSubstring(from: NSRange(location: cell, length: row.range.location + offset - cell)).size().width
                    if widths.count <= column { widths.append(0) }
                    widths[column] = max(widths[column], width)
                    cell = row.range.location + offset + 1
                    column += 1
                }
            }
            var stops: [NSTextTab] = []
            var x = Layout.hang
            for width in widths.dropLast() {
                x += width + gap
                stops.append(NSTextTab(textAlignment: .left, location: x))
            }
            for (position, row) in mine.enumerated() {
                let style = ((storage.attribute(.paragraphStyle, at: row.range.location, effectiveRange: nil) as? NSParagraphStyle)
                             ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
                style.alignment = .natural
                style.hyphenationFactor = 0
                style.firstLineHeadIndent = Layout.hang
                style.headIndent = Layout.hang
                style.tabStops = stops
                style.defaultTabInterval = gap
                style.paragraphSpacingBefore = position == 0 ? Layout.textSize * 0.6 : 0
                style.paragraphSpacing = position == mine.count - 1 ? Layout.textSize * 0.6 : 0
                storage.addAttribute(.paragraphStyle, value: style, range: string.paragraphRange(for: row.range))
            }
        }
    }

    /// A footnote's number: small and raised.
    private static func raise(_ range: NSRange, in storage: NSTextStorage) {
        guard NSMaxRange(range) <= storage.length, range.length > 0 else { return }
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? EditorFont.serif(Layout.textSize)
        storage.addAttributes([.font: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.68) ?? font,
                               .baselineOffset: font.pointSize * 0.36], range: range)
    }

    /// The chapter's notes, after its last scene: "Notes", then each numbered, a step smaller.
    private static func notes(_ notes: [String]) -> NSAttributedString {
        let size = Layout.textSize * 0.85
        let result = NSMutableAttributedString()
        let title = NSMutableParagraphStyle()
        title.firstLineHeadIndent = Layout.hang
        title.headIndent = Layout.hang
        title.paragraphSpacingBefore = Layout.textSize * 2
        title.paragraphSpacing = Layout.textSize * 0.5
        result.append(NSAttributedString(string: "Notes\n", attributes: [
            .font: EditorFont.serif(Layout.textSize, weight: .semibold), .foregroundColor: PaperTheme.ink, .paragraphStyle: title]))
        let hang = size * 1.8
        for (index, words) in notes.enumerated() {
            let note = NSTextStorage(string: words + "\n")
            _ = MarkdownStyler.applyReader(to: note)
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = Layout.hang
            style.headIndent = Layout.hang + hang
            style.tabStops = [NSTextTab(textAlignment: .left, location: Layout.hang + hang)]
            style.lineHeightMultiple = 1.3
            style.paragraphSpacing = size * 0.4
            note.enumerateAttribute(.font, in: NSRange(location: 0, length: note.length)) { value, range, _ in
                let font = value as? NSFont ?? EditorFont.serif(Layout.textSize)
                note.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: size) ?? font, range: range)
            }
            note.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: note.length))
            note.addAttribute(.foregroundColor, value: PaperTheme.ink, range: NSRange(location: 0, length: note.length))
            result.append(NSAttributedString(string: "\(index + 1)\t", attributes: [
                .font: EditorFont.serif(size), .foregroundColor: PaperTheme.secondary, .paragraphStyle: style]))
            result.append(note)
        }
        return result
    }
}

/// One chapter on a reading page.
struct ReadingChapter: Equatable {
    let title: String
    let number: Int?
    let scenes: [ChapterSceneText]
}

/// A whole story's title page: its title and its author, centred.
struct StoryHeading: Equatable {
    let title: String
    let byline: String?

    func text() -> NSAttributedString {
        func style(before: CGFloat, after: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.firstLineHeadIndent = Layout.hang
            style.headIndent = Layout.hang
            style.tailIndent = -Layout.hang
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            return style
        }
        let result = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: EditorFont.serif(40), .foregroundColor: PaperTheme.ink,
            .paragraphStyle: style(before: 96, after: byline == nil ? 40 : 14)])
        if let byline, !byline.isEmpty {
            result.append(NSAttributedString(string: byline + "\n", attributes: [
                .font: NSFontManager.shared.convert(EditorFont.serif(Layout.blurbSize + 2), toHaveTrait: .italicFontMask),
                .foregroundColor: PaperTheme.secondary, .paragraphStyle: style(before: 0, after: 40)]))
        }
        return result
    }
}

/// Where a scene's own text (its Markdown) lands on the reading page, which leaves out
/// symbols, blank lines and a heading repeating the scene's name. Stretches of text kept
/// on the page in the same order, so a place in the scene can be found on the page and back.
struct ReadingMap {
    struct Piece: Equatable {
        var source: Int
        var page: Int
        var length: Int
    }

    /// Where the scene starts on the page, and how long it is there.
    let base: Int
    let length: Int
    /// Page positions are relative to `base`.
    private(set) var pieces: [Piece] = []

    /// `lines` map the Markdown to the scene's lines; `removed` are the characters of those
    /// lines the styler then took out.
    init(base: Int, length: Int, pieces lines: [Piece], removed: IndexSet) {
        self.base = base
        self.length = length
        for line in lines {
            var kept = IndexSet(integersIn: line.page..<(line.page + line.length))
            kept.subtract(removed)
            for run in kept.rangeView {
                let before = removed.count(in: 0..<run.lowerBound)
                pieces.append(Piece(source: line.source + run.lowerBound - line.page, page: run.lowerBound - before, length: run.count))
            }
        }
    }

    /// Whether a page range lies within this scene.
    func covers(_ range: NSRange) -> Bool {
        range.location >= base && NSMaxRange(range) <= base + length
    }

    /// A range of the scene's Markdown on the page. A symbol at either end is left out.
    func page(_ local: NSRange) -> NSRange? {
        guard !pieces.isEmpty else { return nil }
        let start = pieces.first { $0.source + $0.length > local.location }
            .map { $0.page + max(0, local.location - $0.source) } ?? length
        let end = local.length == 0 ? start : (pieces.last { $0.source < NSMaxRange(local) }
            .map { $0.page + min($0.length, NSMaxRange(local) - $0.source) } ?? 0)
        return NSRange(location: base + start, length: max(0, end - start))
    }

    /// A page range (within this scene) in the scene's Markdown.
    func source(_ range: NSRange) -> NSRange {
        let from = range.location - base, to = NSMaxRange(range) - base
        let start = pieces.first { $0.page + $0.length > from }
            .map { $0.source + max(0, from - $0.page) } ?? (pieces.last.map { $0.source + $0.length } ?? 0)
        let end = range.length == 0 ? start : (pieces.last { $0.page < to }
            .map { $0.source + min($0.length, to - $0.page) } ?? start)
        return NSRange(location: start, length: max(0, end - start))
    }
}
