import Foundation

/// A screenplay set on pages the way Final Draft sets them: Courier Prime 12pt, ten characters
/// and six lines an inch, one-inch margins top and bottom (a page about a minute). Positions are
/// Final Draft's own defaults, in inches from the paper's left edge; Longhand's `.fdx` files
/// carry the same ones (`FinalDraft.elementSettings`) and the editor indents to them too.
///
/// Page breaks follow the trade's rules: a scene heading never ends a page; a speech that
/// doesn't fit is split after a sentence, with (MORE) under it and the name again, (CONT'D),
/// at the top of the next page; a paragraph of action keeps at least two lines each side.
enum ScreenplayLayout {
    enum Paper: String, CaseIterable, Codable {
        case letter, a4
        var title: String { self == .letter ? "Letter" : "A4" }
        /// Points (72 an inch).
        var size: CGSize { self == .letter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89) }
        /// Lines of text between the margins.
        var lines: Int { Int((size.height - 144) / 12) }
    }

    /// Where an element sits: its left edge and width, in characters from the paper's left edge
    /// (ten an inch), and the blank lines above it.
    struct Format {
        let left: Int
        let width: Int
        let before: Int
        var align: Align = .left
    }
    enum Align { case left, right, center }

    static let sceneHeading = Format(left: 15, width: 60, before: 1)
    static let action = Format(left: 15, width: 60, before: 1)
    static let character = Format(left: 35, width: 37, before: 1)
    static let parenthetical = Format(left: 30, width: 25, before: 0)
    static let dialogue = Format(left: 25, width: 35, before: 0)
    static let transition = Format(left: 15, width: 60, before: 1, align: .right)
    static let centered = Format(left: 15, width: 60, before: 1, align: .center)

    /// One printed line: where it starts, how wide its box is, and its text.
    struct Line: Equatable {
        var left: Int
        var width: Int
        var align: Align = .left
        var runs: [Fountain.Run]

        var text: String { runs.map(\.text).joined() }
    }

    struct Page: Equatable {
        /// Each row of the page (six an inch): empty for a blank line, two lines side by side
        /// for dual dialogue, a scene number either side of a heading.
        var rows: [[Line]] = []
        /// For each row, where in the file the element it belongs to starts.
        var sources: [Int] = []
    }

    struct Result {
        var pages: [Page]
        /// The page (0-based) each scene heading is on, in order.
        var headingPages: [Int]
    }

    // MARK: - Wrapping

    /// Breaks styled text into lines of at most `width` characters at spaces (a word longer than
    /// the line is cut), keeping line breaks written in the text.
    static func wrap(_ runs: [Fountain.Run], width: Int) -> [[Fountain.Run]] {
        var cells: [(Character, Fountain.Style)] = []
        for run in runs { for c in run.text { cells.append((c, run.style)) } }
        var lines: [[(Character, Fountain.Style)]] = []
        var current: [(Character, Fountain.Style)] = []
        var index = 0
        func endLine() {
            while let last = current.last, last.0 == " " { current.removeLast() }
            lines.append(current)
            current = []
        }
        while index < cells.count {
            let c = cells[index].0
            if c == "\n" {
                endLine()
                index += 1
                continue
            }
            // The next word (with the spaces before it).
            var end = index
            while end < cells.count, cells[end].0 == " " { end += 1 }
            while end < cells.count, cells[end].0 != " ", cells[end].0 != "\n" { end += 1 }
            let piece = Array(cells[index..<end])
            if current.count + piece.count <= width {
                current += piece
            } else if current.isEmpty {
                // A word longer than the line: as much as fits, the rest on the next.
                let fit = Array(piece.prefix(width))
                current = fit
                endLine()
                index += fit.count
                continue
            } else {
                endLine()
                // The new line starts with the word, not its spaces.
                var start = index
                while start < end, cells[start].0 == " " { start += 1 }
                index = start
                continue
            }
            index = end
        }
        if !current.isEmpty || lines.isEmpty { endLine() }
        return lines.map(merge)
    }

    private static func merge(_ cells: [(Character, Fountain.Style)]) -> [Fountain.Run] {
        var runs: [Fountain.Run] = []
        for (c, style) in cells {
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text.append(c)
            } else {
                runs.append(Fountain.Run(text: String(c), style: style))
            }
        }
        return runs
    }

    private static func lines(_ text: String, _ format: Format, style: Fountain.Style = [], caps: Bool = false) -> [Line] {
        var runs = Fountain.runs(text)
        if caps { runs = runs.map { Fountain.Run(text: $0.text.uppercased(), style: $0.style) } }
        if !style.isEmpty { runs = runs.map { Fountain.Run(text: $0.text, style: $0.style.union(style)) } }
        return wrap(runs, width: format.width).map { Line(left: format.left, width: format.width, align: format.align, runs: $0) }
    }

    // MARK: - Blocks

    /// What pagination places as one: an element, a speech, or two speeches side by side.
    private struct Block {
        enum Kind { case heading, action, transition, speech, dual, pageBreak }
        var kind: Kind
        var before: Int
        /// Rows; a speech's first row is the name.
        var rows: [[Line]]
        /// A speech: the name (for CONT'D), and which rows are parentheticals.
        var speaker: Line?
        var parenthetical: Set<Int> = []
        var sceneIndex: Int?
        /// Where its first element starts in the file.
        var source = 0
    }

    private static func blocks(_ document: Fountain.Document, sceneNumbers: Bool) -> [Block] {
        var result: [Block] = []
        let elements = document.elements.filter { $0.kind != .section && $0.kind != .synopsis }
        var i = 0
        var sceneCount = 0

        /// A speech: the name, then its parentheticals and dialogue, at the given places (a
        /// full speech, or one side of dual dialogue).
        func speech(from start: Int, _ f: (name: Format, paren: Format, dialogue: Format) = (character, parenthetical, dialogue))
            -> (rows: [[Line]], parens: Set<Int>, name: Line, next: Int) {
            let name = lines(elements[start].text, f.name)[0]
            var rows: [[Line]] = [[name]]
            var parens: Set<Int> = []
            var j = start + 1
            while j < elements.count, elements[j].kind == .parenthetical || elements[j].kind == .dialogue || (elements[j].kind == .lyric && j > start) {
                let element = elements[j]
                if element.kind == .parenthetical {
                    for line in lines(element.text, f.paren) {
                        parens.insert(rows.count)
                        rows.append([line])
                    }
                } else {
                    for line in lines(element.text, f.dialogue, style: element.kind == .lyric ? .italic : []) { rows.append([line]) }
                }
                j += 1
            }
            return (rows, parens, name, j)
        }

        while i < elements.count {
            let element = elements[i]
            let made = result.count
            defer { if result.count > made { result[made].source = element.source } }
            switch element.kind {
            case .sceneHeading:
                sceneCount += 1
                var rows = lines(element.text, sceneHeading, caps: true).map { [$0] }
                if sceneNumbers, !rows.isEmpty {
                    let number = element.sceneNumber ?? String(sceneCount)
                    rows[0].append(Line(left: 7, width: 6, align: .right, runs: [Fountain.Run(text: number)]))
                    rows[0].append(Line(left: 76, width: 6, runs: [Fountain.Run(text: number)]))
                }
                result.append(Block(kind: .heading, before: sceneHeading.before, rows: rows, sceneIndex: sceneCount - 1))
                i += 1
            case .action:
                result.append(Block(kind: .action, before: action.before, rows: lines(element.text, action).map { [$0] }))
                i += 1
            case .lyric:
                result.append(Block(kind: .action, before: action.before, rows: lines(element.text, action, style: .italic).map { [$0] }))
                i += 1
            case .centered:
                result.append(Block(kind: .action, before: centered.before, rows: lines(element.text, centered).map { [$0] }))
                i += 1
            case .transition:
                result.append(Block(kind: .transition, before: transition.before, rows: lines(element.text, transition, caps: true).map { [$0] }))
                i += 1
            case .pageBreak:
                result.append(Block(kind: .pageBreak, before: 0, rows: []))
                i += 1
            case .character:
                let first = speech(from: i)
                // The second speaker of dual dialogue sits beside the first, each set in half
                // the page from their own text.
                if first.next < elements.count, elements[first.next].kind == .character, elements[first.next].dual {
                    let left = speech(from: i, dualLeft)
                    let right = speech(from: first.next, dualRight)
                    let count = max(left.rows.count, right.rows.count)
                    let rows = (0..<count).map { (left.rows[safe: $0] ?? []) + (right.rows[safe: $0] ?? []) }
                    result.append(Block(kind: .dual, before: character.before, rows: rows))
                    i = right.next
                } else {
                    result.append(Block(kind: .speech, before: character.before, rows: first.rows, speaker: first.name, parenthetical: first.parens))
                    i = first.next
                }
            case .parenthetical, .dialogue:
                // A stray line of dialogue (no name above it) prints where dialogue goes.
                let format = element.kind == .parenthetical ? parenthetical : dialogue
                result.append(Block(kind: .action, before: 0, rows: lines(element.text, format).map { [$0] }))
                i += 1
            default:
                i += 1
            }
        }
        return result
    }

    /// Dual dialogue: two columns of half the page, name, parenthetical and dialogue in each.
    private static let dualLeft = (name: Format(left: 24, width: 20, before: 0), paren: Format(left: 18, width: 20, before: 0),
                                   dialogue: Format(left: 15, width: 26, before: 0))
    private static let dualRight = (name: Format(left: 54, width: 20, before: 0), paren: Format(left: 48, width: 20, before: 0),
                                    dialogue: Format(left: 45, width: 26, before: 0))

    // MARK: - Pages

    /// Sets the document on pages. The title page, if any, is not among them (see `PDF`).
    static func paginate(_ document: Fountain.Document, paper: Paper = .letter, sceneNumbers: Bool = false) -> Result {
        let height = paper.lines
        var pages: [Page] = []
        var page = Page()
        var headingPages: [Int] = []
        let all = blocks(document, sceneNumbers: sceneNumbers)

        func newPage() {
            pages.append(page)
            page = Page()
        }
        func free(before: Int) -> Int {
            height - page.rows.count - (page.rows.isEmpty ? 0 : before)
        }
        var source = 0
        func put(_ rows: [[Line]], before: Int) {
            if !page.rows.isEmpty { for _ in 0..<before { page.rows.append([]) } }
            page.rows += rows
            page.sources += Array(repeating: source, count: page.rows.count - page.sources.count)
        }

        var index = 0
        while index < all.count {
            let block = all[index]
            source = block.source
            switch block.kind {
            case .pageBreak:
                if !page.rows.isEmpty { newPage() }

            case .heading:
                // Keep the heading with at least two lines of what follows (or all of it).
                let next = index + 1 < all.count ? all[index + 1] : nil
                let following = next.map { min($0.rows.count, 2) + $0.before } ?? 0
                if block.rows.count + following > free(before: block.before), !page.rows.isEmpty { newPage() }
                if let scene = block.sceneIndex {
                    while headingPages.count < scene { headingPages.append(pages.count) }
                    headingPages.append(pages.count)
                }
                put(block.rows, before: block.before)

            case .action, .transition, .dual:
                var rows = block.rows
                var before = block.before
                while !rows.isEmpty {
                    let room = free(before: before)
                    if rows.count <= room {
                        put(rows, before: before)
                        rows = []
                    } else if block.kind == .action, rows.count >= 4, room >= 2 {
                        // Split a long paragraph, two lines at least on each side.
                        let take = min(room, rows.count - 2)
                        put(Array(rows.prefix(take)), before: before)
                        rows.removeFirst(take)
                        newPage()
                        before = 0
                    } else if page.rows.isEmpty {
                        // Longer than a page by itself: fill it and go on.
                        put(Array(rows.prefix(room)), before: 0)
                        rows.removeFirst(min(room, rows.count))
                        newPage()
                    } else {
                        newPage()
                    }
                }

            case .speech:
                var rows = block.rows
                var parens = block.parenthetical
                var before = block.before
                while !rows.isEmpty {
                    let room = free(before: before)
                    if rows.count <= room {
                        put(rows, before: before)
                        break
                    }
                    // Name, at least two lines of the speech, and (MORE) must fit, and two
                    // lines must be left for the next page; else the speech moves on whole.
                    let fits = room - 1   // rows before (MORE), name included
                    var split = splitPoint(rows: rows, parens: parens, maximum: fits)
                    if split == nil, page.rows.isEmpty {
                        // A speech longer than a page: break where it must.
                        split = max(2, min(fits, rows.count - 1))
                    }
                    guard let at = split else {
                        newPage()
                        continue
                    }
                    put(Array(rows.prefix(at)), before: before)
                    page.rows.append([Line(left: character.left, width: character.width, runs: [Fountain.Run(text: "(MORE)")])])
                    page.sources.append(source)
                    newPage()
                    let name = block.speaker.map { Line(left: $0.left, width: $0.width, runs: contd($0.runs)) }
                        ?? Line(left: character.left, width: character.width, runs: [])
                    rows = [[name]] + rows.dropFirst(at)
                    parens = Set(parens.compactMap { $0 >= at ? $0 - at + 1 : nil })
                    before = 0
                }
            }
            index += 1
        }
        if !page.rows.isEmpty || pages.isEmpty { pages.append(page) }
        return Result(pages: pages, headingPages: headingPages)
    }

    /// Where to break a speech that doesn't fit: the number of rows (name first) to keep on
    /// this page, at most `maximum`; at least two lines of speech each side; after a sentence
    /// if one ends there, never right after a parenthetical.
    private static func splitPoint(rows: [[Line]], parens: Set<Int>, maximum: Int) -> Int? {
        let lastAllowed = min(maximum, rows.count - 2)
        guard lastAllowed >= 3 else { return nil }   // the name and two lines
        var fallback: Int?
        for at in stride(from: lastAllowed, through: 3, by: -1) {
            let lastRow = at - 1
            if parens.contains(lastRow) { continue }
            if fallback == nil { fallback = at }
            let text = rows[lastRow].first?.text.trimmingCharacters(in: .whitespaces) ?? ""
            if let end = text.last, ".!?—…\"”".contains(end) { return at }
        }
        return fallback
    }

    /// "MARA" → "MARA (CONT'D)"; a name that already says so is left alone.
    private static func contd(_ runs: [Fountain.Run]) -> [Fountain.Run] {
        let text = runs.map(\.text).joined()
        if text.uppercased().contains("(CONT'D)") || text.uppercased().contains("(CONT’D)") { return runs }
        return runs + [Fountain.Run(text: " (CONT'D)")]
    }

    /// How many pages a screenplay runs to: its own measure of length.
    static func pageCount(_ text: String) -> Int {
        let document = Fountain.document(text)
        guard document.elements.contains(where: { $0.kind != .section && $0.kind != .synopsis }) else { return 0 }
        return paginate(document).pages.count
    }
}
