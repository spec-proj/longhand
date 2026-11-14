import SwiftUI
import AppKit

/// The text of one scene, for the chapter page.
struct ChapterSceneText: Identifiable, Equatable {
    let id: Int
    let url: URL
    let title: String
    let text: String

    /// Literal comparison: Swift's `==` normalises Unicode, which on a long scene is slow, and
    /// SwiftUI compares these on every refresh.
    static func == (a: ChapterSceneText, b: ChapterSceneText) -> Bool {
        a.id == b.id && a.url == b.url && a.title == b.title && (a.text as NSString).isEqual(to: b.text)
    }
}

/// A chapter as one continuous, editable page: the chapter opener, then every scene's text in
/// order, with a break between one scene and the next set as books set one: three spaced
/// asterisks, centred, in white space (owner, 2026-11-12). Each edit is saved to its own
/// scene file.
///
/// The breaks and the line ends around them belong to no scene. Any edit must fall inside
/// one scene: an edit that would cross a boundary (backspacing at the start of a scene,
/// deleting a selection that spans two) is refused with a beep, so scenes never merge. The
/// opener is not editable.
struct ChapterEditor: NSViewRepresentable {
    /// The chapter folder (where you were on its page is remembered by it).
    let chapter: URL
    let title: String
    let number: Int?
    let scenes: [ChapterSceneText]
    var margin: MarginStore
    var changes: ChangeState
    var places: Places
    var onEdit: (URL, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, margin: margin, changes: changes, places: places)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // The thin scroller, shown only while scrolling.
        scroll.verticalScroller?.controlSize = .small
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = PaperTheme.paper

