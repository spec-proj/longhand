import Foundation

/// Fountain (fountain.io, syntax 1.1): a screenplay as plain text, the way screenwriters type
/// it. A scene heading starts INT. or EXT.; a name in capitals on its own line, with a line
/// under it, is a character and their dialogue; a line in brackets under a character is a
/// parenthetical; capitals ending TO: are a transition. Symbols force an element where the
/// text alone can't say (`.` heading, `@` character, `!` action, `>` transition, `>…<`
/// centred, `~` lyric, `===` page break, `#` section, `=` synopsis). `[[notes]]` and
/// `/* boneyard */` never print. Highland, Fade In, WriterSolo and Final Draft read it.
///
/// Two levels: `lines(in:)` says what each line of the file is, with its place in the text
/// (the editor's styling, the contents' outline); `document(_:)` turns a file into the
/// elements a page or an export sets (notes and boneyard taken out, symbols removed).
enum Fountain {
    enum Kind: Equatable {
        case blank, titleKey, titleValue
        case sceneHeading, action, character, parenthetical, dialogue, transition
        case centered, lyric, pageBreak, section, synopsis
    }

    /// One line of the file: where it is (without its line break) and what it is.
    struct Line: Equatable {
        let range: NSRange
        let kind: Kind
        /// Forced by a symbol at its start (the symbol is dimmed, never printed).
        var forced = false
    }

