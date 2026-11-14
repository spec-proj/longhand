import AppKit

/// Focus and typewriter scrolling, for both the scene editor and the chapter page (View menu).
///
/// - **Focus** dims everything but the sentence or paragraph holding the caret. The dimming is
///   a shade laid over the page (`FocusShade`): it changes how the words look, never the
///   text, so nothing about saving, undo or styling sees it.
/// - **Typewriter scrolling** keeps the caret's line in the middle of the window. The page
///   gets half a window of space above and below, so the first and last lines can sit there
///   too. Typing and the arrow keys move the page; clicking and dragging never do.
@MainActor
final class WritingModes {
    enum Unit: String, CaseIterable, Identifiable {
        case line, sentence, paragraph
        var id: String { rawValue }
        var title: String {
            switch self {
            case .line: return "Line"
            case .sentence: return "Sentence"
            case .paragraph: return "Paragraph"
            }
        }
    }

    nonisolated static let focusKey = "focusMode"
    nonisolated static let unitKey = "focusUnit"
    nonisolated static let typewriterKey = "typewriter"

    static var focusOn: Bool { UserDefaults.standard.bool(forKey: focusKey) }
    static var unit: Unit { Unit(rawValue: UserDefaults.standard.string(forKey: unitKey) ?? "") ?? .sentence }
    static var typewriterOn: Bool { UserDefaults.standard.bool(forKey: typewriterKey) }

    private weak var textView: NSTextView?
    private weak var scroll: NSScrollView?
    /// The editor's own space above and below the text, when typewriter scrolling is off.
    private let baseInset: CGFloat
    private var settings: (focus: Bool, unit: Unit, typewriter: Bool)
    private var dimmed = false
    /// Focus: the shade over everything but the lines being written.
    private var shade: FocusShade?
    /// The text left bright last time, moved along with edits since, so each keystroke only
    /// repaints what changed. Nil when the whole page must be painted again.
    private var kept: NSRange?
    /// What edits since the last paint touched (newly typed text may have taken on the
    /// dimming of the letter before it).
    private var edited: NSRange?
    private var observers: [NSObjectProtocol] = []
    /// How far down the page is laid out for real (typewriter scrolling): text above this
    /// needn't be checked again until new text is loaded or the width changes.
    private var laidOutTo = -1
    /// Where edits since the last centring began: from there down to the caret is laid out
    /// again (Return splits the paragraph above the caret).
    private var editedFrom: Int?
    private var retries = 0
    /// Where the page was last sent.
    private var aim: NSPoint?

