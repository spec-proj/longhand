import Foundation

/// What the export sheet remembers, per library, in `.longhand/export.json`.
struct ExportSettings: Codable, Equatable {
    enum Format: String, Codable, CaseIterable {
        case manuscriptWord, manuscriptPDF, bookPDF, epub
        var title: String {
            switch self {
            case .manuscriptWord: return "Manuscript (Word)"
            case .manuscriptPDF: return "Manuscript (PDF)"
            case .bookPDF: return "Book (PDF)"
            case .epub: return "E-book (EPUB)"
            }
        }
        /// The export sheet's File row, under Manuscript or Book (four full titles in one
        /// row ran past the sheet's edge).
        var fileTitle: String {
            switch self {
            case .manuscriptWord: return "Word"
            case .manuscriptPDF, .bookPDF: return "PDF"
            case .epub: return "E-book (EPUB)"
            }
        }
        var fileExtension: String {
            switch self {
            case .manuscriptWord: return "docx"
            case .manuscriptPDF, .bookPDF: return "pdf"
            case .epub: return "epub"
            }
        }
        /// A book to read, as against a manuscript to submit.
        var isBook: Bool { self == .bookPDF || self == .epub }
    }

    enum Paper: String, Codable, CaseIterable {
        case letter, a4
        var title: String { self == .letter ? "Letter" : "A4" }
        /// Points (1/72 inch).
        var size: CGSize { self == .letter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89) }
        /// Twentieths of a point, for Word.
        var twips: (width: Int, height: Int) { self == .letter ? (12240, 15840) : (11906, 16838) }
    }

    enum Typeface: String, Codable, CaseIterable {
        case times, courier
        var title: String { self == .times ? "Times New Roman" : "Courier" }
        /// The font Word and macOS know it by.
        var fontName: String { self == .times ? "Times New Roman" : "Courier New" }
    }

    /// A printed book's page size.
    enum Trim: String, Codable, CaseIterable {
        case small, medium, large
        var title: String {
            switch self {
            case .small: return "5 × 8 in"
            case .medium: return "5.5 × 8.5 in"
            case .large: return "6 × 9 in"
            }
        }
        var size: CGSize {
            switch self {
            case .small: return CGSize(width: 360, height: 576)
            case .medium: return CGSize(width: 396, height: 612)
            case .large: return CGSize(width: 432, height: 648)
            }
        }
        /// The body size for the page.
        var bodySize: CGFloat {
            switch self {
            case .small: return 11
            case .medium: return 11.5
            case .large: return 12
            }
        }
    }

    var format: Format = .manuscriptWord
    var trim: Trim = .medium
    var paper: Paper = .letter
    var typeface: Typeface = .times
    /// The lettered cover an e-book gets when its story has no cover picture; nil for none.
    var letteredCover: LetteredCover.Style?
    // The author, filled in from the book's Book Info page before exporting (`useAuthor`).
    // Not saved with the export choices: older libraries kept them here, and
    // `LibraryStore.adoptExportAuthor` moves them to Book Info.
    /// Legal name, for the contact block.
    var name: String = ""
    /// The byline, if different from the legal name.
    var penName: String = ""
    /// Address, phone, email: one per line.
    var contact: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case format, trim, paper, typeface, letteredCover, name, penName, contact
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(trim, forKey: .trim)
        try c.encode(paper, forKey: .paper)
        try c.encode(typeface, forKey: .typeface)
        try c.encodeIfPresent(letteredCover, forKey: .letteredCover)
    }

    /// The author's details from Book Info: the contact block is the address, then phone and
    /// email, one per line.
    mutating func useAuthor(_ info: SceneInfo) {
        func clean(_ text: String?) -> String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        name = clean(info.authorName)
        penName = clean(info.authorPenName)
        contact = [clean(info.authorAddress), clean(info.authorPhone), clean(info.authorEmail)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decode(Format.self, forKey: .format)) ?? .manuscriptWord
        paper = (try? c.decode(Paper.self, forKey: .paper)) ?? .letter
        typeface = (try? c.decode(Typeface.self, forKey: .typeface)) ?? .times
        trim = (try? c.decode(Trim.self, forKey: .trim)) ?? .medium
        letteredCover = try? c.decode(LetteredCover.Style.self, forKey: .letteredCover)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        penName = (try? c.decode(String.self, forKey: .penName)) ?? ""
        contact = (try? c.decode(String.self, forKey: .contact)) ?? ""
    }

    var byline: String {
        let pen = penName.trimmingCharacters(in: .whitespacesAndNewlines)
        return pen.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : pen
    }

    /// The surname for the running header: the byline's last word.
    var surname: String {
        byline.split(separator: " ").last.map(String.init) ?? ""
    }
}

