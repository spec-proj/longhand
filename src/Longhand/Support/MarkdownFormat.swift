import AppKit

/// Format › Bold (⌘B) and Italic (⌘I): Markdown symbols put around the selection, or around
/// the word at the caret, or taken away if they are already there. Done as typing, so Undo
/// reverses it and the page restyles and saves as usual.
@MainActor
enum MarkdownFormat {
    enum Style {
        case bold, italic
        var marker: String { self == .bold ? "**" : "*" }
    }

    static func toggle(_ style: Style, in textView: NSTextView) {
        let string = textView.string as NSString
        let marker = style.marker
        let width = (marker as NSString).length
        var range = trimmed(textView.selectedRange(), in: string)
        if range.length == 0 { range = word(at: range.location, in: string) }

        // Nothing to wrap: put the pair down and the caret between.
        if range.length == 0 {
            replace(textView, range, with: marker + marker, select: NSRange(location: range.location + width, length: 0))
            return
        }

        let before = stars(endingAt: range.location, in: string)
        let after = stars(startingAt: NSMaxRange(range), in: string)
        let wrapped = style == .bold ? before >= 2 && after >= 2 : before % 2 == 1 && after % 2 == 1
        if wrapped {
            let outer = NSRange(location: range.location - width, length: range.length + 2 * width)
            replace(textView, outer, with: string.substring(with: range),
                    select: NSRange(location: outer.location, length: range.length))
            return
        }

        // The selection itself carries the symbols: take them off.
        let inner = string.substring(with: range)
        if inner.hasPrefix(marker), inner.hasSuffix(marker), range.length > 2 * width,
           style == .bold || !inner.hasPrefix("**") || inner.hasPrefix("***") {
            let text = (inner as NSString).substring(with: NSRange(location: width, length: range.length - 2 * width))
            replace(textView, range, with: text, select: NSRange(location: range.location, length: (text as NSString).length))
            return
        }

        replace(textView, range, with: marker + inner + marker,
                select: NSRange(location: range.location + width, length: range.length))
    }

    private static let block = try! NSRegularExpression(pattern: #"^([ \t]*)(?:([-*+])|(\d+)\.|(>))([ \t]+|$)"#)
    private static let rule = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)

    /// Return at the end of a list item or a quoted line starts the next one with the same
    /// symbol (a numbered item with the next number); Return on an item left empty takes the
    /// symbol away instead, ending the list. False when the line is neither, so Return
    /// does what it always does.
    static func continueBlock(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, !textView.hasMarkedText() else { return false }
        let string = textView.string as NSString
        var line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        while line.length > 0, [0x0A, 0x0D].contains(Int(string.character(at: NSMaxRange(line) - 1))) { line.length -= 1 }
        // Only from the end of the line: Return in the middle splits it as usual.
        guard selection.location == NSMaxRange(line), line.length > 0 else { return false }
        let text = string.substring(with: line)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        guard rule.firstMatch(in: text, range: whole) == nil,
              let match = block.firstMatch(in: text, range: whole) else { return false }
        func part(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : (text as NSString).substring(with: range)
        }
        let symbol: String
        if let bullet = part(2) {
            symbol = bullet
        } else if let number = part(3), let value = Int(number) {
            // "1984. Winston…" is a sentence, not item 1,984 of a list.
            guard number.count <= 3 else { return false }
            symbol = "\(value + 1)."
        } else {
            symbol = ">"
        }
        if match.range.length == whole.length {
            // A symbol alone on its line ends a list only if a list is under way: a lone
            // "-" or "12." with nothing like it above is just what was typed.
            guard line.location > 0 else { return false }
            var above = string.lineRange(for: NSRange(location: line.location - 1, length: 0))
            while above.length > 0, [0x0A, 0x0D].contains(Int(string.character(at: NSMaxRange(above) - 1))) { above.length -= 1 }
            let previous = string.substring(with: above)
            guard block.firstMatch(in: previous, range: NSRange(location: 0, length: (previous as NSString).length)) != nil else { return false }
        }
        textView.breakUndoCoalescing()
        if match.range.length == whole.length {
            // Nothing after the symbol: the list (or quote) ends here.
            guard textView.shouldChangeText(in: line, replacementString: "") else { return true }
            textView.insertText("", replacementRange: line)
        } else {
            textView.insertText("\n" + (part(1) ?? "") + symbol + " ", replacementRange: selection)
        }
        textView.breakUndoCoalescing()
        return true
    }

    private static func replace(_ textView: NSTextView, _ range: NSRange, with text: String, select: NSRange) {
        textView.breakUndoCoalescing()
        textView.insertText(text, replacementRange: range)
        textView.breakUndoCoalescing()
        if NSMaxRange(select) <= (textView.string as NSString).length { textView.setSelectedRange(select) }
    }

    /// The selection without spaces or line ends at either end: "**word **" isn't bold.
    private static func trimmed(_ range: NSRange, in string: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        let space = CharacterSet.whitespacesAndNewlines
        while start < end, let s = UnicodeScalar(string.character(at: start)), space.contains(s) { start += 1 }
        while end > start, let s = UnicodeScalar(string.character(at: end - 1)), space.contains(s) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The word the caret is in or touching, if any.
    private static func word(at location: Int, in string: NSString) -> NSRange {
        let letters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-"))
        func isLetter(_ index: Int) -> Bool {
            guard index >= 0, index < string.length, let s = UnicodeScalar(string.character(at: index)) else { return false }
            return letters.contains(s)
        }
        var start = location, end = location
        while isLetter(start - 1) { start -= 1 }
        while isLetter(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func stars(endingAt location: Int, in string: NSString) -> Int {
        var count = 0, index = location - 1
        while index >= 0, string.character(at: index) == 0x2A { count += 1; index -= 1 }
        return count
    }

    private static func stars(startingAt location: Int, in string: NSString) -> Int {
        var count = 0, index = location
        while index < string.length, string.character(at: index) == 0x2A { count += 1; index += 1 }
        return count
    }
}