        let textView = HighlightTextView.page()
        textView.identifier = ChapterEditor.identifier
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: Layout.gutter, height: 28)
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = true
        textView.insertionPointColor = PaperTheme.accent
        textView.selectedTextAttributes = [.backgroundColor: PaperTheme.selection]
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.delegate = context.coordinator

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.attach(textView, scroll: scroll)
        context.coordinator.load(title: title, number: number, scenes: scenes)
        context.coordinator.chapter = chapter
        places.reporter = context.coordinator
        // Laid out first, so the place can be scrolled to.
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            // Come from Read (⌘R): the same place; else where you last were in this chapter.
            if let place = context.coordinator.takeAnchor() {
                textView.restore(place)
            } else if let place = places.place(for: chapter) {
                textView.restore(place)
            } else {
                textView.setSelectedRange(NSRange(location: context.coordinator.bodyStart, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onEdit = onEdit
        let coordinator = context.coordinator
        if coordinator.chapter != chapter {
            // Another chapter on the same page: remember this one's place, go to the next's.
            coordinator.reportPlace()
            coordinator.chapter = chapter
            coordinator.load(title: title, number: number, scenes: scenes)
            places.reporter = coordinator
            if let textView = coordinator.textView {
                if let place = places.place(for: chapter) {
                    textView.restore(place)
                } else {
                    textView.setSelectedRange(NSRange(location: coordinator.bodyStart, length: 0))
                    textView.scrollToBeginningOfDocument(nil)
                }
            }
            return
        }
        coordinator.reloadIfChanged(title: title, number: number, scenes: scenes)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    static let identifier = NSUserInterfaceItemIdentifier("chapter-editor")

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate, CommentPage, PlaceReporter {
        struct Segment {
            let url: URL
            var range: NSRange
        }

        var onEdit: (URL, String) -> Void
        weak var textView: NSTextView?
        /// Scene ranges within the page, kept up to date as the text changes.
        private(set) var segments: [Segment] = []
        /// Where the scenes start (after the opener).
        private(set) var bodyStart = 0
        /// The length of each scene's number line (its line end included), which sits just
        /// before the scene's text.
        private var labelLengths: [Int] = []
        /// Where the caret last was, to tell which way it is moving when it lands on a
        /// number line.
        private var lastCaret = 0
        private var title = ""
        private var number: Int?
        private var dirty: Set<Int> = []
        /// The scene texts last handed in from disk; only a new set can trigger a reload.
        private var lastLoaded: [ChapterSceneText] = []
        private var flushScheduled = false
        /// What changed since the last restyle, so only those lines are restyled.
        private var pendingEdit: NSRange?
        private var loading = false
        /// Each page keeps its own undo history.
        let undo = UndoManager()
        let margin: MarginStore
        private var overlay: CommentOverlay?
        private var modes: WritingModes?
        private let changes: ChangeState
        private var gutter: ChangeGutter?
        let places: Places
        /// The chapter on the page.
        var chapter: URL?

        /// Records where you are on this chapter's page.
        func reportPlace() {
            guard let textView, let chapter, !loading else { return }
            places.record(textView.currentPlace, for: chapter)
        }

        init(onEdit: @escaping (URL, String) -> Void, margin: MarginStore, changes: ChangeState, places: Places) {
            self.onEdit = onEdit
            self.places = places
            self.margin = margin
            self.changes = changes
        }

        func attach(_ textView: HighlightTextView, scroll: NSScrollView) {
            margin.page = self
            overlay = CommentOverlay(textView: textView, margin: margin)
            modes = WritingModes(textView: textView, scroll: scroll)
            gutter = ChangeGutter(textView: textView, page: self, changes: changes, margin: margin) {
                [weak self] in self?.segments.map(\.url) ?? []
            }
            textView.selectAllHandler = { [weak self] in self?.selectAll() ?? false }
            textView.copyText = { [weak self] in self?.copied($0) }
        }

        /// The read-or-write anchor (`MarginStore.ReadingAnchor`) as a place on this page, if
        /// it is in one of its scenes; taken, so it is used once.
        func takeAnchor() -> Places.Place? {
            guard let anchor = margin.readingAnchor else { return nil }
            func page(_ point: (scene: URL, location: Int)?) -> Int? {
                guard let point, let segment = segments.first(where: { $0.url == point.scene }) else { return nil }
                return segment.range.location + min(max(0, point.location), segment.range.length)
            }
            guard let top = page(anchor.top) ?? page(anchor.caret) else { return nil }
            margin.readingAnchor = nil
            return Places.Place(caret: page(anchor.caret) ?? top, top: top)
        }

        /// Where you are on this page, in its scenes' own text.
        private func anchor() -> MarginStore.ReadingAnchor? {
            guard let textView else { return nil }
            func scene(_ location: Int) -> (scene: URL, location: Int)? {
                guard let index = segmentIndex(containing: NSRange(location: location, length: 0)) else { return nil }
                return (segments[index].url, location - segments[index].range.location)
            }
            let place = textView.currentPlace
            return MarginStore.ReadingAnchor(top: scene(place.top), caret: scene(place.caret))
        }

        func detach() {
            // Leaving for Read (or anywhere): Read opens where this page was.
            if let anchor = anchor() { margin.readingAnchor = anchor }
            overlay?.detach()
            modes?.detach()
            gutter?.detach()
            if margin.page === self {
                margin.page = nil
            }
        }

        /// ⌘A: the scene the caret is in; again, every scene. The chapter's title is never
        /// selected, so typing over a selection stays inside the page's text.
        func selectAll() -> Bool {
            guard let textView, let first = segments.first, let last = segments.last else { return false }
            let selection = textView.selectedRange()
            let body = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let scene = segments.first { selection.location >= $0.range.location && selection.location <= NSMaxRange($0.range) }?.range
            if let scene, selection != scene, segments.count > 1 {
                textView.setSelectedRange(scene)
            } else {
                textView.setSelectedRange(body)
            }
            return true
        }

        /// What a selection reaching over more than one scene copies: the scenes' own text,
        /// a blank line between them, without the numbers the page sets between scenes.
        private func copied(_ selection: NSRange) -> String? {
            guard let string = textView?.string as NSString?, segmentIndex(containing: selection) == nil else { return nil }
            let parts = segments.compactMap { segment -> String? in
                let part = NSIntersectionRange(segment.range, selection)
                guard part.length > 0, NSMaxRange(part) <= string.length else { return nil }
                return string.substring(with: part)
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }

        /// The range of a scene's number line on the page.
        private func labelRange(_ index: Int) -> NSRange {
            NSRange(location: segments[index].range.location - labelLengths[index], length: labelLengths[index])
        }

        /// Scene numbers are not Markdown, so after the styler has been over the page they
        /// are set again where it reached them, and the first paragraph of each scene is set
        /// flush with no space above it, as after any break.
        private func styleBreaks() {
            guard let storage = textView?.textStorage, labelLengths.count == segments.count else { return }
            let string = storage.string as NSString
            for index in segments.indices {
                let label = labelRange(index)
                guard label.location >= 0, NSMaxRange(label) <= storage.length, label.length > 0 else { continue }
                if storage.attribute(SceneBreak.key, at: label.location, effectiveRange: nil) == nil
                    || storage.attribute(SceneBreak.key, at: NSMaxRange(label) - 1, effectiveRange: nil) == nil {
                    storage.setAttributes(SceneBreak.attributes, range: label)
                }
                let start = segments[index].range.location
                guard segments[index].range.length > 0, start < storage.length,
                      let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle else { continue }
                let indented = abs(style.firstLineHeadIndent - (Layout.hang + Layout.textSize)) < 0.5
                guard style.paragraphSpacingBefore != 0 || indented else { continue }
                let flush = style.mutableCopy() as! NSMutableParagraphStyle
                flush.paragraphSpacingBefore = 0
                if indented { flush.firstLineHeadIndent = Layout.hang }
                let paragraph = NSIntersectionRange(string.paragraphRange(for: NSRange(location: start, length: 0)),
                                                    NSRange(location: start, length: storage.length - start))
                storage.addAttribute(.paragraphStyle, value: flush, range: paragraph)
            }
        }

        // MARK: CommentPage

        var pageTextView: NSTextView? { textView }

        func pageRange(scene: URL, local: NSRange) -> NSRange? {
            guard let segment = segments.first(where: { $0.url == scene }),
                  NSMaxRange(local) <= segment.range.length else { return nil }
            return NSRange(location: segment.range.location + local.location, length: local.length)
        }

        func selectionInScene() -> (scene: URL, range: NSRange)? {
            guard let selection = textView?.selectedRange(), let index = segmentIndex(containing: selection) else {
                return nil
            }
            let segment = segments[index]
            return (segment.url, NSRange(location: selection.location - segment.range.location, length: selection.length))
        }

        func text(of scene: URL) -> String? {
            guard let segment = segments.first(where: { $0.url == scene }),
                  let string = textView?.string as NSString?,
                  NSMaxRange(segment.range) <= string.length else { return nil }
            return string.substring(with: segment.range)
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// Return in a list or a quote carries its symbol to the next line.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            selector == #selector(NSResponder.insertNewline(_:)) && MarkdownFormat.continueBlock(in: textView)
        }

        func textView(
            _ view: NSTextView,
            didCheckTextIn range: NSRange,
            types checkingTypes: NSTextCheckingTypes,
            options: [NSSpellChecker.OptionKey: Any] = [:],
            results: [NSTextCheckingResult],
            orthography: NSOrthography,
            wordCount: Int
        ) -> [NSTextCheckingResult] {
            ProofingFilter.filter(results, in: view.string as NSString)
        }

        // MARK: Loading

        func load(title: String, number: Int?, scenes: [ChapterSceneText]) {
            guard let textView, let storage = textView.textStorage else { return }
            loading = true
            defer { loading = false }
            self.title = title
            self.number = number
            lastLoaded = scenes

            let opener = ChapterOpener.text(title: title, number: number)
            bodyStart = opener.length

            let body = NSMutableString()
            var location = bodyStart
            segments = []
            labelLengths = []
            for (index, scene) in scenes.enumerated() {
                if index > 0 {
                    body.append("\n")
                    location += 1
                }
                // A break before every scene but the chapter's first.
                let label = index > 0 ? SceneBreak.ornament + "\n" : ""
                body.append(label)
                labelLengths.append((label as NSString).length)
                location += (label as NSString).length
                let length = (scene.text as NSString).length
                segments.append(Segment(url: scene.url, range: NSRange(location: location, length: length)))
                body.append(scene.text)
                location += length
            }

            let page = NSMutableAttributedString(attributedString: opener)
            page.append(NSAttributedString(string: body as String, attributes: MarkdownStyler.baseAttributes))
            storage.delegate = nil
            storage.setAttributedString(page)
            storage.delegate = self
            restyle()
            undo.removeAllActions()
            dirty = []

            // The comments of every scene on the page, each matched to its scene's text.
            margin.openChapterPage(scenes: scenes.map(\.url))
            for scene in scenes { margin.anchor(scene: scene.url, text: scene.text) }
            overlay?.invalidate()
            modes?.update(loaded: true)
            gutter?.loaded()
        }

        /// Re-reads only when a new read from disk differs from what the page shows (or the
        /// chapter's scenes changed), and never while edits are waiting to be handed over.
        /// SwiftUI calls this on every refresh — a word count changing, say — so it must not
        /// reload just because the page has moved on from what was first loaded.
        func reloadIfChanged(title: String, number: Int?, scenes: [ChapterSceneText]) {
            guard dirty.isEmpty, let storage = textView?.textStorage else { return }
            guard scenes != lastLoaded || title != self.title || number != self.number else { return }
            let sameShape = title == self.title && number == self.number
                && scenes.map(\.url) == segments.map(\.url)
            if sameShape {
                let string = storage.string as NSString
                // NSString comparison: literal and fast. Swift's `==` normalises Unicode, which
                // on a whole chapter took longer than the keystroke itself.
                let unchanged = zip(scenes, segments).allSatisfy { scene, segment in
                    NSMaxRange(segment.range) <= string.length
                        && string.substring(with: segment.range) as NSString == scene.text as NSString
                }
                if unchanged {
                    lastLoaded = scenes
                    return
                }
            }
            let selection = textView?.selectedRange()
            load(title: title, number: number, scenes: scenes)
            if let selection, NSMaxRange(selection) <= storage.length {
                textView?.setSelectedRange(selection)
            }
        }

        // MARK: Editing

        func textViewDidChangeSelection(_ notification: Notification) {
            if !loading, let textView, let first = segments.first, let last = segments.last {
                // The caret never rests on the chapter's title or a scene's number, where
                // nothing can be typed: it goes on to the nearest scene, the way it was heading.
                let selection = textView.selectedRange()
                if selection.length == 0, !segments.contains(where: {
                    selection.location >= $0.range.location && selection.location <= NSMaxRange($0.range)
                }) {
                    let before = segments.last { NSMaxRange($0.range) <= selection.location }
                    let after = segments.first { $0.range.location >= selection.location }
                    let target = selection.location < lastCaret
                        ? (before.map { NSMaxRange($0.range) } ?? first.range.location)
                        : (after?.range.location ?? NSMaxRange(last.range))
                    lastCaret = target
                    textView.setSelectedRange(NSRange(location: target, length: 0))
                    return
                }
                lastCaret = selection.location
            }
            if !loading { modes?.update() }
            guard let location = textView?.selectedRange().location, !loading,
                  let segment = segments.first(where: {
                      location >= $0.range.location && location <= NSMaxRange($0.range)
                  }) else { return }
            margin.caretMoved(scene: segment.url, location: location - segment.range.location)
        }

        /// The scene an edit of `range` would fall entirely inside, if any.
        func segmentIndex(containing range: NSRange) -> Int? {
            segments.firstIndex {
                range.location >= $0.range.location && NSMaxRange(range) <= NSMaxRange($0.range)
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard replacementString != nil else { return true }
            if segmentIndex(containing: affectedCharRange) != nil { return true }
            NSSound.beep()
            return false
        }

        /// Edits of several ranges at once (Replace All in the find bar, a drag between
        /// paragraphs): allowed only when every range is inside the same scene, because the
        /// storage reports them as one change and it is credited to one scene.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard replacementStrings != nil else { return true }
            let scenes = Set(affectedRanges.map { segmentIndex(containing: $0.rangeValue) })
            if scenes.count == 1, scenes.first != .some(nil) { return true }
            NSSound.beep()
            return false
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !loading else { return }
            let location = editedRange.location
            guard let index = segments.firstIndex(where: {
                location >= $0.range.location && location <= NSMaxRange($0.range)
            }) else { return }

            pendingEdit = pendingEdit.map { NSUnionRange($0, editedRange) } ?? editedRange
            segments[index].range.length += delta
            for later in segments.indices where later > index {
                segments[later].range.location += delta
            }
            dirty.insert(index)
            margin.textDidEdit(
                scene: segments[index].url,
                range: NSRange(location: editedRange.location - segments[index].range.location, length: editedRange.length),
                delta: delta
            ) { [segment = segments[index].range] in (textStorage.string as NSString).substring(with: segment) as NSString }

            // Report and restyle after the storage has finished this edit (this also covers
            // undo and redo, which don't always pass through the text view's own callbacks).
            if !flushScheduled {
                flushScheduled = true
                DispatchQueue.main.async { [weak self] in self?.flush() }
            }
        }

        private func flush() {
            flushScheduled = false
            guard let storage = textView?.textStorage else { return }
            let string = storage.string as NSString
            for index in dirty.sorted() where index < segments.count {
                let segment = segments[index]
                guard NSMaxRange(segment.range) <= string.length else { continue }
                let text = string.substring(with: segment.range)
                onEdit(segment.url, text)
                margin.textDidSettle(scene: segment.url, text: text)
            }
            dirty = []
            if textView?.hasMarkedText() != true { restyleEdited() }
            overlay?.invalidate()
            modes?.update()
            gutter?.edited()
        }

        /// Restyles only the lines the last edits touched (see `MarkdownStyler.restyle`).
        private func restyleEdited() {
            guard let textView, let storage = textView.textStorage, let edited = pendingEdit else { return }
            pendingEdit = nil
            let selection = textView.selectedRange()
            let body = NSRange(location: bodyStart, length: storage.length - bodyStart)
            let start = min(max(edited.location, body.location), storage.length)
            let end = min(max(NSMaxRange(edited), start), storage.length)
            MarkdownStyler.restyle(storage, around: NSRange(location: start, length: end - start), within: body)
            styleBreaks()
            if NSMaxRange(selection) <= storage.length {
                textView.setSelectedRange(selection)
            }
            textView.typingAttributes = MarkdownStyler.baseAttributes
        }

        private func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let bodyRange = NSRange(location: bodyStart, length: storage.length - bodyStart)
            MarkdownStyler.apply(to: storage, range: bodyRange, mode: .editor)
            styleBreaks()
            if NSMaxRange(selection) <= storage.length {
                textView.setSelectedRange(selection)
            }
            textView.typingAttributes = MarkdownStyler.baseAttributes
        }
    }
}

/// A book's chapter opener: space above, a small "Chapter 1", then the title, both centred,
/// with the text starting lower on the page. It scrolls with the text.
enum ChapterOpener {
    static func text(title: String, number: Int?) -> NSAttributedString {
        func style(before: CGFloat, after: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.firstLineHeadIndent = Layout.hang
            style.headIndent = Layout.hang
            style.tailIndent = -Layout.hang
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            return style
        }

        let result = NSMutableAttributedString()
        if let number {
            result.append(NSAttributedString(string: "Chapter \(number)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: PaperTheme.secondary,
                .paragraphStyle: style(before: 64, after: 14)
            ]))
        }
        result.append(NSAttributedString(string: title + "\n", attributes: [
            .font: EditorFont.serif(32),
            .foregroundColor: PaperTheme.ink,
            .paragraphStyle: style(before: number == nil ? 64 : 0, after: 44)
        ]))
        return result
    }
}

/// The break between two scenes on the chapter page, and a `---` in the reading view: three
/// spaced asterisks, centred, with white space above and below.
enum SceneBreak {
    /// Marks a break's line, so it can be told from the scenes' own text.
    static let key = NSAttributedString.Key("LonghandSceneBreak")
    static let ornament = "* * *"

    static var attributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.firstLineHeadIndent = Layout.hang
        style.headIndent = Layout.hang
        style.tailIndent = -Layout.hang
        style.paragraphSpacingBefore = (Layout.textSize * 1.3).rounded()
        style.paragraphSpacing = (Layout.textSize * 1.3).rounded()
        return [
            .font: EditorFont.serif(Layout.textSize),
            .foregroundColor: PaperTheme.secondary,
            .kern: Layout.textSize * 0.35,
            .paragraphStyle: style,
            key: true
        ]
    }
}