/// A book ready to be set: chapters of blocks, independent of the file format.
struct ManuscriptBook {
    struct Run: Equatable {
        var text: String
        var italic = false
        var bold = false
        /// A footnote called out here: its words. The run's own text is empty until
        /// `numbered` gives it a number.
        var note: [Run]? = nil
        /// Set small and raised (a footnote's number in the PDFs).
        var raised = false
    }

    enum Block: Equatable {
        /// A paragraph of prose. `opening` is true for the first paragraph of a chapter and
        /// after a heading, quote or scene break (book convention: no indent there).
        case paragraph([Run], opening: Bool)
        case heading([Run])
        case quote([Run])
        case sceneBreak
        /// A table: rows of cells, the first row its headings.
        case table([[[Run]]])
    }

    struct Chapter {
        let number: Int
        let title: String
        let blocks: [Block]
        /// False when the story's numbers are off (its page › Numbers): no "Chapter 2" line.
        var showsNumber = true

        /// "Chapter 2" above the title, or nil when numbers are off.
        var label: String? { showsNumber ? "Chapter \(number)" : nil }
        /// The title under the label, or nil when it only repeats the number ("2", "Chapter 2").
        var heading: String? {
            showsNumber && DocxWriter.isPlainNumber(title, number) ? nil : title
        }
        /// The chapter's name in a contents or running head.
        var name: String { heading ?? "Chapter \(number)" }

        /// For formats without real footnotes (the PDFs): each footnote becomes a raised
        /// number where it was called out, and the notes are listed, numbered from 1 in each
        /// chapter, to be set at the chapter's end.
        func numbered() -> (blocks: [Block], notes: [[Run]]) {
            var notes: [[Run]] = []
            func number(_ runs: [Run]) -> [Run] {
                runs.map { run in
                    guard let note = run.note else { return run }
                    notes.append(note)
                    return Run(text: "\(notes.count)", raised: true)
                }
            }
            let out = blocks.map { block -> Block in
                switch block {
                case .paragraph(let runs, let opening): return .paragraph(number(runs), opening: opening)
                case .heading(let runs): return .heading(number(runs))
                case .quote(let runs): return .quote(number(runs))
                case .sceneBreak: return .sceneBreak
                case .table(let rows): return .table(rows.map { $0.map(number) })
                }
            }
            return (out, notes)
        }
    }

    let title: String
    let words: Int
    let chapters: [Chapter]

    /// "about 83,000 words": to the nearest thousand, or hundred for short work.
    var roundedWords: String {
        let step = words < 1000 ? 100 : 1000
        let rounded = max(step, Int((Double(words) / Double(step)).rounded()) * step)
        // English-language publishing writes 83,000, whatever the Mac's region.
        return "about \(rounded.formatted(.number.locale(Locale(identifier: "en_US")))) words"
    }
}

/// Turns scene files into blocks. Markdown is read the way a reader would see it: emphasis kept,
/// symbols gone, a heading that only repeats the scene's name dropped, rules become scene
/// breaks, and consecutive scenes are separated by a scene break.
enum ManuscriptBuilder {
    static func make(title: String, chapters: [(title: String, scenes: [(title: String, text: String)])], words: Int, numbered: Bool = true) -> ManuscriptBook {
        var made: [ManuscriptBook.Chapter] = []
        for (index, chapter) in chapters.enumerated() {
            var blocks: [ManuscriptBook.Block] = []
            for scene in chapter.scenes {
                var sceneBlocks = self.blocks(from: scene.text, sceneTitle: scene.title)
                // A break typed at the very start or end of a scene would double the one
                // between scenes.
                while sceneBlocks.first == .sceneBreak { sceneBlocks.removeFirst() }
                while sceneBlocks.last == .sceneBreak { sceneBlocks.removeLast() }
                guard !sceneBlocks.isEmpty else { continue }
                if !blocks.isEmpty { blocks.append(.sceneBreak) }
                blocks += sceneBlocks
            }
            made.append(ManuscriptBook.Chapter(number: index + 1, title: chapter.title, blocks: markOpenings(blocks), showsNumber: numbered))
        }
        return ManuscriptBook(title: title, words: words, chapters: made)
    }