    // MARK: - Lines

    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^(?:int|ext|est|int\.?/ext|i/e)[.\s]"#, options: [.caseInsensitive])
    private static let titleKeyPattern = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z ]{0,30}:"#)
    /// A title page starts with one of Fountain's own keys, so "FADE IN:" opening a script
    /// is never mistaken for one.
    private static let titleStartPattern = try! NSRegularExpression(
        pattern: #"^(?:title|credit|author|authors|source|draft date|date|contact|copyright|notes|revision)\s*:"#,
        options: [.caseInsensitive])

    /// Every line of the file, classified. `range` must start at a line's start; set
    /// `documentStart` when it starts the file (only the file's first block can be a title page).
    static func lines(in string: NSString, range whole: NSRange? = nil, documentStart: Bool? = nil) -> [Line] {
        let limit = whole ?? NSRange(location: 0, length: string.length)
        let atStart = documentStart ?? (limit.location == 0)
        // Split into lines (contents only, no line breaks).
        var all: [NSRange] = []
        var location = limit.location
        let end = NSMaxRange(limit)
        while location < end {
            var lineEnd = 0, contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            all.append(NSRange(location: location, length: min(contentsEnd, end) - location))
            if lineEnd <= location { break }
            location = lineEnd
        }
        // A final empty line after a trailing newline.
        if end == string.length, end > limit.location, isNewline(string.character(at: end - 1)) {
            all.append(NSRange(location: end, length: 0))
        }
        if all.isEmpty { all.append(NSRange(location: limit.location, length: 0)) }

        var result: [Line] = []
        result.reserveCapacity(all.count)
        var index = 0
        var firstBlock = true
        while index < all.count {
            if isBlank(all[index], in: string) {
                result.append(Line(range: all[index], kind: .blank))
                index += 1
                continue
            }
            var blockEnd = index
            while blockEnd + 1 < all.count, !isBlank(all[blockEnd + 1], in: string) { blockEnd += 1 }
            let block = Array(all[index...blockEnd])
            result += classify(block: block, in: string, titlePage: atStart && firstBlock)
            firstBlock = false
            index = blockEnd + 1
        }
        return result
    }

    /// The lines of one block (lines with text between blank lines).
    private static func classify(block: [NSRange], in string: NSString, titlePage: Bool) -> [Line] {
        let texts = block.map { string.substring(with: $0) }
        let first = texts[0]
        let trimmed = first.trimmingCharacters(in: .whitespaces)

        if titlePage, matches(titleStartPattern, first) {
            return zip(block, texts).map { range, text in
                Line(range: range, kind: matches(titleKeyPattern, text) ? .titleKey : .titleValue)
            }
        }

        // Elements that are one line each, whatever the block.
        func perLine(_ make: (String) -> Kind?) -> [Line]? {
            guard make(first) != nil else { return nil }
            return zip(block, texts).map { range, text in
                if let kind = make(text) { return Line(range: range, kind: kind, forced: true) }
                return Line(range: range, kind: .action)
            }
        }
        if let lines = perLine({ isPageBreak($0) ? .pageBreak : nil }) { return lines }
        if let lines = perLine({ $0.hasPrefix("#") ? .section : nil }) { return lines }
        if let lines = perLine({ $0.hasPrefix("=") && !isPageBreak($0) ? .synopsis : nil }) { return lines }
        if let lines = perLine({ isCentered($0) ? .centered : nil }) { return lines }
        if let lines = perLine({ $0.hasPrefix("~") ? .lyric : nil }) { return lines }

        func rest(_ kind: Kind, forced: Bool) -> [Line] {
            var lines = [Line(range: block[0], kind: kind, forced: forced)]
            for range in block.dropFirst() { lines.append(Line(range: range, kind: .action)) }
            return lines
        }
        if first.hasPrefix("!") {
            return block.enumerated().map { Line(range: $1, kind: .action, forced: $0 == 0) }
        }
        if first.hasPrefix(".") && !first.hasPrefix("..") && first.count > 1 {
            return rest(.sceneHeading, forced: true)
        }
        if matches(headingPattern, first) { return rest(.sceneHeading, forced: false) }
        if first.hasPrefix(">") { return rest(.transition, forced: true) }

        let forcedCharacter = first.hasPrefix("@")
        if block.count >= 2, forcedCharacter || isCharacterName(trimmed) {
            var lines = [Line(range: block[0], kind: .character, forced: forcedCharacter)]
            for (range, text) in zip(block, texts).dropFirst() {
                let t = text.trimmingCharacters(in: .whitespaces)
                lines.append(Line(range: range, kind: t.hasPrefix("(") && t.hasSuffix(")") ? .parenthetical : .dialogue))
            }
            return lines
        }
        if block.count == 1, trimmed.hasSuffix("TO:"), trimmed == trimmed.uppercased() {
            return [Line(range: block[0], kind: .transition)]
        }
        return block.map { Line(range: $0, kind: .action) }
    }

    /// A name in capitals: at least one letter, no small letters before any bracket (an
    /// extension may be "(cont'd)"), and a trailing ^ (dual dialogue) allowed.
    static func isCharacterName(_ line: String) -> Bool {
        var name = line
        if name.hasSuffix("^") { name.removeLast() }
        if let bracket = name.firstIndex(of: "(") { name = String(name[..<bracket]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        if name.hasSuffix("TO:") { return false }
        return name == name.uppercased() && !name.hasPrefix("!") && !name.hasPrefix("~")
    }

    static func isPageBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.allSatisfy { $0 == "=" }
    }

    static func isCentered(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && t.hasPrefix(">") && t.hasSuffix("<")
    }

    /// A line with nothing but spaces is blank, except exactly two spaces: Fountain's way of
    /// keeping an empty line inside dialogue.
    private static func isBlank(_ range: NSRange, in string: NSString) -> Bool {
        if range.length == 0 { return true }
        if range.length == 2, string.substring(with: range) == "  " { return false }
        for i in 0..<range.length {
            let c = string.character(at: range.location + i)
            if c != 0x20 && c != 0x09 { return false }
        }
        return true
    }

    private static func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 }

    /// Whether a line starts like a scene heading (INT., EXT., EST., INT./EXT., I/E).
    static func isHeading(_ line: String) -> Bool { matches(headingPattern, line) }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    // MARK: - Outline

    struct Heading: Equatable {
        /// As printed: symbols and scene number taken off, in capitals.
        let title: String
        /// The heading line in the file.
        let range: NSRange
        /// Its number: one written in the file (`#12A#`), else its place.
        let number: String
    }

    /// The scene headings, in order: a screenplay's contents.
    static func headings(in text: String) -> [Heading] {
        let string = text as NSString
        var result: [Heading] = []
        for line in lines(in: string) where line.kind == .sceneHeading {
            let (title, number) = cleanHeading(string.substring(with: line.range), forced: line.forced)
            // As printed: emphasis symbols taken off ("**EXT. FARM - DAY**").
            let printed = runs(title).map(\.text).joined()
            result.append(Heading(title: printed, range: line.range, number: number ?? String(result.count + 1)))
        }
        return result
    }

    private static let sceneNumber = try! NSRegularExpression(pattern: #"\s*#([^#\s]+)#\s*$"#)

    /// A heading as printed, and the number written on it (`#1A#`), if any.
    static func cleanHeading(_ raw: String, forced: Bool) -> (String, String?) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if forced, text.hasPrefix(".") { text.removeFirst() }
        var number: String?
        let ns = text as NSString
        if let match = sceneNumber.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            number = ns.substring(with: match.range(at: 1))
            text = ns.replacingCharacters(in: match.range, with: "")
        }
        return (text.trimmingCharacters(in: .whitespaces).uppercased(), number)
    }

    // MARK: - Emphasis

    struct Style: OptionSet, Hashable {
        let rawValue: Int
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let underline = Style(rawValue: 4)
    }

    /// A stretch of printed text in one style.
    struct Run: Equatable {
        var text: String
        var style: Style = []
    }

    private static let emphasisPatterns: [(NSRegularExpression, Style, Int)] = [
        (try! NSRegularExpression(pattern: #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#), [.bold, .italic], 3),
        (try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#), .bold, 2),
        (try! NSRegularExpression(pattern: #"\*(?=\S)(.+?)(?<=\S)\*"#), .italic, 1),
        (try! NSRegularExpression(pattern: #"_(?=\S)(.+?)(?<=\S)_"#), .underline, 1)
    ]

    /// Emphasis in a stretch of text: each character's style, and the symbols (the stars and
    /// underscores of emphasis, the backslash of an escape), which print as nothing.
    static func emphasis(in string: NSString, range: NSRange) -> (styles: [Style], symbols: IndexSet) {
        var chars = [unichar](repeating: 0, count: range.length)
        if range.length > 0 { string.getCharacters(&chars, range: range) }
        var styles = [Style](repeating: [], count: range.length)
        var symbols = IndexSet()
        // An escaped symbol is just itself: hide the backslash, and keep the symbol out of
        // the patterns' reach.
        var i = 0
        while i < chars.count {
            if chars[i] == 0x5C, i + 1 < chars.count, [0x2A, 0x5F, 0x5C].contains(chars[i + 1]) {
                symbols.insert(i)
                chars[i + 1] = 0xE000
                i += 2
            } else {
                i += 1
            }
        }
        let masked = NSString(characters: chars, length: chars.count)
        for (pattern, style, width) in emphasisPatterns {
            for match in pattern.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)) {
                let whole = match.range
                let open = whole.location..<(whole.location + width)
                let close = (NSMaxRange(whole) - width)..<NSMaxRange(whole)
                // Symbols already used by a stronger pattern can't be used again.
                if open.contains(where: symbols.contains) || close.contains(where: symbols.contains) { continue }
                symbols.insert(integersIn: open)
                symbols.insert(integersIn: close)
                for j in open.upperBound..<close.lowerBound { styles[j].insert(style) }
            }
        }
        return (styles, symbols)
    }

    /// Printed text in its runs of style: symbols gone, escapes resolved.
    static func runs(_ text: String) -> [Run] {
        let string = text as NSString
        let (styles, symbols) = emphasis(in: string, range: NSRange(location: 0, length: string.length))
        var runs: [Run] = []
        var current = Run(text: "")
        var units: [unichar] = []
        func flush() {
            guard !units.isEmpty else { return }
            current.text = String(utf16CodeUnits: units, count: units.count)
            runs.append(current)
            units = []
        }
        for i in 0..<string.length where !symbols.contains(i) {
            if styles[i] != current.style {
                flush()
                current = Run(text: "", style: styles[i])
            }
            units.append(string.character(at: i))
        }
        flush()
        return runs
    }

    // MARK: - The document

    struct Element: Equatable {
        var kind: Kind
        /// Printed text, emphasis symbols still in (see `runs`); lines joined by "\n".
        var text: String
        /// A scene heading's number written in the file.
        var sceneNumber: String?
        /// The second speaker of dual dialogue (a character written with ^).
        var dual = false
        /// Where it starts in the file (exact unless notes or boneyard were taken out before
        /// it): how the Read page and Write find the same place (⌘R).
        var source = 0
    }

    struct Document: Equatable {
        /// The title page's keys and their lines, in file order ("Title", ["Night Ferry"]).
        var titlePage: [(key: String, lines: [String])] = []
        var elements: [Element] = []

        static func == (a: Document, b: Document) -> Bool {
            a.elements == b.elements && a.titlePage.map(\.key) == b.titlePage.map(\.key)
                && a.titlePage.map(\.lines) == b.titlePage.map(\.lines)
        }

        func title(_ key: String) -> [String]? {
            titlePage.first { $0.key.lowercased() == key.lowercased() }?.lines
        }
    }

    private static let boneyard = try! NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#)
    private static let notes = try! NSRegularExpression(pattern: #"[ \t]?\[\[[\s\S]*?\]\]"#)

    /// What a file prints: its title page and its elements, in order.
    static func document(_ raw: String) -> Document {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for pattern in [boneyard, notes] {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }
        let string = text as NSString
        var document = Document()
        var previous: Kind = .blank

        for line in lines(in: string) {
            let raw = string.substring(with: line.range)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let count = document.elements.count
            defer {
                previous = line.kind
                if document.elements.count > count { document.elements[count].source = line.range.location }
            }
            switch line.kind {
            case .blank:
                continue
            case .titleKey:
                let colon = raw.firstIndex(of: ":")!
                let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
                let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                document.titlePage.append((key, value.isEmpty ? [] : [value]))
            case .titleValue:
                if !document.titlePage.isEmpty { document.titlePage[document.titlePage.count - 1].lines.append(trimmed) }
            case .sceneHeading:
                let (title, number) = cleanHeading(raw, forced: line.forced)
                document.elements.append(Element(kind: .sceneHeading, text: title, sceneNumber: number))
            case .action:
                var body = raw
                if line.forced, body.hasPrefix("!") { body.removeFirst() }
                body = trailingTrimmed(body)
                // Lines of one paragraph stay one element, their breaks kept.
                if previous == .action, let last = document.elements.last, last.kind == .action {
                    document.elements[document.elements.count - 1].text += "\n" + body
                } else {
                    document.elements.append(Element(kind: .action, text: body))
                }
            case .character:
                var name = trimmed
                if line.forced, name.hasPrefix("@") { name.removeFirst() }
                var dual = false
                if name.hasSuffix("^") {
                    name.removeLast()
                    dual = true
                }
                name = name.trimmingCharacters(in: .whitespaces)
                if !line.forced { name = name.uppercased() }
                document.elements.append(Element(kind: .character, text: name, dual: dual))
            case .parenthetical:
                document.elements.append(Element(kind: .parenthetical, text: trimmed))
            case .dialogue:
                let body = raw == "  " ? "" : trimmed
                if previous == .dialogue, let last = document.elements.last, last.kind == .dialogue {
                    document.elements[document.elements.count - 1].text += "\n" + body
                } else {
                    document.elements.append(Element(kind: .dialogue, text: body))
                }
            case .transition:
                var t = trimmed
                if line.forced, t.hasPrefix(">") { t.removeFirst() }
                document.elements.append(Element(kind: .transition, text: t.trimmingCharacters(in: .whitespaces).uppercased()))
            case .centered:
                let t = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                document.elements.append(Element(kind: .centered, text: t))
            case .lyric:
                document.elements.append(Element(kind: .lyric, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            case .pageBreak:
                document.elements.append(Element(kind: .pageBreak, text: ""))
            case .section:
                document.elements.append(Element(kind: .section, text: trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            case .synopsis:
                document.elements.append(Element(kind: .synopsis, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            }
        }
        return document
    }

    private static func trailingTrimmed(_ s: String) -> String {
        var t = s
        while let last = t.last, last == " " || last == "\t" { t.removeLast() }
        return t
    }

    /// The text of a title page in Fountain's own form, to put at the head of a file.
    static func titlePageText(_ pairs: [(key: String, lines: [String])]) -> String {
        var out = ""
        for (key, lines) in pairs where !lines.isEmpty {
            if lines.count == 1 {
                out += "\(key): \(lines[0])\n"
            } else {
                out += "\(key):\n" + lines.map { "    \($0)\n" }.joined()
            }
        }
        return out
    }
}
