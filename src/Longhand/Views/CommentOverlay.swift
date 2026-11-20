import AppKit
import Combine

/// Draws comment highlights on a page. Shared by the scene editor and the chapter page; each
/// says where a comment's passage falls on its page.
@MainActor
final class CommentOverlay {
    private weak var textView: HighlightTextView?
    private let margin: MarginStore
    /// What was last painted; nil forces the next refresh to paint (an empty list is a real
    /// state: no highlights, which must still replace those of the scene before).
    private var painted: [String]?
    private var subscriptions: Set<AnyCancellable> = []

    init(textView: HighlightTextView, margin: MarginStore) {
        self.textView = textView
        self.margin = margin

        // Repaint when comments or focus change.
        margin.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &subscriptions)
    }

    func detach() {
        subscriptions = []
    }

    /// Repaint even if nothing seems to have changed (after the text itself changed).
    func invalidate() {
        painted = nil
        refresh()
    }

    private func visible() -> [(comment: SceneComment, range: NSRange)] {
        guard let textView else { return [] }
        let length = (textView.string as NSString).length
        return margin.comments.compactMap { comment in
            guard !comment.resolved, let range = margin.pageRange(of: comment), NSMaxRange(range) <= length else { return nil }
            return (comment, range)
        }
    }

    func refresh() {
        guard let textView else { return }
        let names = margin.trackedNamesOnPage
        if textView.trackedNames != names { textView.trackedNames = names }
        let shown = visible()
        let signature = shown.map {
            "\($0.comment.id)|\($0.range.location)|\($0.range.length)|\($0.comment.id == margin.focused)"
        }
        if signature != painted {
            painted = signature
            textView.highlights = shown
                .filter { $0.range.length > 0 }
                .map { ($0.range, $0.comment.id == margin.focused ? PaperTheme.highlightFocus : PaperTheme.highlight) }
        }
    }
}

/// A text view that draws comment highlights behind the words, line by line and tight to the
/// text: unlike a background colour attribute, a highlight that wraps never runs into the
/// margin or out to the edge of the column.
final class HighlightTextView: NSTextView {