    /// Marks the paragraphs that open a chapter or follow a heading, quote or break.
    private static func markOpenings(_ blocks: [ManuscriptBook.Block]) -> [ManuscriptBook.Block] {
        var previousIsProse = false
        return blocks.map { block in
            switch block {
            case .paragraph(let runs, _):
                defer { previousIsProse = true }
                return .paragraph(runs, opening: !previousIsProse)
            default:
                previousIsProse = false
                return block
            }
        }
    }

    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.*?)[ \t#]*$"#)
    private static let rulePattern = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let tableRulePattern = try! NSRegularExpression(pattern: #"^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?$"#)

    /// The cells of one line of a table: split at the bars (a "\|" is a bar in the text).
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [""]
        var escaped = false
        for character in text {
            if escaped {
                cells[cells.count - 1] += character == "|" ? "|" : "\\" + String(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append("")
            } else {
                cells[cells.count - 1].append(character)
            }
        }
        if escaped { cells[cells.count - 1] += "\\" }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static let notePattern = try! NSRegularExpression(pattern: #"^[ ]{0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#)
    private static let listPattern = try! NSRegularExpression(pattern: #"^[ \t]*([-*+]|\d+\.)[ \t]+(.*)$"#)

    static func blocks(from markdown: String, sceneTitle: String) -> [ManuscriptBook.Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [ManuscriptBook.Block] = []
        var paragraph: [String] = []

        // Footnotes: "[^1]: the note" lines (with any indented lines that carry it on) are
        // taken out of the text and kept by name; "[^1]" in the prose calls one out.
        var notes: [String: String] = [:]
        var body: [String] = []
        var open: String?
        for raw in lines {
            let ns = raw as NSString
            if let match = notePattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                notes[name] = ns.substring(with: match.range(at: 2))
                open = name
            } else if let name = open, raw.hasPrefix("    ") || raw.hasPrefix("\t"),
                      !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                notes[name] = (notes[name] ?? "") + " " + raw.trimmingCharacters(in: .whitespaces)
            } else {
                open = nil
                body.append(raw)
            }
        }
        func runs(_ text: String) -> [ManuscriptBook.Run] { Self.runs(text, notes: notes) }

        func flush() {
            defer { paragraph = [] }
            guard !paragraph.isEmpty else { return }
            // A table: lines of cells between bars, the second line all dashes.
            if paragraph.count >= 2, paragraph[0].contains("|"), matches(tableRulePattern, paragraph[1]) {
                let rows = ([paragraph[0]] + paragraph.dropFirst(2)).map { cells($0).map { runs($0) } }
                let width = rows.map(\.count).max() ?? 0
                if width > 0 {
                    blocks.append(.table(rows.map { $0 + Array(repeating: [], count: width - $0.count) }))
                    return
                }
            }
            if paragraph.allSatisfy({ $0.hasPrefix(">") }) {
                let text = paragraph.map { line -> String in
                    var line = String(line.dropFirst())
                    if line.hasPrefix(" ") { line.removeFirst() }
                    return line
                }.joined(separator: " ")
                blocks.append(.quote(runs(text)))
                return
            }
            if paragraph.allSatisfy({ matches(listPattern, $0) }) {
                for line in paragraph {
                    let ns = line as NSString
                    guard let match = listPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                    let marker = ns.substring(with: match.range(at: 1))
                    let item = ns.substring(with: match.range(at: 2))
                    let prefix = marker.hasSuffix(".") ? marker + " " : "– "
                    blocks.append(.paragraph(runs(prefix + item), opening: false))
                }
                return
            }
            blocks.append(.paragraph(runs(paragraph.joined(separator: " ")), opening: false))
        }

        for raw in body {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            let ns = line as NSString
            if let match = headingPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush()
                let level = match.range(at: 1).length
                let text = ns.substring(with: match.range(at: 2))
                if level == 1, text.caseInsensitiveCompare(sceneTitle) == .orderedSame { continue }
                blocks.append(.heading(runs(text)))
                continue
            }
            if matches(rulePattern, line) {
                flush()
                if blocks.last != .sceneBreak { blocks.append(.sceneBreak) }
                continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static let inlinePattern = try! NSRegularExpression(
        pattern: #"(?<t>\*\*\*|___)(?<ti>.+?)\k<t>|(?<b>\*\*|__)(?<bi>.+?)\k<b>|(?<![\w*])(?<e>[*_])(?![\s*_])(?<ei>.+?)(?<![\s*_])\k<e>(?![\w*])|`(?<c>[^`]+)`|\[\^(?<f>[^\]\s]+)\]|\[(?<l>[^\]]+)\]\((?<u>[^)]+)\)"#
    )

    /// Characters Markdown lets you escape with a backslash ("\*" is a plain star).
    private static let escapable: [Character] = Array("\\*_`[]()#>-+.!~")
    /// Where escaped characters wait while emphasis is worked out: one private-use
    /// character each, so "\*" can never open or close anything.
    private static let escapeBase: UInt32 = 0xE000

    /// Emphasis, strong, both together, code and links, as runs of plain text. Emphasis can
    /// sit inside strong and the other way round; a backslash makes the next symbol plain.
    /// `notes` are the scene's footnotes by name; "[^name]" becomes a run carrying its note.
    static func runs(_ text: String, notes: [String: String] = [:]) -> [ManuscriptBook.Run] {
        var hidden = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            if character == "\\", let next = characters.next() {
                if let index = escapable.firstIndex(of: next), let scalar = Unicode.Scalar(escapeBase + UInt32(index)) {
                    hidden.unicodeScalars.append(scalar)
                } else {
                    hidden.append(character)
                    hidden.append(next)
                }
            } else {
                hidden.append(character)
            }
        }
        return parse(hidden, notes: notes).compactMap { run in
            var run = run
            run.text = String(String.UnicodeScalarView(run.text.unicodeScalars.map { scalar in
                let index = Int(scalar.value) - Int(escapeBase)
                return escapable.indices.contains(index) ? escapable[index].unicodeScalars.first! : scalar
            }))
            return run.text.isEmpty && run.note == nil ? nil : run
        }
    }

    private static func parse(_ text: String, notes: [String: String], bold: Bool = false, italic: Bool = false) -> [ManuscriptBook.Run] {
        let ns = text as NSString
        var result: [ManuscriptBook.Run] = []
        var cursor = 0
        func plain(_ range: NSRange) {
            guard range.length > 0 else { return }
            result.append(.init(text: ns.substring(with: range), italic: italic, bold: bold))
        }
        for match in inlinePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            plain(NSRange(location: cursor, length: match.range.location - cursor))
            func inner(_ name: String) -> String? {
                let range = match.range(withName: name)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            if let both = inner("ti") {
                result += parse(both, notes: notes, bold: true, italic: true)
            } else if let strong = inner("bi") {
                result += parse(strong, notes: notes, bold: true, italic: italic)
            } else if let emphasis = inner("ei") {
                result += parse(emphasis, notes: notes, bold: bold, italic: true)
            } else if let code = inner("c") {
                result.append(.init(text: code, italic: italic, bold: bold))
            } else if let name = inner("f") {
                // A footnote with words to it; a call with no note stays as typed.
                if let words = notes[name] {
                    result.append(.init(text: "", note: runs(words)))
                } else {
                    plain(match.range)
                }
            } else if let link = inner("l") {
                result += parse(link, notes: notes, bold: bold, italic: italic)
            }
            cursor = NSMaxRange(match.range)
        }
        plain(NSRange(location: cursor, length: ns.length - cursor))
        // Neighbours set the same way read as one run.
        var joined: [ManuscriptBook.Run] = []
        for run in result where !run.text.isEmpty || run.note != nil {
            if var last = joined.last, last.note == nil, run.note == nil, last.bold == run.bold, last.italic == run.italic {
                last.text += run.text
                joined[joined.count - 1] = last
            } else {
                joined.append(run)
            }
        }
        return joined
    }
}
