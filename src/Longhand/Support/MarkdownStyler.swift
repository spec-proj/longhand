import AppKit

/// Styles Markdown in place.
///
/// - **Editor:** symbols are dimmed, never hidden, so text never moves under the cursor and
///   what you see is still the real file. Heading, quote and list symbols hang in the left
///   margin, so the edge of the prose stays straight (as in iA Writer).
/// - **Reader** (the read-only chapter view): set like a printed novel. Symbols around headings,
///   quotes, emphasis, code and links are removed; text is justified and hyphenated, leading a
///   little tighter. List bullets and scene-break rules are kept, the rules centred.
///
/// Both modes follow book convention for paragraphs: a first-line indent of one em and no gap,
/// except the first paragraph after a heading, quote, list or scene break. In the editor the
/// blank line typed between paragraphs is kept in the file but drawn almost flat.
enum MarkdownStyler {
    enum Mode { case editor, reader }

    static var baseSize: CGFloat { Layout.textSize }

    /// Leading: a little looser while writing, book-like when reading.
    private static var editorLeading: CGFloat { ProseFace.current.leading }
    private static let readerLeading: CGFloat = 1.42
    private static var em: CGFloat { Layout.textSize }

    // MARK: - Paragraph styles

    private static func paragraph(
        first: CGFloat = Layout.hang,
        head: CGFloat = Layout.hang,
        before: CGFloat = 0,
        after: CGFloat = 0,
        lineHeight: CGFloat = editorLeading,
        alignment: NSTextAlignment = .natural,
        hyphenate: Bool = false
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = max(0, first)
        style.headIndent = max(0, head)
        style.tailIndent = -Layout.hang
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = lineHeight * Layout.lineHeightCorrection
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        if hyphenate { style.hyphenationFactor = 0.9 }
        return style
    }

    /// Body text in the editor (also the typing attributes).
    private static var editorBody: NSParagraphStyle { paragraph() }

    /// A blank line between paragraphs in the editor: kept in the file, drawn almost flat, so
    /// the page reads as indented book paragraphs rather than blocks with gaps.
    private static var editorBlank: NSParagraphStyle {
        let style = paragraph(lineHeight: 1.0).mutableCopy() as! NSMutableParagraphStyle
        style.maximumLineHeight = 5
        return style
    }
    private static var blankFont: NSFont { EditorFont.serif(4) }

    /// Fonts and styles used on every line, made once per prose face rather than per line.
    private struct Cache {
        let face: ProseFace
        let size: CGFloat
        let base: [NSAttributedString.Key: Any]
        let blank: NSParagraphStyle
        let blankFont: NSFont
    }
    private static var cache: Cache?

    private static var current: Cache {
        let face = ProseFace.current
        if let cache, cache.face == face, cache.size == baseSize { return cache }
        let made = Cache(
            face: face,
            size: baseSize,
            base: [
                .font: EditorFont.serif(baseSize),
                .foregroundColor: PaperTheme.ink,
                .paragraphStyle: editorBody
            ],
            blank: editorBlank,
            blankFont: blankFont
        )
        cache = made
        return made
    }

    static var baseAttributes: [NSAttributedString.Key: Any] { current.base }

