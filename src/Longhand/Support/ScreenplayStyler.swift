import AppKit

/// Styles a Fountain screenplay in the editor: Courier Prime, each element at its place on the
/// page (`ScreenplayLayout`'s positions, counted in characters from the action's edge), the
/// symbols that force an element and those of emphasis dimmed, never hidden, so the file is
/// still exactly what you see. Notes, boneyard, sections and synopses, which never print, are
/// grey. Like `MarkdownStyler`, typing restyles only the blocks around the edit.
enum ScreenplayStyler {
    /// A little under the prose size: Courier Prime reads large for its size.
    static var size: CGFloat { max(11, Layout.textSize - 2) }
    static var characterWidth: CGFloat { size * ScreenplayFont.advance }
    /// Sixty characters: the width of action on the printed page.
    static var proseWidth: CGFloat { (characterWidth * 60).rounded(.up) }
    /// The column: the page's sixty characters, the hanging margin and the gutters.
    static var column: CGFloat { proseWidth + 2 * (Layout.hang + Layout.gutter) }

    private struct Cache {
        let size: CGFloat
        let styles: [Fountain.Kind: NSParagraphStyle]
        let fonts: [Int: NSFont]
        let base: [NSAttributedString.Key: Any]
    }
    private static var cache: Cache?

    private static var current: Cache {
        let size = self.size
        if let cache, cache.size == size { return cache }
        let cw = size * ScreenplayFont.advance
        func style(left: Int, right: Int, align: NSTextAlignment = .natural) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = Layout.hang + CGFloat(left) * cw
            p.headIndent = Layout.hang + CGFloat(left) * cw
            p.tailIndent = -(Layout.hang + CGFloat(right) * cw)
            p.alignment = align
            p.lineBreakMode = .byWordWrapping
            // Monospaced lines at a fixed height: a script's rows stay even.
            p.minimumLineHeight = (size * 1.45).rounded()
            p.maximumLineHeight = (size * 1.45).rounded()
            return p
        }
        // Left edge and right margin in characters from the action's sixty.
        let action = style(left: 0, right: 0)
        var styles: [Fountain.Kind: NSParagraphStyle] = [:]
        for kind in [Fountain.Kind.blank, .titleKey, .titleValue, .sceneHeading, .action, .pageBreak, .section, .synopsis, .lyric] {
            styles[kind] = action
        }
        styles[.character] = style(left: ScreenplayLayout.character.left - 15, right: 0)
        styles[.parenthetical] = style(left: ScreenplayLayout.parenthetical.left - 15, right: 75 - ScreenplayLayout.parenthetical.left - ScreenplayLayout.parenthetical.width)
        styles[.dialogue] = style(left: ScreenplayLayout.dialogue.left - 15, right: 75 - ScreenplayLayout.dialogue.left - ScreenplayLayout.dialogue.width)
        styles[.transition] = style(left: 0, right: 0, align: .right)
        styles[.centered] = style(left: 0, right: 0, align: .center)
        var fonts: [Int: NSFont] = [:]
        for raw in 0..<4 {
            let s = Fountain.Style(rawValue: raw)
            fonts[raw] = ScreenplayFont.font(size, style: s)
        }
        let made = Cache(
            size: size,
            styles: styles,
            fonts: fonts,
            base: [.font: fonts[0]!, .foregroundColor: PaperTheme.ink, .paragraphStyle: action]
        )
        cache = made
        return made
    }

    static var baseAttributes: [NSAttributedString.Key: Any] { current.base }

    private static let boneyard = try! NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#)
    private static let note = try! NSRegularExpression(pattern: #"\[\[[\s\S]*?\]\]"#)
    private static let sceneNumber = try! NSRegularExpression(pattern: #"#[^#\s]+#\s*$"#)

    /// Styles the whole text, or `range` of it (whole lines).
    static func apply(to storage: NSTextStorage, range: NSRange? = nil) {
        let string = storage.string as NSString
        let whole = range ?? NSRange(location: 0, length: string.length)
        let c = current
        storage.beginEditing()
        defer { storage.endEditing() }
        if whole.length > 0 {
            storage.setAttributes(c.base, range: whole)
        }
        for line in Fountain.lines(in: string, range: whole, documentStart: whole.location == 0) {
            // The line with its line break, so a blank line takes its element's spacing too.
            let full = string.lineRange(for: NSRange(location: line.range.location, length: 0))
            let span = NSIntersectionRange(full, whole)
            if span.length > 0, let style = c.styles[line.kind] {
                storage.addAttribute(.paragraphStyle, value: style, range: span)
            }
            guard line.range.length > 0 else { continue }
            style(line, in: string, storage: storage, cache: c)
        }
        // Notes and boneyard, which never print.
        for pattern in [note, boneyard] {
            for match in pattern.matches(in: string as String, range: whole) {
                storage.addAttribute(.foregroundColor, value: PaperTheme.secondary, range: match.range)
            }
        }
    }

    private static func style(_ line: Fountain.Line, in string: NSString, storage: NSTextStorage, cache c: Cache) {
        let r = line.range
        let first = string.character(at: r.location)
        func dim(_ range: NSRange) {
            guard range.length > 0 else { return }
            storage.addAttribute(.foregroundColor, value: PaperTheme.marker, range: range)
        }
        switch line.kind {
        case .titleKey:
            let text = string.substring(with: r)
            if let colon = text.firstIndex(of: ":") {
                dim(NSRange(location: r.location, length: text.utf16.distance(from: text.startIndex, to: colon) + 1))
            }
        case .section, .synopsis:
            storage.addAttribute(.foregroundColor, value: PaperTheme.secondary, range: r)
            return
        case .pageBreak:
            dim(r)
            return
        default:
            break
        }
        // The symbol that forces an element.
        if line.forced, [0x2E, 0x40, 0x21, 0x3E, 0x7E].contains(first) {
            dim(NSRange(location: r.location, length: 1))
        }
        if line.kind == .lyric, first == 0x7E { dim(NSRange(location: r.location, length: 1)) }
        if line.kind == .centered {
            let text = string.substring(with: r) as NSString
            let open = text.range(of: ">")
            let close = text.range(of: "<", options: .backwards)
            if open.location != NSNotFound { dim(NSRange(location: r.location + open.location, length: 1)) }
            if close.location != NSNotFound { dim(NSRange(location: r.location + close.location, length: 1)) }
        }
        if line.kind == .character {
            let text = string.substring(with: r) as NSString
            let caret = text.range(of: "^", options: .backwards)
            if caret.location != NSNotFound { dim(NSRange(location: r.location + caret.location, length: 1)) }
        }
        if line.kind == .sceneHeading, let match = sceneNumber.firstMatch(in: string as String, range: r) {
            dim(match.range)
        }
        // Emphasis: the words styled, the stars and underscores dimmed.
        let (styles, symbols) = Fountain.emphasis(in: string, range: r)
        var i = 0
        while i < styles.count {
            let s = styles[i]
            var j = i + 1
            while j < styles.count, styles[j] == s { j += 1 }
            if !s.isEmpty {
                let range = NSRange(location: r.location + i, length: j - i)
                let fontKey = s.intersection([.bold, .italic]).rawValue
                if fontKey != 0, let font = c.fonts[fontKey] { storage.addAttribute(.font, value: font, range: range) }
                if s.contains(.underline) { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            }
            i = j
        }
        for index in symbols { dim(NSRange(location: r.location + index, length: 1)) }
    }

    /// Restyles what an edit can have changed: the blocks (lines between blank lines) it
    /// touched, and the block either side, since an element depends on the lines around it.
    static func restyle(_ storage: NSTextStorage, around edited: NSRange) {
        let string = storage.string as NSString
        let length = string.length
        guard length > 0 else { return }
        let start = previousBlockStart(blockStart(min(edited.location, length), in: string), in: string)
        let end = nextBlockEnd(blockEnd(min(NSMaxRange(edited), length), in: string), in: string)
        apply(to: storage, range: NSRange(location: start, length: max(0, end - start)))
    }

    /// As Fountain has it: a line of exactly two spaces keeps a speech going, so it isn't blank.
    private static func isBlankLine(_ range: NSRange, in string: NSString) -> Bool {
        let line = string.substring(with: range).trimmingCharacters(in: .newlines)
        return line != "  " && line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The start of the line holding `location` (the empty last line after a final newline too).
    private static func lineStart(_ location: Int, in string: NSString) -> Int {
        if location >= string.length {
            if string.length == 0 || string.character(at: string.length - 1) == 0x0A { return string.length }
            return string.lineRange(for: NSRange(location: string.length - 1, length: 0)).location
        }
        return string.lineRange(for: NSRange(location: location, length: 0)).location
    }

    /// The start of the block holding `location`: back over lines with text.
    private static func blockStart(_ location: Int, in string: NSString) -> Int {
        var start = lineStart(location, in: string)
        while start > 0 {
            let previous = string.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlankLine(previous, in: string) { break }
            start = previous.location
        }
        return start
    }

    /// The start of the block before the one starting at `start` (back over blank lines first).
    private static func previousBlockStart(_ start: Int, in string: NSString) -> Int {
        var p = start
        while p > 0 {
            let previous = string.lineRange(for: NSRange(location: p - 1, length: 0))
            if !isBlankLine(previous, in: string) { break }
            p = previous.location
        }
        return p > 0 ? blockStart(p - 1, in: string) : 0
    }

    /// The end of the block holding `location`: its line, then on over lines with text.
    private static func blockEnd(_ location: Int, in string: NSString) -> Int {
        guard location < string.length else { return string.length }
        var end = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
        while end < string.length {
            let line = string.lineRange(for: NSRange(location: end, length: 0))
            if isBlankLine(line, in: string) { break }
            end = NSMaxRange(line)
        }
        return end
    }

    /// The end of the block after `end` (on over blank lines first).
    private static func nextBlockEnd(_ end: Int, in string: NSString) -> Int {
        var e = end
        while e < string.length {
            let line = string.lineRange(for: NSRange(location: e, length: 0))
            if !isBlankLine(line, in: string) { break }
            e = NSMaxRange(line)
        }
        return e < string.length ? blockEnd(e, in: string) : e
    }

    /// What the line holding `location` is: the editor's status bar shows it.
    static func element(at location: Int, in string: NSString) -> Fountain.Kind {
        let at = lineStart(location, in: string)
        if at >= string.length { return .blank }
        let line = string.lineRange(for: NSRange(location: at, length: 0))
        if isBlankLine(line, in: string) { return .blank }
        let start = blockStart(at, in: string)
        let end = blockEnd(at, in: string)
        let lines = Fountain.lines(in: string, range: NSRange(location: start, length: end - start), documentStart: start == 0)
        return lines.last { $0.range.location <= at }?.kind ?? .action
    }
}

/// The screenplay's keys, as Final Draft has them: Return after a name or a parenthetical
/// goes on to dialogue (one line down); after dialogue, action or a heading it starts a new
/// element (a blank line between). Tab on an empty line starts a character (what you type
/// there is set in capitals); in a speech it starts a parenthetical. A scene heading is set in
/// capitals as you type it.
enum ScreenplayKeys {
    /// Whether a line typed so far is a scene heading, so the rest is set in capitals.
    static func isHeading(_ lineSoFar: String) -> Bool { Fountain.isHeading(lineSoFar) }

    enum TabResult { case none, character, parenthetical }

    /// Return: the text to insert at the caret, or nil for the usual.
    static func newline(in textView: NSTextView) -> String? {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return nil }
        let line = string.lineRange(for: NSRange(location: min(selection.location, max(string.length - 1, 0)), length: 0))
        var contents = line
        if contents.length > 0, NSMaxRange(contents) <= string.length, string.character(at: NSMaxRange(contents) - 1) == 0x0A { contents.length -= 1 }
        // Only at the end of a line with text.
        if selection.location == string.length, selection.location > 0, string.character(at: selection.location - 1) == 0x0A { return nil }
        guard selection.location == NSMaxRange(contents) else { return nil }
        let text = string.substring(with: contents)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let kind = ScreenplayStyler.element(at: selection.location, in: string)
        switch kind {
        case .titleKey, .titleValue, .character, .parenthetical:
            return "\n"
        case .dialogue:
            return "\n\n"
        default:
            // A name typed on its own after a blank line: its dialogue goes on the next line.
            let previousBlank = contents.location == 0
                || string.substring(with: string.lineRange(for: NSRange(location: contents.location - 1, length: 0)))
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if previousBlank, text.hasPrefix("@") || Fountain.isCharacterName(text.trimmingCharacters(in: .whitespaces)),
               !isHeading(text) {
                return "\n"
            }
            return "\n\n"
        }
    }

    /// Tab: what it starts on this line.
    static func tab(in textView: NSTextView) -> TabResult {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return .none }
        let line = string.lineRange(for: NSRange(location: min(selection.location, max(string.length - 1, 0)), length: 0))
        let atEnd = selection.location == string.length && selection.location > 0 && string.character(at: selection.location - 1) == 0x0A
        let lineText = atEnd ? "" : string.substring(with: line).trimmingCharacters(in: .newlines)
        guard lineText.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        let lineStart = atEnd ? selection.location : line.location
        guard lineStart > 0 else { return .character }
        let previous = string.lineRange(for: NSRange(location: lineStart - 1, length: 0))
        let previousText = string.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
        if previousText.isEmpty { return .character }
        switch ScreenplayStyler.element(at: previous.location, in: string) {
        case .character, .dialogue:
            return .parenthetical
        default:
            // A name just typed (not yet a character until its dialogue follows).
            return Fountain.isCharacterName(previousText) ? .parenthetical : .none
        }
    }
}