    init(textView: NSTextView, scroll: NSScrollView) {
        self.textView = textView
        self.scroll = scroll
        baseInset = textView.textContainerInset.height
        settings = (Self.focusOn, Self.unit, Self.typewriterOn)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
        })
        if let storage = textView.textStorage {
            observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] note in
                guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
                let range = storage.editedRange, delta = storage.changeInLength
                MainActor.assumeIsolated { self?.textEdited(range, delta: delta) }
            })
        }
        scroll.contentView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowResized() }
        })
        applyInset()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        shade?.removeFromSuperview()
        shade = nil
    }

    /// Call when the caret moves or the text changes (after restyling), and with `loaded`
    /// when new text was put on the page, so it opens with the caret's line in the middle.
    func update(loaded: Bool = false) {
        if loaded { kept = nil; laidOutTo = -1 }
        // Centre first: it lays out what's above the caret, which can move the lines the
        // focus shade must leave bright.
        recentre(force: loaded, animate: !loaded)
        refocus()
    }

    // MARK: Settings

    private func settingsMayHaveChanged() {
        let now = (Self.focusOn, Self.unit, Self.typewriterOn)
        guard now != settings else { return }
        let typewriterChanged = now.2 != settings.typewriter
        settings = now
        kept = nil
        refocus()
        if typewriterChanged {
            laidOutTo = -1
            applyInset()
            recentre(force: true, animate: true)
        }
    }

    private func windowResized() {
        laidOutTo = -1
        defer { refocus() }
        guard settings.typewriter else { return }
        applyInset()
        recentre(force: true, animate: false)
    }

    private func applyInset() {
        guard let textView, let scroll else { return }
        let height = settings.typewriter
            ? max(baseInset, (scroll.contentView.bounds.height / 2).rounded())
            : baseInset
        if textView.textContainerInset.height != height {
            textView.textContainerInset = NSSize(width: textView.textContainerInset.width, height: height)
        }
    }

    // MARK: Focus

    private func textEdited(_ range: NSRange, delta: Int) {
        editedFrom = min(editedFrom ?? range.location, range.location)
        edited = edited.map { NSUnionRange(Self.shift($0, by: range, delta: delta), range) } ?? range
        guard let old = kept else { return }
        kept = Self.shift(old, by: range, delta: delta)
    }

    /// Where `range` sits after an edit that left `edit` (in the new text), changing the
    /// length by `delta`.
    static func shift(_ range: NSRange, by edit: NSRange, delta: Int) -> NSRange {
        let oldEnd = edit.location + edit.length - delta
        if oldEnd <= range.location {
            return NSRange(location: range.location + delta, length: range.length)
        }
        if edit.location >= NSMaxRange(range) { return range }
        let start = min(range.location, edit.location)
        let end = max(NSMaxRange(range), oldEnd) + delta
        return NSRange(location: start, length: max(0, end - start))
    }

    private func refocus() {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        edited = nil
        guard settings.focus else {
            if dimmed {
                shade?.isHidden = true
                dimmed = false
            }
            kept = nil
            (textView as? HighlightTextView)?.focusBright = nil
            return
        }
        let now = settings.unit == .line
            ? lineRange(for: textView.selectedRange())
            : Self.focusRange(in: textView.string as NSString, selection: textView.selectedRange(), unit: settings.unit)
        kept = now
        dimmed = true
        (textView as? HighlightTextView)?.focusBright = now
        let shade = shadeView()
        shade?.isHidden = false
        // Exactly over the visible page (it was made before the page had a size).
        if let shade, let scroll, shade.frame != scroll.contentView.frame { shade.frame = scroll.contentView.frame }
        // The bright lines, exactly as laid out: everything else is shaded.
        if let page = textView as? HighlightTextView, NSMaxRange(now) <= length {
            shade?.bright = now.length > 0 ? page.lineRects(of: now).map { $0.insetBy(dx: -2, dy: 0) } : []
            // The caret's cut-out follows it, here and once macOS has moved its caret view.
            shade?.arrange()
            page.onCaretMoved = { [weak shade] in shade?.arrange() }
        }
    }

    /// The shade lies over the page, not scrolling with it, and is drawn afresh as the page
    /// scrolls. Made the first time Focus is on.
    private func shadeView() -> FocusShade? {
        if let shade { return shade }
        guard let textView, let scroll else { return nil }
        let made = FocusShade(frame: scroll.contentView.frame)
        made.clipsToBounds = true
        made.page = textView
        made.autoresizingMask = [.width, .height]
        scroll.addFloatingSubview(made, for: .vertical)
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: scroll.contentView, queue: .main) { [weak made] _ in
            MainActor.assumeIsolated { made?.arrange() }
        })
        shade = made
        return made
    }

    /// Focus on a line: the lines, as wrapped on the page, that the selection touches. On a
    /// blank line, the last line above it (as with sentences and paragraphs).
    private func lineRange(for selection: NSRange) -> NSRange {
        guard let textView, let page = textView as? HighlightTextView,
              let textLayoutManager = textView.textLayoutManager,
              let content = textLayoutManager.textContentManager else { return selection }
        let string = textView.string as NSString
        let length = string.length
        var start = min(selection.location, length)
        if selection.length == 0 {
            // A blank line borrows the end of the text above, as `focusRange` does.
            let kept = Self.focusRange(in: string, selection: selection, unit: .sentence)
            if kept.length > 0, kept.location > start || NSMaxRange(kept) < start { start = max(kept.location, NSMaxRange(kept) - 1) }
        }
        let end = selection.length > 0 ? max(start, NSMaxRange(selection) - 1) : start
        func line(at location: Int) -> NSRange? {
            guard let here = page.textRange(for: NSRange(location: min(location, length), length: 0)) else { return nil }
            textLayoutManager.ensureLayout(for: here)
            guard let fragment = textLayoutManager.textLayoutFragment(for: here.location) else { return nil }
            let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let lines = fragment.textLineFragments
            for (index, lineFragment) in lines.enumerated() {
                let range = NSRange(location: paragraphStart + lineFragment.characterRange.location, length: lineFragment.characterRange.length)
                if location < NSMaxRange(range) || index == lines.count - 1 { return range }
            }
            return nil
        }
        guard let first = line(at: start) else { return Self.focusRange(in: string, selection: selection, unit: .sentence) }
        var union = NSUnionRange(first, line(at: end) ?? first)
        // Without the paragraph's newline.
        while union.length > 0, [0x0A, 0x0D].contains(string.character(at: NSMaxRange(union) - 1)) { union.length -= 1 }
        return union
    }

    /// Words a full stop doesn't end a sentence after ("Mr. Utterson", "Dr. Jekyll"). The
    /// system's sentence finder stops at them.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "messrs", "dr", "st", "mt", "jr", "sr", "prof", "rev", "revd", "capt",
        "col", "gen", "lt", "sgt", "maj", "esq", "hon", "mme", "mlle", "no", "vs", "viz", "cf",
        "e.g", "i.e", "etc", "co", "inc", "ltd", "fig", "vol", "ch", "p", "pp",
    ]

    /// The text left bright: the sentences or paragraphs the selection touches. On a blank
    /// line (between paragraphs, or a new one not yet typed) the paragraph or sentence just
    /// above stays bright, so moving through the page with the arrow keys never darkens all of
    /// it at once.
    static func focusRange(in string: NSString, selection: NSRange, unit: Unit) -> NSRange {
        let length = string.length
        var start = min(selection.location, length)
        var end = min(NSMaxRange(selection), length)
        if selection.length == 0 {
            let line = string.lineRange(for: NSRange(location: start, length: 0))
            let text = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                // Back to the end of the nearest line with words on it.
                var probe = line.location
                while probe > 0 {
                    let previous = string.lineRange(for: NSRange(location: probe - 1, length: 0))
                    if !string.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        var last = NSMaxRange(previous)
                        while last > previous.location, [0x0A, 0x0D, 0x20].contains(string.character(at: last - 1)) { last -= 1 }
                        start = max(previous.location, last - 1)
                        end = start
                        break
                    }
                    probe = previous.location
                }
            }
        }

        func paragraph(at location: Int) -> NSRange {
            var line = string.lineRange(for: NSRange(location: location, length: 0))
            while line.length > 0 {
                let unit = string.character(at: NSMaxRange(line) - 1)
                guard unit == 0x0A || unit == 0x0D else { break }
                line.length -= 1
            }
            return line
        }

        func sentence(at location: Int) -> NSRange {
            let line = paragraph(at: location)
            guard line.length > 0 else { return NSRange(location: location, length: 0) }
            // The system's sentences, joined again where one ended at an abbreviation.
            var sentences: [(range: NSRange, enclosing: NSRange)] = []
            string.enumerateSubstrings(in: line, options: [.bySentences, .substringNotRequired]) { _, range, enclosing, _ in
                if let previous = sentences.last, endsWithAbbreviation(string.substring(with: previous.range)) {
                    sentences[sentences.count - 1] = (NSUnionRange(previous.range, range), NSUnionRange(previous.enclosing, enclosing))
                } else {
                    sentences.append((range, enclosing))
                }
            }
            // The caret belongs to a sentence from its first letter to the space after it.
            let found = sentences.first { location >= $0.enclosing.location && location < NSMaxRange($0.enclosing) }
            return found?.range ?? sentences.last?.range ?? line
        }

        func endsWithAbbreviation(_ sentence: String) -> Bool {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix(".") else { return false }
            let word = trimmed.dropLast().split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "“" || $0 == "\"" }).last.map(String.init) ?? ""
            // An initial ("J. Smith") or a known abbreviation.
            if word.count == 1, word.first?.isUppercase == true { return true }
            return abbreviations.contains(word.lowercased())
        }

        let pick = unit == .sentence ? sentence(at:) : paragraph(at:)
        let first = pick(start)
        // A selection ending at the start of a line (triple-click, ⇧↓) stops before that line.
        let last = end > start ? pick(end - 1) : first
        return NSUnionRange(first, last)
    }

    // MARK: Typewriter

    private func recentre(force: Bool, animate: Bool) {
        guard settings.typewriter, let textView, let scroll else { return }
        // Never move the page under the pointer while clicking or dragging out a selection in
        // it. A choice from the menu bar (Paste, Undo) is a click elsewhere, and does move it.
        if !force, NSEvent.pressedMouseButtons != 0 { return }
        if !force, (textView as? HighlightTextView)?.holdsScroll == true { return }
        if !force, let event = NSApp.currentEvent, event.window === textView.window,
           [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp].contains(event.type) { return }

        let length = (textView.string as NSString).length
        let caret = min(NSMaxRange(textView.selectedRange()), length)
        var line = NSRect.null
        if let textLayoutManager = textView.textLayoutManager {
            guard let page = textView as? HighlightTextView,
                  let here = page.textRange(for: NSRange(location: caret, length: 0)) else { return }
            // Everything above the caret laid out for real: TextKit 2 only estimates the
            // height of text not yet shown, and centring on an estimate put the line up to a
            // screen away once the real layout arrived. Once laid out it stays laid out, so
            // this costs something only the first time.
            // From the top the first time; after that from the edit, or at least the few lines
            // above the caret (restyling after Return reshapes them without editing them).
            let string = textView.string as NSString
            var nearby = string.lineRange(for: NSRange(location: caret, length: 0)).location
            for _ in 0..<3 where nearby > 0 {
                nearby = string.lineRange(for: NSRange(location: nearby - 1, length: 0)).location
            }
            let from: Int? = caret > laidOutTo ? 0 : min(editedFrom ?? nearby, nearby)
            editedFrom = nil
            if let from, let start = page.textRange(for: NSRange(location: from, length: 0))?.location,
               let upTo = NSTextRange(location: start, end: here.location) {
                textLayoutManager.ensureLayout(for: upTo)
                laidOutTo = max(laidOutTo, caret)
                // The page's own height follows the layout a moment later; bring it up to
                // date now, or centring is held back by the old, estimated height.
                textLayoutManager.textViewportLayoutController.layoutViewport()
            }
            textLayoutManager.ensureLayout(for: here)
            textLayoutManager.enumerateTextSegments(in: here, type: .standard, options: []) { _, frame, _, _ in
                line = frame
                return false
            }
            guard !line.isNull else { return }
        } else if let layout = textView.layoutManager {
            layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(caret + 1, length)))
            if caret == length, layout.extraLineFragmentTextContainer != nil {
                line = layout.extraLineFragmentRect
            } else if length > 0 {
                let glyph = layout.glyphIndexForCharacter(at: min(caret, length - 1))
                line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                return
            }
        } else {
            return
        }

        let clip = scroll.contentView
        // Not sized or not in the window yet (the page is still being built): try again on the
        // next pass, a few times.
        guard clip.bounds.height > 0, textView.window != nil else {
            if retries < 10 {
                retries += 1
                DispatchQueue.main.async { [weak self] in self?.recentre(force: true, animate: false) }
            }
            return
        }
        retries = 0
        let middle = line.midY + textView.textContainerOrigin.y
        let target = NSPoint(x: clip.bounds.origin.x, y: max(0, (middle - clip.bounds.height / 2).rounded()))
        // The page's height is partly an estimate (TextKit 2 hasn't laid out what's below);
        // never let it hold the line short of the middle. Half a window of space below the
        // text means the real height always has room.
        let needed = target.y + clip.bounds.height
        if textView.frame.height < needed {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: needed))
        }
        let distance = abs(target.y - clip.bounds.origin.y)
        guard distance >= 1 else { return }

        aim = target
        if animate, distance > line.height * 2 {
            // A jump (after a click, or a paste): glide rather than cut. If the glide was cut
            // short (it sometimes is), finish the move when it ends, unless a newer one began.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { [weak self, weak scroll] in
                MainActor.assumeIsolated {
                    guard let self, let scroll, self.aim == target, scroll.contentView.bounds.origin != target else { return }
                    scroll.contentView.setBoundsOrigin(target)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            })
        } else {
            // Through the animator with no duration, so a glide still under way stops here
            // instead of finishing at its older target.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clip.animator().setBoundsOrigin(target)
            }
        }
        scroll.reflectScrolledClipView(clip)
    }
}