    // MARK: - Patterns

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    private static let quote = try! NSRegularExpression(pattern: #"^>[ \t]?"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^[ \t]*([-*+])[ \t]+"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^[ \t]*(\d+\.)[ \t]+"#)
    private static let rule = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    /// A song's section label on a line of its own: "[Chorus]" (not a footnote's "[^1]").
    private static let verseLabel = try! NSRegularExpression(pattern: #"^[ \t]*(\[)([^\]\^][^\]]*)(\])[ \t]*$"#)

    // Emphasis hugs its words, as Markdown has it: "2 * 3 * 4" and a bullet's own star are not
    // italics, and an underscore inside a word (a_file_name) is just an underscore.
    private static let bold = try! NSRegularExpression(pattern: #"\*\*(?=[^\s*])([^*\n]+?)(?<=\S)\*\*"#)
    private static let boldUnderscore = try! NSRegularExpression(pattern: #"(?<![\w_])__(?=[^\s_])([^_\n]+?)(?<=\S)__(?![\w_])"#)
    private static let boldItalic = try! NSRegularExpression(pattern: #"(?<!\*)\*\*\*(?=[^\s*])([^*\n]+?)(?<=\S)\*\*\*(?!\*)"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<!\*)\*(?=[^\s*])([^*\n]+?)(?<=\S)\*(?!\*)"#)
    private static let italicUnderscore = try! NSRegularExpression(pattern: #"(?<![\w_])_(?=[^\s_])([^_\n]+?)(?<=\S)_(?![\w_])"#)
    private static let code = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#)

    // MARK: - Applying

    /// Styles `range` of the storage (all of it by default), leaving the rest untouched — the
    /// chapter page keeps its opener outside the styled range.
    static func apply(to storage: NSTextStorage, range: NSRange? = nil, mode: Mode = .editor, verse: Bool = false) {
        apply(to: storage, range: range, mode: mode, previous: .none, verse: verse)
    }

    /// Sets the whole storage for reading and says which characters of the text it was given
    /// were removed (the Markdown symbols), so places in the original can be found on the page.
    /// `extra` are further characters to take out with the symbols (a table's bars, a
    /// footnote call's brackets); the result includes them.
    static func applyReader(to storage: NSTextStorage, removing extra: IndexSet = [], verse: Bool = false) -> IndexSet {
        apply(to: storage, range: nil, mode: .reader, previous: .none, verse: verse, removing: extra)
    }

    /// Restyles only what an edit can have changed: the edited lines, and the next line with
    /// text (whose indent depends on the line before it). `edited` is the changed range after
    /// the edit; `bounds` limits styling (the chapter page leaves its opener alone).
    static func restyle(_ storage: NSTextStorage, around edited: NSRange, within bounds: NSRange? = nil, verse: Bool = false) {
        let string = storage.string as NSString
        let limit = bounds ?? NSRange(location: 0, length: string.length)
        guard limit.length > 0, NSMaxRange(limit) <= string.length else { return }
        let from = min(max(edited.location, limit.location), NSMaxRange(limit))
        let to = min(max(NSMaxRange(edited), from), NSMaxRange(limit))

        var start = string.lineRange(for: NSRange(location: min(from, max(NSMaxRange(limit) - 1, 0)), length: 0)).location
        start = max(start, limit.location)
        var end = NSMaxRange(string.lineRange(for: NSRange(location: min(to, max(NSMaxRange(limit) - 1, 0)), length: 0)))
        // Through any blank lines to the next line with text, and that line too.
        while end < NSMaxRange(limit) {
            let line = string.lineRange(for: NSRange(location: end, length: 0))
            end = min(NSMaxRange(line), NSMaxRange(limit))
            if !isBlank(line, in: string) { break }
        }
        end = min(end, NSMaxRange(limit))

        // The kind of the nearest line with text above, which decides the first line's indent.
        var previous: LineKind = .none
        var probe = start
        while probe > limit.location {
            let line = string.lineRange(for: NSRange(location: probe - 1, length: 0))
            if !isBlank(line, in: string) {
                previous = kind(of: string.substring(with: line))
                break
            }
            probe = max(line.location, limit.location)
        }
        apply(to: storage, range: NSRange(location: start, length: end - start), mode: .editor, previous: previous, verse: verse)
    }

    private static func isBlank(_ line: NSRange, in string: NSString) -> Bool {
        for index in line.location..<NSMaxRange(line) {
            let unit = string.character(at: index)
            if unit != 0x0A && unit != 0x0D && unit != 0x20 && unit != 0x09 { return false }
        }
        return true
    }

    /// What kind of line this is, checked in the same order as `styleLine`.
    private static func kind(of rawLine: String) -> LineKind {
        let line = rawLine.trimmingCharacters(in: .newlines)
        let whole = NSRange(location: 0, length: (line as NSString).length)
        if heading.firstMatch(in: line, range: whole) != nil { return .heading }
        if quote.firstMatch(in: line, range: whole) != nil { return .quote }
        if rule.firstMatch(in: line, range: whole) != nil { return .rule }
        if bullet.firstMatch(in: line, range: whole) != nil || numbered.firstMatch(in: line, range: whole) != nil {
            return .list
        }
        return .body
    }

    @discardableResult
    private static func apply(to storage: NSTextStorage, range: NSRange?, mode: Mode, previous: LineKind,
                              verse: Bool = false, removing extra: IndexSet = []) -> IndexSet {
        let string = storage.string as NSString
        let full = range ?? NSRange(location: 0, length: string.length)
        guard full.length > 0, NSMaxRange(full) <= string.length else { return [] }

        var markers: [NSRange] = []
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        styleBlocks(in: string, range: full, storage: storage, mode: mode, previous: previous, verse: verse, markers: &markers)
        styleInline(in: string, range: full, storage: storage, markers: &markers)
        var removed = mode == .reader ? extra : IndexSet()
        if mode == .reader {
            // Merge first: overlapping symbol ranges deleted one by one would run off the end.
            for range in markers where range.length > 0 { removed.insert(integersIn: range.location..<NSMaxRange(range)) }
            for range in removed.rangeView.reversed() {
                storage.deleteCharacters(in: NSRange(location: range.lowerBound, length: range.count))
            }
        }
        storage.endEditing()
        return removed
    }

    // MARK: - Blocks

    private enum LineKind { case none, body, heading, quote, list, rule }

    private static func styleBlocks(
        in string: NSString,
        range: NSRange,
        storage: NSTextStorage,
        mode: Mode,
        previous start: LineKind,
        verse: Bool,
        markers: inout [NSRange]
    ) {
        var location = range.location
        var previous = start

        while location < NSMaxRange(range) {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            var contentRange = lineRange
            while contentRange.length > 0 {
                let character = string.character(at: NSMaxRange(contentRange) - 1)
                guard character == 0x0A || character == 0x0D else { break }
                contentRange.length -= 1
            }

            if contentRange.length > 0 {
                previous = styleLine(
                    in: string,
                    range: contentRange,
                    paragraphRange: lineRange,
                    storage: storage,
                    mode: mode,
                    previous: previous,
                    verse: verse,
                    markers: &markers
                )
            } else if lineRange.length > 0, mode == .editor, !verse {
                storage.addAttribute(.paragraphStyle, value: current.blank, range: lineRange)
                storage.addAttribute(.font, value: current.blankFont, range: lineRange)
            }
            location = NSMaxRange(lineRange)
        }
    }

    private static func width(of range: NSRange, in string: NSString, font: NSFont) -> CGFloat {
        (string.substring(with: range) as NSString).size(withAttributes: [.font: font]).width
    }

    private static func styleLine(
        in string: NSString,
        range: NSRange,
        paragraphRange: NSRange,
        storage: NSTextStorage,
        mode: Mode,
        previous: LineKind,
        verse: Bool = false,
        markers: inout [NSRange]
    ) -> LineKind {
        let line = string.substring(with: range)
        let lineLength = NSRange(location: 0, length: (line as NSString).length)
        let base = EditorFont.serif(baseSize)
        let reader = mode == .reader
        let leading = reader ? readerLeading : editorLeading

        func marker(_ match: NSTextCheckingResult) -> NSRange {
            NSRange(location: range.location, length: match.range.length)
        }

        if let match = heading.firstMatch(in: line, range: lineLength) {
            let level = match.range(at: 1).length
            let font = EditorFont.serif(headingSize(level), weight: .semibold)
            let symbols = marker(match)
            let hangBy = reader ? 0 : width(of: symbols, in: string, font: font)
            let style = paragraph(
                first: Layout.hang - hangBy,
                before: previous == .none ? 0 : em * 1.4,
                after: em * 0.5,
                lineHeight: leading
            )
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            dim(symbols, in: storage)
            markers.append(symbols)
            return .heading
        }

        if let match = quote.firstMatch(in: line, range: lineLength) {
            let indent = Layout.hang + em * 1.4
            let symbols = marker(match)
            let hangBy = reader ? 0 : width(of: symbols, in: string, font: base)
            // Set off from the text by a little space and an indent on both sides.
            let style = (paragraph(
                first: indent - hangBy,
                head: indent,
                before: previous != .quote ? em * 0.5 : 0,
                after: em * 0.5,
                lineHeight: leading
            ).mutableCopy() as! NSMutableParagraphStyle)
            style.tailIndent = -(Layout.hang + em * 1.4)
            storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            storage.addAttribute(.foregroundColor, value: PaperTheme.quote, range: range)
            dim(symbols, in: storage)
            markers.append(symbols)
            return .quote
        }

        if rule.firstMatch(in: line, range: lineLength) != nil {
            // A break inside a scene, set as a novel sets one: centred, in a line's worth of
            // white space, the symbols spaced out as an ornament.
            let style = paragraph(
                first: Layout.hang,
                before: em * 1.1,
                after: em * 1.1,
                lineHeight: leading,
                alignment: .center
            )
            storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            storage.addAttribute(.kern, value: em * 0.35, range: range)
            // Part of the page (it is drawn as asterisks), not a dimmed symbol.
            storage.addAttribute(.foregroundColor, value: PaperTheme.secondary, range: range)
            return .rule
        }

        if verse {
            // Verse (owner, 2026-11-14): every line as written, flush left, never justified; a
            // line too long for the page hangs an em and a half under its start. A blank line
            // between stanzas keeps its full height.
            let style = paragraph(first: Layout.hang, head: Layout.hang + em * 1.5, lineHeight: leading)
            storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            // A song's section label ("[Chorus]"): small and grey, its brackets dimmed (gone
            // when reading).
            if let match = verseLabel.firstMatch(in: line, range: lineLength) {
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: Layout.chromeSize, weight: .semibold), range: range)
                storage.addAttribute(.foregroundColor, value: PaperTheme.secondary, range: range)
                for bracket in [match.range(at: 1), match.range(at: 3)] {
                    let symbol = NSRange(location: range.location + bracket.location, length: bracket.length)
                    dim(symbol, in: storage)
                    markers.append(symbol)
                }
            }
            return .body
        }

        if let match = bullet.firstMatch(in: line, range: lineLength)
            ?? numbered.firstMatch(in: line, range: lineLength) {
            let symbols = marker(match)
            let style = paragraph(
                first: Layout.hang - width(of: symbols, in: string, font: base),
                before: previous != .list ? em * 0.4 : 0,
                after: 2,
                lineHeight: leading
            )
            storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            dim(symbols, in: storage)
            return .list
        }

        // Book paragraphs: a one-em first-line indent and no gap, except the first after a
        // heading, quote, list or scene break (and the first on the page).
        let indent = previous == .body ? em : 0
        storage.addAttribute(
            .paragraphStyle,
            value: paragraph(
                first: Layout.hang + indent,
                before: previous == .list ? em * 0.4 : 0,
                lineHeight: leading,
                alignment: reader ? .justified : .natural,
                hyphenate: reader
            ),
            range: paragraphRange
        )
        return .body
    }

    /// Headings move with View › Bigger Text, so a heading is never smaller than the prose.
    private static func headingSize(_ level: Int) -> CGFloat {
        let step = CGFloat(ProseSize.current)
        switch level {
        case 1: return 23 + step
        case 2: return 20 + step
        case 3: return 18 + step
        default: return 17 + step
        }
    }

    // MARK: - Inline

    private static func styleInline(
        in string: NSString,
        range full: NSRange,
        storage: NSTextStorage,
        markers: inout [NSRange]
    ) {

        apply(bold, in: string, range: full, storage: storage, markers: &markers) { content in
            storage.addAttribute(.font, value: EditorFont.serif(baseSize, weight: .semibold), range: content)
            storage.addAttribute(.foregroundColor, value: PaperTheme.ink, range: content)
        }
        apply(boldUnderscore, in: string, range: full, storage: storage, markers: &markers) { content in
            storage.addAttribute(.font, value: EditorFont.serif(baseSize, weight: .semibold), range: content)
            storage.addAttribute(.foregroundColor, value: PaperTheme.ink, range: content)
        }
        apply(italic, in: string, range: full, storage: storage, markers: &markers) { content in
            storage.addAttribute(.font, value: EditorFont.italic(baseSize), range: content)
            storage.addAttribute(.foregroundColor, value: PaperTheme.ink, range: content)
        }
        apply(italicUnderscore, in: string, range: full, storage: storage, markers: &markers) { content in
            storage.addAttribute(.font, value: EditorFont.italic(baseSize), range: content)
            storage.addAttribute(.foregroundColor, value: PaperTheme.ink, range: content)
        }
        apply(boldItalic, in: string, range: full, storage: storage, markers: &markers) { content in
            storage.addAttribute(.font, value: EditorFont.boldItalic(baseSize), range: content)
            storage.addAttribute(.foregroundColor, value: PaperTheme.ink, range: content)
        }
        apply(code, in: string, range: full, storage: storage, markers: &markers) { content in
            storage.addAttribute(.font, value: EditorFont.mono(baseSize - 2), range: content)
            storage.addAttribute(.foregroundColor, value: PaperTheme.ink, range: content)
            storage.addAttribute(.backgroundColor, value: PaperTheme.codeFill, range: content)
        }
        apply(link, in: string, range: full, storage: storage, markers: &markers) { content in
            storage.addAttribute(.foregroundColor, value: PaperTheme.accent, range: content)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: content)
        }
    }

    private static func apply(
        _ regex: NSRegularExpression,
        in string: NSString,
        range: NSRange,
        storage: NSTextStorage,
        markers: inout [NSRange],
        content: (NSRange) -> Void
    ) {
        for match in regex.matches(in: string as String, range: range) {
            let contentRange = match.range(at: 1)
            guard contentRange.location != NSNotFound, contentRange.length > 0 else { continue }
            dim(match.range, in: storage)
            content(contentRange)
            // The symbols either side of the content: `**` … `**`, `[` … `](url)`.
            markers.append(NSRange(location: match.range.location,
                                   length: contentRange.location - match.range.location))
            markers.append(NSRange(location: NSMaxRange(contentRange),
                                   length: NSMaxRange(match.range) - NSMaxRange(contentRange)))
        }
    }

    private static func dim(_ range: NSRange, in storage: NSTextStorage) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: PaperTheme.marker, range: range)
    }
}

/// Spelling and grammar marks that fall only on Markdown symbols (`>`, `#`, `*`, `-`) are
/// dropped: the checker reads a quote's `>` as a stray character and underlined it.
enum ProofingFilter {
    static func filter(_ results: [NSTextCheckingResult], in string: NSString) -> [NSTextCheckingResult] {
        results.filter { result in
            switch result.resultType {
            case .dash:
                // Dashes typed at the start of a line are Markdown (--- is a break): turned
                // into an em dash as they were typed, a break could never be typed at all.
                // Dashes that open a line of prose ("--Hello," she said) still become one.
                return !(startsLine(result.range, in: string) && endsLine(result.range, in: string))
            case .spelling:
                return hasWords(result.range, in: string)
            case .grammar:
                // A grammar mark covers a sentence; its details say which parts are marked.
                let details = result.grammarDetails ?? []
                guard !details.isEmpty else { return hasWords(result.range, in: string) }
                return details.contains { detail in
                    guard let value = detail[NSGrammarRange] as? NSValue else { return true }
                    let local = value.rangeValue
                    return hasWords(NSRange(location: result.range.location + local.location, length: local.length), in: string)
                }
            default:
                return true
            }
        }
    }

    /// Whether only spaces and hyphens come before `range` on its line.
    private static func startsLine(_ range: NSRange, in string: NSString) -> Bool {
        guard range.location != NSNotFound, range.location <= string.length else { return false }
        var index = range.location - 1
        while index >= 0 {
            let unit = string.character(at: index)
            if unit == 0x0A || unit == 0x0D { return true }
            if unit != 0x20 && unit != 0x09 && unit != 0x2D { return false }
            index -= 1
        }
        return true
    }

    /// Whether only spaces and hyphens follow `range` on its line.
    private static func endsLine(_ range: NSRange, in string: NSString) -> Bool {
        var index = NSMaxRange(range)
        while index < string.length {
            let unit = string.character(at: index)
            if unit == 0x0A || unit == 0x0D { return true }
            if unit != 0x20 && unit != 0x09 && unit != 0x2D { return false }
            index += 1
        }
        return true
    }

    private static func hasWords(_ range: NSRange, in string: NSString) -> Bool {
        guard range.location != NSNotFound, NSMaxRange(range) <= string.length else { return true }
        return string.substring(with: range).rangeOfCharacter(from: .alphanumerics) != nil
    }
}