    /// Pages draw their marks again when Clear Desk or the change bars switch changes.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: PageMarks.changed, object: nil)
        guard window != nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(marksChanged), name: PageMarks.changed, object: nil)
        // Takes the keyboard if the page it replaces had it.
        Panes.pageArrived()
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { Panes.active = .page }
        return took
    }

    @objc private func marksChanged() { needsDisplay = true }

    /// A page on TextKit 2: each paragraph is laid out and drawn on its own, and only what is
    /// on screen is laid out, so typing near the top of a long scene and opening a long chapter
    /// no longer redraw or lay out the whole page. `LONGHAND_TK1=1` makes the old kind.
    static func page() -> HighlightTextView {
        let textKit2 = ProcessInfo.processInfo.environment["LONGHAND_TK1"] != "1"
        let view = HighlightTextView(usingTextLayoutManager: textKit2)
        // Breaks are drawn as asterisks (see `textContentStorage(_:textParagraphWith:)`).
        view.textContentStorage?.delegate = view
        return view
    }

    var highlights: [(range: NSRange, colour: NSColor)] = [] {
        // Only highlights that moved or changed on screen are repainted. Typing above a comment
        // shifts its range on every keystroke, but if it is in another paragraph it stays where
        // it was on the page; repainting it anyway marked most of the page dirty each key.
        didSet {
            let rects = highlights.map { bounds(of: $0.range).insetBy(dx: -4, dy: -4) }
            if rects.count == paintedRects.count, highlights.count == oldValue.count {
                for index in rects.indices where rects[index] != paintedRects[index]
                    || !highlights[index].colour.isEqual(oldValue[index].colour) {
                    setNeedsDisplay(paintedRects[index])
                    setNeedsDisplay(rects[index])
                }
            } else {
                paintedRects.forEach { setNeedsDisplay($0) }
                rects.forEach { setNeedsDisplay($0) }
            }
            paintedRects = rects
        }
    }

    /// Where each highlight was last drawn, in view coordinates.
    private var paintedRects: [NSRect] = []

    // MARK: Change bars

    /// Paragraphs changed since the last version (`ChangeGutter`), drawn as bars in the gutter
    /// left of the text: ochre for edited, green for added, a red notch where text was cut.
    var changeBars: [ChangeBar] = [] {
        didSet {
            guard changeBars != oldValue else { return }
            setNeedsDisplay(NSRect(x: barX - 6, y: 0, width: 20, height: bounds.height))
        }
    }

    var onChangeBarClicked: ((ChangeBar) -> Void)?

    /// Focus: the text left bright (nil when Focus is off). Read by the self-test.
    var focusBright: NSRange?
    /// While set, a caret move doesn't scroll the page (typewriter centring): for caret moves
    /// made for the writer, not by them, such as leaving a passage just commented on.
    var holdsScroll = false

    // MARK: The caret on a blank line

    /// How often the caret was drawn here (the self-test checks the override is used).
    nonisolated(unsafe) static var caretDraws = 0

    /// The blank line between paragraphs is drawn about 5pt tall (book paragraphs, no gap),
    /// and the caret took the line's height: a sliver. A caret shorter than half a line is
    /// drawn at the text's own height, centred on the gap. No text moves.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        Self.caretDraws += 1
        super.drawInsertionPoint(in: fullCaret(rect), color: color, turnedOn: flag)
    }

    /// The caret's area is repainted (to blink it off) as AppKit measured it; a taller caret
    /// needs the taller area repainted too.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.width <= 4 ? fullCaret(rect) : rect, avoidAdditionalLayout: flag)
    }

    /// Newer macOS may draw the caret as its own view rather than through
    /// `drawInsertionPoint`; that view is given the same height.
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        DispatchQueue.main.async { [weak self] in self?.resizeIndicator() }
    }

    private weak var indicator: NSTextInsertionIndicator?
    private var indicatorObserver: NSObjectProtocol?

    private func resizeIndicator() {
        if indicator == nil || indicator?.superview == nil {
            func find(_ view: NSView) -> NSTextInsertionIndicator? {
                if let found = view as? NSTextInsertionIndicator { return found }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            indicator = find(self)
            // macOS sets the caret view's frame again whenever it moves or blinks; follow it.
            if let indicator {
                if let indicatorObserver { NotificationCenter.default.removeObserver(indicatorObserver) }
                indicator.postsFrameChangedNotifications = true
                indicatorObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: indicator, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resizeIndicator() }
                }
            }
        }
        guard let indicator, let host = indicator.superview else { return }
        let frame = host.convert(indicator.frame, to: self)
        let full = fullCaret(frame)
        if full != frame { indicator.frame = host.convert(full, from: self) }
        onCaretMoved?()
    }

    /// Called after the caret view has been placed (Focus moves its cut-out).
    var onCaretMoved: (() -> Void)?

    /// Where the caret is drawn, in this view's coordinates (Focus leaves it unshaded).
    var caretFrame: NSRect? {
        guard let indicator, let host = indicator.superview, !indicator.isHidden else { return nil }
        return host.convert(indicator.frame, to: self)
    }

    private func fullCaret(_ rect: NSRect) -> NSRect {
        let full = (Layout.textSize * 1.25).rounded()
        guard rect.height < full / 2 else { return rect }
        return NSRect(x: rect.minX, y: (rect.midY - full / 2).rounded(), width: rect.width, height: full)
    }

    /// Select All, if the page wants its own (the chapter page selects one scene, then all the
    /// scenes, never the chapter's title). Returns false to select everything as usual.
    var selectAllHandler: (() -> Bool)?

    /// What a selection copies, if not the selected text itself (the chapter page leaves out
    /// the scene numbers it sets between scenes). Nil for the usual copy.
    var copyText: ((NSRange) -> String?)?

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        if let text = copyText?(selectedRange()) {
            pboard.declareTypes([.string], owner: nil)
            return pboard.setString(text, forType: .string)
        }
        return super.writeSelection(to: pboard, types: types)
    }

    override func selectAll(_ sender: Any?) {
        if selectAllHandler?() == true { return }
        super.selectAll(sender)
    }

    /// The bars' left edge: in the gutter, clear of the Markdown symbols that hang in the margin.
    private var barX: CGFloat { textContainerOrigin.x - 14 }

    /// Where a bar is drawn, or nil if its text isn't laid out.
    private func barRect(_ bar: ChangeBar) -> NSRect? {
        let length = (string as NSString).length
        if bar.kind == .removed && bar.range.length == 0 || bar.drawRange.length == 0 {
            let location = bar.range.location
            let y: CGFloat
            if location < length, let line = lineRects(of: NSRange(location: location, length: 1)).first {
                y = line.minY
            } else if length > 0, let line = lineRects(of: NSRange(location: length - 1, length: 1)).last {
                y = line.maxY
            } else {
                return nil
            }
            return NSRect(x: barX - 3, y: y - 1.5, width: 9, height: 3)
        }
        let lines = lineRects(of: bar.drawRange)
        guard var box = lines.first else { return nil }
        for line in lines.dropFirst() { box = box.union(line) }
        let trim = max(0, ((lines.first?.height ?? 0) - Layout.textSize * 1.3) / 2)
        if bar.kind == .removed {
            return NSRect(x: barX - 3, y: box.minY + trim - 1.5, width: 9, height: 3)
        }
        return NSRect(x: barX, y: box.minY + trim, width: 3, height: max(4, box.height - 2 * trim))
    }

    /// The bars whose text lies (at least partly) in a stretch of the view.
    private func bars(in rect: NSRect) -> [(bar: ChangeBar, box: NSRect)] {
        guard !changeBars.isEmpty else { return [] }
        let visible = characterRange(in: rect)
        let first = visible.location, last = NSMaxRange(visible)
        return changeBars.compactMap { bar in
            guard NSMaxRange(bar.range) >= first, bar.range.location <= last, let box = barRect(bar) else { return nil }
            return (bar, box)
        }
    }

    private func drawChangeBars(in rect: NSRect) {
        guard !changeBars.isEmpty, rect.minX <= barX + 10, rect.maxX >= barX - 6 else { return }
        for (bar, box) in bars(in: rect) where box.intersects(rect) {
            let colour: NSColor
            switch bar.kind {
            case .added: colour = PaperTheme.diffAddedMark
            case .changed: colour = PaperTheme.diffChangedMark
            case .removed: colour = PaperTheme.diffRemovedMark
            }
            colour.setFill()
            NSBezierPath(rect: box).fill()
        }
    }

    // MARK: Tracked names (issue #24)

    /// The names the story tracks. One shows a dotted line while the pointer is over it.
    var trackedNames: [String] = [] {
        didSet {
            guard trackedNames != oldValue else { return }
            nameRegexes = trackedNames.compactMap(NameMatch.regex(for:))
            setHoveredName(nil)
        }
    }
    private var nameRegexes: [NSRegularExpression] = []
    private var hoveredName: NSRange?
    private var hoveredIndex = -1
    private var nameTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let nameTracking { removeTrackingArea(nameTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        nameTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !nameRegexes.isEmpty, let window else { return }
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        let index = characterIndex(for: screen)
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        // The text storage's own string: `string` can copy the whole page on every move.
        guard index != NSNotFound, let text = textStorage?.mutableString,
              let range = NameMatch.range(at: index, in: text, among: nameRegexes) else {
            setHoveredName(nil)
            return
        }
        // Only when the pointer is on the name itself, not on the empty end of its line.
        let point = convert(event.locationInWindow, from: nil)
        setHoveredName(lineRects(of: range).contains { $0.insetBy(dx: -2, dy: 0).contains(point) } ? range : nil)
    }

    /// Text or scrolling moved under the pointer: the name it was over may not be there.
    override func didChangeText() {
        super.didChangeText()
        forgetHoveredName()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        forgetHoveredName()
    }

    private func forgetHoveredName() {
        guard hoveredName != nil || hoveredIndex != -1 else { return }
        hoveredIndex = -1
        setHoveredName(nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredIndex = -1
        setHoveredName(nil)
    }

    private func setHoveredName(_ range: NSRange?) {
        guard range != hoveredName else { return }
        for old in [hoveredName, range] {
            if let old { setNeedsDisplay(bounds(of: old).insetBy(dx: -4, dy: -4)) }
        }
        hoveredName = range
    }

    /// A dotted line under the tracked name the pointer is over.
    private func drawHoveredName(in rect: NSRect) {
        guard let range = hoveredName, NSMaxRange(range) <= (textStorage?.length ?? 0) else { return }
        PaperTheme.secondary.setStroke()
        for line in lineRects(of: range) {
            let trim = max(0, (line.height - Layout.textSize * 1.3) / 2)
            let y = line.maxY - trim - 1
            guard line.insetBy(dx: -2, dy: -4).intersects(rect) else { continue }
            let path = NSBezierPath()
            path.move(to: NSPoint(x: line.minX, y: y))
            path.line(to: NSPoint(x: line.maxX, y: y))
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.setLineDash([0.1, 3], count: 2, phase: 0)
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let onChangeBarClicked, !changeBars.isEmpty, PageMarks.changeBarsShown {
            let point = convert(event.locationInWindow, from: nil)
            if point.x >= barX - 8, point.x <= barX + 10 {
                let near = NSRect(x: 0, y: point.y - 40, width: bounds.width, height: 80)
                if let hit = bars(in: near).first(where: { $0.box.insetBy(dx: -6, dy: -4).contains(point) }) {
                    onChangeBarClicked(hit.bar)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Clear Desk: the words alone, without comment highlights or change bars.
        guard !PageMarks.deskCleared else { return }
        for highlight in highlights {
            highlight.colour.setFill()
            for line in lineRects(of: highlight.range) {
                // Trim the leading below and above the line, so the band hugs the type.
                let trim = max(0, (line.height - Layout.textSize * 1.3) / 2)
                let box = line.insetBy(dx: -1, dy: trim)
                if box.intersects(rect) { NSBezierPath(rect: box).fill() }
            }
        }
        drawHoveredName(in: rect)
        if PageMarks.changeBarsShown { drawChangeBars(in: rect) }
    }
}

/// What the pages mark besides the words (owner, 2026-11-14): change bars can be turned off
/// (the status bar's Changes menu, `showChangeBars`), and Clear Desk draws neither them nor
/// comment highlights.
@MainActor
enum PageMarks {
    static let changed = Notification.Name("LonghandPageMarksChanged")
    static let changeBarsKey = "showChangeBars"

    static var deskCleared = false {
        didSet { if deskCleared != oldValue { NotificationCenter.default.post(name: changed, object: nil) } }
    }
    static var changeBarsOn = UserDefaults.standard.object(forKey: changeBarsKey) as? Bool ?? true {
        didSet { if changeBarsOn != oldValue { NotificationCenter.default.post(name: changed, object: nil) } }
    }
    static var changeBarsShown: Bool { changeBarsOn && !deskCleared }
}

// MARK: - Breaks drawn as asterisks

/// A break typed as `---` (or `- - -`, `___`) is drawn as asterisks, the way books set one
/// (owner, 2026-11-12). Only the drawing changes: the file keeps what was typed, and since
/// each symbol is swapped for one asterisk, the caret and every range stay where they were.
extension HighlightTextView: NSTextContentStorageDelegate {
    func textContentStorage(_ storage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let drawn = Self.asterisks(in: storage.textStorage, range: range) else { return nil }
        return NSTextParagraph(attributedString: drawn)
    }

    /// The paragraph with its dashes or underscores as asterisks, or nil if it isn't a break.
    static func asterisks(in text: NSAttributedString?, range: NSRange) -> NSAttributedString? {
        guard let text, range.length >= 3, range.length <= 40, NSMaxRange(range) <= text.length else { return nil }
        let string = text.string as NSString
        var mark: unichar = 0
        var marks: [Int] = []
        for index in range.location..<NSMaxRange(range) {
            let unit = string.character(at: index)
            if unit == 0x0A || unit == 0x0D || unit == 0x20 || unit == 0x09 { continue }
            guard unit == 0x2D || unit == 0x5F, mark == 0 || mark == unit else { return nil }
            mark = unit
            marks.append(index - range.location)
        }
        guard marks.count >= 3 else { return nil }
        let drawn = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        for offset in marks { drawn.replaceCharacters(in: NSRange(location: offset, length: 1), with: "*") }
        return drawn
    }
}

// MARK: - Geometry, on either text system

extension NSTextView {

    /// A character range as a TextKit 2 range.
    func textRange(for range: NSRange) -> NSTextRange? {
        guard let content = textLayoutManager?.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// The rectangle of each line a range covers, in view coordinates, with each line's own
    /// height (for trimming the leading off a highlight).
    func lineRects(of range: NSRange) -> [NSRect] {
        guard NSMaxRange(range) <= (string as NSString).length else { return [] }
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        if let textLayoutManager {
            guard let textRange = textRange(for: range) else { return [] }
            textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
                rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
        } else if let layout = layoutManager, let container = textContainer {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                var box = layout.boundingRect(forGlyphRange: part, in: container)
                box.origin.y = used.origin.y
                box.size.height = used.height
                rects.append(box.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        return rects
    }

    /// Scrolls a passage into view, a third of the way down the page if it was off screen.
    /// No flash: the comment's own highlight, darker while it is in focus, marks it.
    func jump(to range: NSRange) {
        guard NSMaxRange(range) <= (string as NSString).length else { return }
        if let textLayoutManager, let target = textRange(for: range),
           let upTo = NSTextRange(location: textLayoutManager.documentRange.location, end: target.endLocation) {
            // TextKit 2 only estimates text it hasn't drawn: lay it out for real first, or the
            // passage lands far from where it was aimed.
            textLayoutManager.ensureLayout(for: upTo)
            textLayoutManager.textViewportLayoutController.layoutViewport()
        }
        let box = bounds(of: range)
        if !box.isNull, let clip = enclosingScrollView?.contentView {
            let visible = clip.documentVisibleRect
            if !visible.contains(box) {
                let y = max(0, min(box.minY - visible.height / 3, frame.height - visible.height))
                clip.scroll(to: NSPoint(x: visible.minX, y: y))
                enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
    }

    /// Everything a range covers, in view coordinates.
    func bounds(of range: NSRange) -> NSRect {
        lineRects(of: range).reduce(NSRect.null) { $0.union($1) }
    }

    /// A line segment type that covers each line's full height (for row bands).
    func lineBands(of range: NSRange) -> [NSRect] {
        guard NSMaxRange(range) <= (string as NSString).length else { return [] }
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        if let textLayoutManager {
            guard let textRange = textRange(for: range) else { return [] }
            textLayoutManager.enumerateTextSegments(in: textRange, type: .selection, options: .rangeNotRequired) { _, frame, _, _ in
                rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
        } else if let layout = layoutManager {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, _, _ in
                rects.append(line.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        return rects
    }

    /// The characters drawn in `rect` (view coordinates), without laying out anything more.
    func characterRange(in rect: NSRect) -> NSRange {
        let origin = textContainerOrigin
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        if let textLayoutManager, let content = textLayoutManager.textContentManager {
            let top = textLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, local.minY)))
            let bottom = textLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: local.maxY))
            let documentStart = content.documentRange.location
            let start = top.map { content.offset(from: documentStart, to: $0.rangeInElement.location) } ?? 0
            let end = bottom.map { content.offset(from: documentStart, to: $0.rangeInElement.endLocation) }
                ?? (string as NSString).length
            return NSRange(location: start, length: max(0, end - start))
        } else if let layout = layoutManager, let container = textContainer {
            let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: local, in: container)
            return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }
        return NSRange(location: 0, length: 0)
    }
}