/// Focus, drawn by Longhand itself: the page's own colour laid over everything but the bright
/// lines, three-quarters opaque, so dimmed words read as ink at about 28%. (TextKit 2's
/// rendering attributes did the same job, but the page didn't redraw them as the caret moved:
/// the dimming showed only once a selection redrew the lines.) Clicks pass through.
///
/// The shade is a handful of plain rectangles (above, below and either side of the bright
/// lines) composited by the graphics chip: nothing is painted, so a keystroke only moves them.
final class FocusShade: NSView {
    weak var page: NSTextView?
    /// The bright lines, in the page's coordinates.
    var bright: [NSRect] = [] {
        didSet { if bright != oldValue { arrange() } }
    }
    private var pieces: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { arrange() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); arrange() }

    /// Lays the rectangles out again (after the bright lines change, or the page scrolls).
    func arrange() {
        guard let page, let layer else { return }
        var holes = bright.map { convert($0, from: page) }
        // The caret stays fully visible, even on a blank line between the bright ones.
        if let caret = (page as? HighlightTextView)?.caretFrame {
            holes.append(convert(caret, from: page).insetBy(dx: -2, dy: 0))
        }
        holes = holes.filter { $0.maxY > bounds.minY && $0.minY < bounds.maxY }.sorted { $0.minY < $1.minY }

        var rects: [NSRect] = []
        var y = bounds.minY
        for hole in holes {
            if hole.minY > y { rects.append(NSRect(x: bounds.minX, y: y, width: bounds.width, height: hole.minY - y)) }
            let top = max(y, hole.minY), height = hole.maxY - top
            if height > 0 {
                rects.append(NSRect(x: bounds.minX, y: top, width: max(0, hole.minX - bounds.minX), height: height))
                rects.append(NSRect(x: hole.maxX, y: top, width: max(0, bounds.maxX - hole.maxX), height: height))
            }
            y = max(y, hole.maxY)
        }
        if y < bounds.maxY { rects.append(NSRect(x: bounds.minX, y: y, width: bounds.width, height: bounds.maxY - y)) }
        rects = rects.filter { $0.width > 0 && $0.height > 0 }

        var colour = CGColor(gray: 1, alpha: 0.72)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colour = (PaperTheme.paper.usingColorSpace(.sRGB) ?? PaperTheme.paper).withAlphaComponent(0.72).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while pieces.count < rects.count {
            let piece = CALayer()
            layer.addSublayer(piece)
            pieces.append(piece)
        }
        for (index, piece) in pieces.enumerated() {
            if index < rects.count {
                piece.isHidden = false
                piece.frame = rects[index]
                piece.backgroundColor = colour
            } else {
                piece.isHidden = true
            }
        }
        CATransaction.commit()
    }
}
