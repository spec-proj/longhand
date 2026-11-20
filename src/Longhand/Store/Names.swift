import Foundation

/// Finding and changing a name in text (issue #24): a character's, a place's, anything the
/// story tracks. Only whole words match (Mara is not in Marathon), in the case it was tracked
/// in or in capitals as a screenplay's character cues set it (MARA). Mara's is Mara; "mara"
/// lower case is not, so a name that is also a word (Mark, Rose) leaves the word alone.
enum NameMatch {
    /// One place a name is found, and what it becomes.
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        var delta: Int { replacement.utf16.count - range.length }
    }

    /// A word character: a letter, a digit, or an underscore.
    private static let word = "\\p{L}\\p{N}_"

    static func regex(for name: String) -> NSRegularExpression? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Each word on its own, with any run of spaces between: "Mara  Voss" is "Mara Voss".
        func pattern(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
        }
        let forms = Array(Set([trimmed, trimmed.uppercased()]))
        let any = forms.map(pattern).joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?<![\(word)])(?:\(any))(?![\(word)])")
    }

    static func ranges(of name: String, in text: String) -> [NSRange] {
        guard let regex = regex(for: name) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// The edits that change `old` to `new` in `text`, in order: a match in capitals becomes
    /// the new name in capitals.
    static func edits(replacing old: String, with new: String, in text: String) -> [Edit] {
        let oldName = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldName != newName, !newName.isEmpty else { return [] }
        let ns = text as NSString
        return ranges(of: oldName, in: text).map { range in
            let found = ns.substring(with: range)
            let shouted = found != oldName && found == oldName.uppercased()
            return Edit(range: range, replacement: shouted ? newName.uppercased() : newName)
        }
    }

    static func apply(_ edits: [Edit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return result as String
    }

    static func replacing(_ old: String, with new: String, in text: String) -> String {
        apply(edits(replacing: old, with: new, in: text), to: text)
    }

    /// Where a position in the old text falls in the new. A position inside a replaced name
    /// goes to its start, or to its end when `end` is set (the end of a passage).
    static func map(_ index: Int, through edits: [Edit], end: Bool = false) -> Int {
        var shift = 0
        for edit in edits {
            if NSMaxRange(edit.range) <= index {
                shift += edit.delta
            } else if edit.range.location < index {
                return edit.range.location + shift + (end ? edit.replacement.utf16.count : 0)
            } else {
                break
            }
        }
        return index + shift
    }

    /// How many places in `text` (and in how many of `texts`) hold the name.
    static func count(of name: String, in texts: [String]) -> (places: Int, texts: Int) {
        guard let regex = regex(for: name) else { return (0, 0) }
        var places = 0, within = 0
        for text in texts {
            let found = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            places += found
            if found > 0 { within += 1 }
        }
        return (places, within)
    }

    /// The same for a character with several names: a place holding two of them (Mara inside
    /// Mara Voss) counts once.
    static func count(ofAny names: [String], in texts: [String]) -> (places: Int, texts: Int) {
        let regexes = names.compactMap(regex(for:))
        var places = 0, within = 0
        for text in texts {
            let whole = NSRange(location: 0, length: (text as NSString).length)
            let found = regexes.flatMap { $0.matches(in: text, range: whole).map(\.range) }.sorted { $0.location < $1.location }
            var reach = -1, here = 0
            for range in found where range.location >= reach {
                here += 1
                reach = NSMaxRange(range)
            }
            places += here
            if here > 0 { within += 1 }
        }
        return (places, within)
    }

    /// The name's place under a character index, if a tracked name sits there: looks only a
    /// little either side, so hovering is cheap on a long page.
    static func range(at index: Int, in text: NSString, among regexes: [NSRegularExpression]) -> NSRange? {
        guard index >= 0, index <= text.length else { return nil }
        let start = max(0, index - 60)
        let window = NSRange(location: start, length: min(text.length, index + 60) - start)
        let piece = text.substring(with: window)
        for regex in regexes {
            for match in regex.matches(in: piece, range: NSRange(location: 0, length: window.length)) {
                let range = NSRange(location: match.range.location + start, length: match.range.length)
                if NSLocationInRange(index, range) { return range }
            }
        }
        return nil
    }
}
