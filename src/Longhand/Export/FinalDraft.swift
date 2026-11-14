import Foundation

/// Final Draft's file (`.fdx`): XML, one `<Paragraph Type="…">` per element, styled `<Text>`
/// runs inside. Longhand writes one from a screenplay (export) and reads one into Fountain
/// (File › Import Final Draft…). Element positions are Final Draft's own defaults, in Courier
/// Prime (`ScreenplayLayout`), so a script looks the same in both.
enum FinalDraft {

    // MARK: - Writing

    static func fdx(_ document: Fountain.Document, titlePage: ScreenplayTitlePage?, sceneNumbers: Bool = false) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
        <FinalDraft DocumentType="Script" Template="No" Version="5">

        <Content>

        """
        let elements = document.elements.filter { $0.kind != .section && $0.kind != .synopsis }
        var newPage = false
        var sceneCount = 0
        var i = 0

        func paragraph(_ type: String, _ text: String, number: String? = nil, extra: String = "", caps: Bool = false) -> String {
            var attributes = "Type=\"\(type)\""
            if let number { attributes += " Number=\"\(escape(number))\"" }
            attributes += extra
            if newPage {
                attributes += " StartsNewPage=\"Yes\""
                newPage = false
            }
            return "    <Paragraph \(attributes)>\n" + texts(text, caps: caps) + "    </Paragraph>\n"
        }
        // Lines of one element become paragraphs of their own, the later ones close up.
        func paragraphs(_ type: String, _ text: String, extra: String = "") -> String {
            text.components(separatedBy: "\n").enumerated().map { index, line in
                paragraph(type, line, extra: extra + (index > 0 && type == "Action" ? " SpaceBefore=\"0\"" : ""))
            }.joined()
        }
        func speech(from start: Int) -> (String, Int) {
            var s = paragraph("Character", elements[start].text, caps: !elements[start].text.contains(where: \.isLowercase))
            var j = start + 1
            while j < elements.count, elements[j].kind == .parenthetical || elements[j].kind == .dialogue || elements[j].kind == .lyric {
                let e = elements[j]
                switch e.kind {
                case .parenthetical: s += paragraph("Parenthetical", e.text)
                case .lyric: s += paragraph("Dialogue", "*\(e.text)*")
                default: s += paragraphs("Dialogue", e.text)
                }
                j += 1
            }
            return (s, j)
        }

        while i < elements.count {
            let e = elements[i]
            switch e.kind {
            case .sceneHeading:
                sceneCount += 1
                let number = e.sceneNumber ?? (sceneNumbers ? String(sceneCount) : nil)
                out += paragraph("Scene Heading", e.text, number: number, caps: true)
                i += 1
            case .action:
                out += paragraphs("Action", e.text)
                i += 1
            case .centered:
                out += paragraphs("Action", e.text, extra: " Alignment=\"Center\"")
                i += 1
            case .lyric:
                out += paragraph("Action", "*\(e.text)*")
                i += 1
            case .transition:
                out += paragraph("Transition", e.text, caps: true)
                i += 1
            case .pageBreak:
                newPage = true
                i += 1
            case .character:
                let (first, next) = speech(from: i)
                if next < elements.count, elements[next].kind == .character, elements[next].dual {
                    let (second, after) = speech(from: next)
                    out += "    <Paragraph>\n      <DualDialogue>\n" + indent(first) + indent(second) + "      </DualDialogue>\n    </Paragraph>\n"
                    i = after
                } else {
                    out += first
                    i = next
                }
            case .parenthetical:
                out += paragraph("Parenthetical", e.text)
                i += 1
            case .dialogue:
                out += paragraphs("Dialogue", e.text)
                i += 1
            default:
                i += 1
            }
        }
        out += "\n</Content>\n\n" + elementSettings
        if let titlePage { out += titlePageXML(titlePage) }
        out += "\n</FinalDraft>\n"
        return out
    }

    private static func indent(_ block: String) -> String {
        block.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n")
    }

    /// A line's `<Text>` runs, emphasis as Final Draft's styles.
    private static func texts(_ text: String, caps: Bool) -> String {
        let runs = Fountain.runs(text)
        if runs.isEmpty { return "      <Text></Text>\n" }
        return runs.map { run in
            var styles: [String] = []
            if run.style.contains(.bold) { styles.append("Bold") }
            if run.style.contains(.italic) { styles.append("Italic") }
            if run.style.contains(.underline) { styles.append("Underline") }
            if caps { styles.append("AllCaps") }
            let style = styles.isEmpty ? "" : " Style=\"\(styles.joined(separator: "+"))\""
            return "      <Text\(style)>\(escape(run.text))</Text>\n"
        }.joined()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Final Draft's default element formats, set in Courier Prime 12pt.
    static let elementSettings: String = {
        let rows: [(type: String, caps: Bool, align: String, left: String, right: String, before: Int, next: String)] = [
            ("General", false, "Left", "1.50", "7.50", 0, "General"),
            ("Scene Heading", true, "Left", "1.50", "7.50", 12, "Action"),
            ("Action", false, "Left", "1.50", "7.50", 12, "Action"),
            ("Character", true, "Left", "3.50", "7.25", 12, "Dialogue"),
            ("Parenthetical", false, "Left", "3.00", "5.50", 0, "Dialogue"),
            ("Dialogue", false, "Left", "2.50", "6.00", 0, "Action"),
            ("Transition", true, "Right", "5.50", "7.50", 12, "Scene Heading"),
            ("Shot", true, "Left", "1.50", "7.50", 12, "Action")
        ]
        return rows.map { row in
            """
              <ElementSettings Type="\(row.type)">
                <FontSpec AdornmentStyle="0" Background="#FFFFFFFFFFFF" Color="#000000000000" Font="Courier Prime" RevisionID="0" Size="12" Style="\(row.caps ? "AllCaps" : "")"/>
                <ParagraphSpec Alignment="\(row.align)" FirstIndent="0.00" Leading="Regular" LeftIndent="\(row.left)" RightIndent="\(row.right)" SpaceBefore="\(row.before)" Spacing="1" StartsNewPage="No"/>
                <Behavior PaginateAs="\(row.type)" ReturnKey="\(row.next)" Shortcut=""/>
              </ElementSettings>

            """
        }.joined()
    }()

    private static func titlePageXML(_ page: ScreenplayTitlePage) -> String {
        var lines: [(String, String)] = []   // (alignment, text)
        for _ in 0..<15 { lines.append(("Center", "")) }
        lines += page.title.components(separatedBy: "\n").map { ("Center", $0) }
        if !page.credit.isEmpty || !page.authors.isEmpty {
            lines += [("Center", ""), ("Center", page.credit), ("Center", "")]
            lines += page.authors.map { ("Center", $0) }
        }
        if !page.source.isEmpty {
            lines += [("Center", ""), ("Center", "")] + page.source.map { ("Center", $0) }
        }
        let foot = page.contact.map { ("Left", $0) } + (page.draft.isEmpty ? [] : [("Left", "")] + page.draft.map { ("Right", $0) })
        while lines.count + foot.count < 52 { lines.append(("Left", "")) }
        lines += foot
        var out = "\n  <TitlePage>\n    <Content>\n"
        for (align, text) in lines {
            out += "      <Paragraph Alignment=\"\(align)\" FirstIndent=\"0.00\" Leading=\"Regular\" LeftIndent=\"1.00\" RightIndent=\"7.50\" SpaceBefore=\"0\" Spacing=\"1\" StartsNewPage=\"No\">\n"
            // Emphasis as Final Draft's styles, never Fountain's stars and underscores.
            out += texts(text, caps: false) + "      </Paragraph>\n"
        }
        return out + "    </Content>\n  </TitlePage>\n"
    }

    // MARK: - Reading

    struct Paragraph: Equatable {
        var type: String
        var runs: [Fountain.Run] = []
        var centered = false
        var startsNewPage = false
        var number: String?
        /// The second speaker of dual dialogue starts here.
        var dualStart = false
        var alignment = "Left"
        /// Closes up to the paragraph before (a second line of the same action).
        var tight = false

        var text: String { runs.map(\.text).joined() }
    }

    struct Script: Equatable {
        var paragraphs: [Paragraph] = []
        var titlePage: [Paragraph] = []
    }

    /// Reads an `.fdx` file's script and title page. Nil if it isn't Final Draft's XML.
    static func read(_ data: Data) -> Script? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawRoot else { return nil }
        return reader.script
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var script = Script()
        var sawRoot = false
        private var stack: [String] = []
        private var paragraph: Paragraph?
        private var paragraphDepth = 0
        private var inTitle = false
        private var text: String?
        private var textStyle: (Fountain.Style, Bool) = ([], false)
        private var dualDepth = 0
        private var charactersInDual = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            defer { stack.append(name) }
            if name == "FinalDraft" { sawRoot = true }
            let parent = stack.last
            switch name {
            case "TitlePage" where stack == ["FinalDraft"]:
                inTitle = true
            case "DualDialogue":
                dualDepth = stack.count
                charactersInDual = 0
            case "Paragraph":
                // Only the script's own paragraphs (and the title page's): never those
                // inside notes or other extras.
                let script = stack == ["FinalDraft", "Content"] || (dualDepth > 0 && parent == "DualDialogue")
                let title = inTitle && stack == ["FinalDraft", "TitlePage", "Content"]
                guard script || title, attributes["Type"] != nil || title else { return }
                var p = Paragraph(type: attributes["Type"] ?? "Action")
                p.alignment = attributes["Alignment"] ?? "Left"
                p.centered = p.alignment == "Center"
                p.startsNewPage = attributes["StartsNewPage"] == "Yes"
                p.number = attributes["Number"].flatMap { $0.isEmpty ? nil : $0 }
                p.tight = attributes["SpaceBefore"] == "0"
                if dualDepth > 0, p.type == "Character" {
                    charactersInDual += 1
                    p.dualStart = charactersInDual == 2
                }
                paragraph = p
                paragraphDepth = stack.count
            case "Text" where paragraph != nil && stack.count == paragraphDepth + 1:
                var style: Fountain.Style = []
                let tokens = (attributes["Style"] ?? "").split(separator: "+").map { $0.lowercased() }
                if tokens.contains("bold") { style.insert(.bold) }
                if tokens.contains("italic") { style.insert(.italic) }
                if tokens.contains("underline") { style.insert(.underline) }
                textStyle = (style, tokens.contains("allcaps"))
                text = ""
            default:
                break
            }
        }

        static let wrap = "\u{1}"

        /// Wraps become a space, or nothing where a space is already beside them.
        static func unwrap(_ runs: [Fountain.Run]) -> [Fountain.Run] {
            guard runs.contains(where: { $0.text.contains(wrap) }) else { return runs }
            var out = runs
            for i in out.indices {
                var chars = Array(out[i].text)
                var j = 0
                while j < chars.count {
                    guard String(chars[j]) == wrap else { j += 1; continue }
                    let before: Character? = j > 0 ? chars[j - 1] : (i > 0 ? out[i - 1].text.last : nil)
                    let after: Character? = j + 1 < chars.count ? chars[j + 1] : (i + 1 < out.count ? out[i + 1].text.first : nil)
                    if before == nil || after == nil || before == " " || after == " " || String(after!) == wrap {
                        chars.remove(at: j)
                    } else {
                        chars[j] = " "
                        j += 1
                    }
                }
                out[i].text = String(chars)
            }
            return out.filter { !$0.text.isEmpty }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if text != nil { text! += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
            switch name {
            case "Text":
                if let t = text, paragraph != nil, stack.count == paragraphDepth + 1 {
                    // A line break inside a paragraph is a wrap left by a PDF imported into
                    // Final Draft, not a break the writer typed: marked here, made a space (or
                    // nothing, beside a space) when the paragraph ends.
                    var value = textStyle.1 ? t.uppercased() : t
                    value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                        .replacingOccurrences(of: "\n", with: Reader.wrap)
                    if !value.isEmpty { paragraph!.runs.append(Fountain.Run(text: value, style: textStyle.0)) }
                }
                text = nil
            case "Paragraph" where paragraph != nil && stack.count == paragraphDepth:
                paragraph!.runs = Self.unwrap(paragraph!.runs)
                if inTitle { script.titlePage.append(paragraph!) } else { script.paragraphs.append(paragraph!) }
                paragraph = nil
            case "DualDialogue":
                dualDepth = 0
            case "TitlePage":
                inTitle = false
            default:
                break
            }
        }
    }

    // MARK: - Into Fountain

    /// A Final Draft script as a Fountain file, title page first.
    static func fountain(_ script: Script) -> String {
        var out = Fountain.titlePageText(titleKeys(script.titlePage))
        if !out.isEmpty { out += "\n" }
        var previous = ""
        var body = ""

        func emit(_ line: String, blankBefore: Bool) {
            if blankBefore, !body.isEmpty, !body.hasSuffix("\n\n") { body += "\n" }
            body += line + "\n"
        }

        for (index, p) in script.paragraphs.enumerated() {
            let next = index + 1 < script.paragraphs.count ? script.paragraphs[index + 1] : nil
            if p.startsNewPage, !body.isEmpty {
                emit("===", blankBefore: true)
            }
            let raw = p.text.trimmingCharacters(in: .whitespaces)
            let text = markup(p.runs)
            switch p.type {
            case "Scene Heading":
                guard !raw.isEmpty else { continue }
                // Forced with "." unless the line as written starts INT./EXT.: a heading set in
                // bold ("**EXT. FARM - DAY**") starts with its stars (owner's script, 2026-11-14).
                var line = (matchesHeading(text) ? "" : ".") + text.uppercased()
                if let number = p.number { line += " #\(number)#" }
                emit(line, blankBefore: true)
            case "Character":
                guard !raw.isEmpty else { continue }
                // Final Draft sets names in capitals whatever was typed ("AlBERT", "Allie").
                var name = text.uppercased()
                if !Fountain.isCharacterName(raw.uppercased()) { name = "@" + name }
                if p.dualStart { name += " ^" }
                emit(name, blankBefore: true)
            case "Parenthetical":
                guard !raw.isEmpty else { continue }
                var t = text
                if !raw.hasPrefix("(") { t = "(" + t }
                if !raw.hasSuffix(")") { t += ")" }
                emit(t, blankBefore: false)
            case "Dialogue":
                guard !raw.isEmpty else { continue }
                // A line that would read as a parenthetical stays dialogue only if it isn't one.
                emit(text, blankBefore: previous != "Character" && previous != "Parenthetical" && previous != "Dialogue")
            case "Transition":
                guard !raw.isEmpty else { continue }
                let t = text.uppercased()
                emit(t.hasSuffix("TO:") ? t : "> " + t, blankBefore: true)
            case "Lyrics":
                guard !raw.isEmpty else { continue }
                emit("~" + text, blankBefore: previous != "Lyrics")
            default:
                // Action, General, Shot and anything else print as action.
                guard !raw.isEmpty else { continue }
                if p.centered {
                    emit("> " + text + " <", blankBefore: true)
                } else {
                    // A second line of the same paragraph closes up; a first line that a second
                    // follows mustn't read as a speaker's name.
                    let tight = p.type == previous && (p.tight || previous == "General")
                    let followed = next.map { $0.type == p.type && $0.tight && !$0.startsNewPage } ?? false
                    emit(forcedAction(text, raw: raw, type: p.type, followed: followed && !tight), blankBefore: !tight)
                }
            }
            previous = p.type
        }
        return out + body
    }

    private static func matchesHeading(_ s: String) -> Bool { Fountain.isHeading(s) }

    /// Action that Fountain would read as something else gets `!` in front.
    private static func forcedAction(_ text: String, raw: String, type: String, followed: Bool) -> String {
        let first = raw.components(separatedBy: "\n").first ?? raw
        let symbols: [Character] = [".", "@", "!", ">", "~", "=", "#"]
        var force = matchesHeading(first) || symbols.contains(where: { first.hasPrefix(String($0)) })
            || (first == first.uppercased() && first.hasSuffix("TO:"))
            || Fountain.isPageBreak(first) || first.hasPrefix("[[") || first.hasPrefix("/*")
        // A Shot reads as a capital line: keep it as action, not a speaker.
        if type == "Shot" || raw.contains("\n") || followed { force = force || Fountain.isCharacterName(first) }
        return force ? "!" + text : text
    }

    /// Styled runs as Fountain emphasis, symbols in the text escaped.
    static func markup(_ runs: [Fountain.Run]) -> String {
        var out = ""
        for run in runs {
            var t = ""
            for c in run.text {
                if c == "*" || c == "_" || c == "\\" { t.append("\\") }
                t.append(c)
            }
            guard !run.style.isEmpty, t.contains(where: { !$0.isWhitespace }) else {
                out += t
                continue
            }
            // Emphasis hugs its words: spaces stay outside the symbols.
            let leading = String(t.prefix { $0 == " " })
            let trailing = String(t.reversed().prefix { $0 == " " })
            var core = String(t.dropFirst(leading.count).dropLast(trailing.count))
            var open = "", close = ""
            if run.style.contains(.underline) { open += "_"; close = "_" + close }
            if run.style.contains(.bold) && run.style.contains(.italic) {
                open += "***"; close = "***" + close
            } else if run.style.contains(.bold) {
                open += "**"; close = "**" + close
            } else if run.style.contains(.italic) {
                open += "*"; close = "*" + close
            }
            core = open + core + close
            out += leading + core + trailing
        }
        return out
    }

    /// Final Draft's title page as Fountain keys: the first centred line is the title, a line
    /// like "Written by" the credit, the centred lines after it the authors; lines at the foot
    /// on the left the contact, on the right the draft.
    static func titleKeys(_ paragraphs: [Paragraph]) -> [(key: String, lines: [String])] {
        let lines = paragraphs.map { (text: $0.text.trimmingCharacters(in: .whitespaces), align: $0.alignment) }
        let filled = lines.filter { !$0.text.isEmpty }
        guard !filled.isEmpty else { return [] }
        var title: [String] = [], credit: [String] = [], authors: [String] = [], contact: [String] = [], draft: [String] = []
        var stage = 0   // 0 title, 1 after credit
        for line in filled {
            if line.align == "Center" {
                let lower = line.text.lowercased()
                if stage == 0, title.isEmpty {
                    title.append(line.text)
                } else if stage == 0, lower == "by" || lower.hasPrefix("written by") || lower.hasPrefix("screenplay by")
                            || lower.hasPrefix("story by") || lower.hasPrefix("teleplay by") {
                    credit.append(line.text)
                    stage = 1
                } else if stage == 0 {
                    title.append(line.text)
                } else {
                    authors.append(line.text)
                }
            } else if line.align == "Right" {
                draft.append(line.text)
            } else {
                contact.append(line.text)
            }
        }
        // Final Draft's own placeholder: the story's name stands instead.
        if title.count == 1, title[0].lowercased() == "untitled" { title = [] }
        return [("Title", title), ("Credit", credit), ("Author", authors), ("Draft date", draft), ("Contact", contact)]
            .filter { !$0.1.isEmpty }
    }
}
