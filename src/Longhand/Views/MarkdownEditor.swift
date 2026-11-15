import SwiftUI
import AppKit
import Combine

/// The scene editor: one Markdown file in an `NSTextView`, styled in place.
///
/// It also carries the scene's comments: their passages are highlighted (more strongly for the
/// comment in focus), edits move them along with the text, and the editor reports where each
/// passage sits on screen so the margin can set its card beside it.
struct MarkdownEditor: NSViewRepresentable {
    let text: String
    /// Moves when the text is replaced from disk; typing leaves it alone. Comparing this
    /// instead of the text itself keeps each keystroke from comparing the whole scene.
    let version: Int
    /// The scene file shown, so its comments can be told apart from others.
    let scene: URL
    var margin: MarginStore
    /// What changed since the last version, for the bars beside the paragraphs.
    var changes: ChangeState
    /// Where you were in each scene.
    var places: Places
    /// The text, and the `version` this editor last loaded (the store drops stale reports).
    var onChange: (String, Int) -> Void
    /// A Fountain screenplay (`ScreenplayStyler`, `ScreenplayKeys`) rather than Markdown.
    var screenplay = false
    /// Poems or songs: every line kept as written (`MarkdownStyler`'s verse).
    var verse = false
    /// Where the status bar's counts (and a screenplay's element) live.
    var live: LiveCount? = nil
    /// A single document: moves a selected passage (and the text before it) to the Boneyard;
    /// true when it did, and the page then takes the passage out.
    var cutPassage: ((String, String) -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
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
        // Less room above the text now the chapter's name sits in the page's header row.
        textView.textContainerInset = NSSize(width: Layout.gutter, height: 40)
        textView.drawsBackground = false
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
        textView.font = EditorFont.serif(MarkdownStyler.baseSize)
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.delegate = context.coordinator

        scroll.documentView = textView
        context.coordinator.attach(textView, scroll: scroll)
        context.coordinator.load(text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // Laid out first, then to where you were: the place Read was showing (⌘R), else where
        // you last were in this scene (a new editor, as after Read, starts there too).
        DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
            guard let textView, let coordinator else { return }
            if let anchor = coordinator.takeAnchor() {
                textView.restore(anchor)
            } else {
                if let place = places.place(for: scene) { textView.restore(place) }
                // SwiftUI dismantles the outgoing Read page slightly after making Write:
                DispatchQueue.main.async { [weak textView, weak coordinator] in
                    guard let textView, let coordinator, let anchor = coordinator.takeAnchor() else { return }
                    textView.restore(anchor)
                }
            }
        }

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        if context.coordinator.loadedVersion != version || context.coordinator.loadedScene != scene {
            let switching = context.coordinator.loadedScene != scene
            // Leaving a scene: remember where you were in it.
            if switching { context.coordinator.reportPlace() }
            context.coordinator.load(text)
            places.reporter = context.coordinator
            if switching, let place = places.place(for: scene) {
                textView.restore(place)
            } else if switching {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollToBeginningOfDocument(nil)
            } else {
                // The same scene, re-read from disk: stay where you are, as near as it allows.
                textView.restore(context.coordinator.placeBeforeReload ?? Places.Place(caret: 0, top: 0))
            }
            // The text was replaced from disk; old undo steps no longer match it.
            context.coordinator.undo.removeAllActions()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate, CommentPage, PlaceReporter {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        /// Each scene editor keeps its own undo history, so Undo never reaches back into a
        /// scene you were editing before.
        let undo = UndoManager()
        private var loading = false
        private var overlay: CommentOverlay?
        private var modes: WritingModes?
        private var gutter: ChangeGutter?
        /// The text version on screen (see `MarkdownEditor.version`).
        var loadedVersion = -1
        /// The scene whose text is on screen.
        var loadedScene: URL?
        /// What changed since the last restyle, so only those lines are restyled.
        private var pendingEdit: NSRange?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undo
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

        /// Return in a list or a quote carries its symbol to the next line. In a screenplay,
        /// Return and Tab move between elements (`ScreenplayKeys`).
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if parent.screenplay {
                if selector == #selector(NSResponder.insertNewline(_:)) {
                    capsLine = nil
                    guard let insert = ScreenplayKeys.newline(in: textView) else { return false }
                    textView.insertText(insert, replacementRange: textView.selectedRange())
                    return true
                }
                if selector == #selector(NSResponder.insertTab(_:)) {
                    switch ScreenplayKeys.tab(in: textView) {
                    case .character:
                        // What is typed on this line is set in capitals: a name.
                        let string = textView.string as NSString
                        let at = textView.selectedRange().location
                        capsLine = at == string.length ? at : string.lineRange(for: NSRange(location: at, length: 0)).location
                        parent.live?.setElement("Character")
                    case .parenthetical:
                        let at = textView.selectedRange().location
                        textView.insertText("()", replacementRange: textView.selectedRange())
                        textView.setSelectedRange(NSRange(location: at + 1, length: 0))
                    case .none:
                        break
                    }
                    // Never a tab character in the script.
                    return true
                }
                return false
            }
            return selector == #selector(NSResponder.insertNewline(_:)) && MarkdownFormat.continueBlock(in: textView)
        }

        /// Right-click in a single document: Move to Boneyard for the selected passage.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard parent.cutPassage != nil, view.selectedRange().length > 0 else { return menu }
            let item = NSMenuItem(title: "Move to Boneyard", action: #selector(moveSelectionToBoneyard), keyEquivalent: "")
            item.target = self
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
            return menu
        }

        @objc func moveSelectionToBoneyard() {
            guard let textView, let cut = parent.cutPassage else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let string = textView.string as NSString
            let passage = string.substring(with: range)
            let start = max(0, range.location - 80)
            let before = string.substring(with: NSRange(location: start, length: range.location - start))
            guard cut(passage, before) else { return }
            // Out of the page as an edit, so it saves like typing.
            textView.insertText("", replacementRange: range)
        }

        /// A line Tab began as a character's name: what's typed on it is set in capitals.
        private var capsLine: Int?

        /// In a screenplay a scene heading, and a name begun with Tab, are typed in capitals.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard parent.screenplay, let typed = replacementString, !typed.isEmpty,
                  typed.contains(where: \.isLowercase), !typed.contains("\n"), !textView.hasMarkedText() else { return true }
            let string = textView.string as NSString
            let lineStart = range.location >= string.length && (string.length == 0 || string.character(at: string.length - 1) == 0x0A)
                ? range.location
                : string.lineRange(for: NSRange(location: min(range.location, max(string.length - 1, 0)), length: 0)).location
            guard range.location >= lineStart else { return true }
            let before = string.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            if capsLine == lineStart {
                textView.insertText(typed.uppercased(), replacementRange: range)
                return false
            }
            if ScreenplayKeys.isHeading(before + typed) {
                // The whole heading so far, in capitals ("int. " becomes "INT. ").
                let whole = NSRange(location: lineStart, length: NSMaxRange(range) - lineStart)
                textView.insertText((before + typed).uppercased(), replacementRange: whole)
                return false
            }
            return true
        }

        // MARK: Setup

        func attach(_ textView: NSTextView, scroll: NSScrollView) {
            self.textView = textView
            textView.textStorage?.delegate = self
            parent.margin.page = self
            if let page = textView as? HighlightTextView {
                overlay = CommentOverlay(textView: page, margin: parent.margin)
                gutter = ChangeGutter(textView: page, page: self, changes: parent.changes, margin: parent.margin) {
                    [weak self] in self.map { [$0.parent.scene] } ?? []
                }
            }
            modes = WritingModes(textView: textView, scroll: scroll)
        }

        /// The read-or-write anchor as a place in this scene, if it is for this scene; taken.
        func takeAnchor() -> Places.Place? {
            guard let anchor = parent.margin.readingAnchor, let textView else { return nil }
            let length = (textView.string as NSString).length
            let top = anchor.top.flatMap { $0.scene == parent.scene ? $0.location : nil }
            let caret = anchor.caret.flatMap { $0.scene == parent.scene ? $0.location : nil }
            guard let at = top ?? caret else { return nil }
            parent.margin.readingAnchor = nil
            // From Read the top is an element's start: the caret goes there too.
            return Places.Place(caret: min(caret ?? at, length), top: min(at, length))
        }

        func detach() {
            // A screenplay leaving for Read: it opens at the same part of the script.
            if parent.screenplay, let textView, let scene = loadedScene {
                let place = textView.currentPlace
                parent.margin.readingAnchor = MarginStore.ReadingAnchor(top: (scene, place.top), caret: (scene, place.caret))
                reportPlace()
            }
            overlay?.detach()
            modes?.detach()
            gutter?.detach()
            if parent.margin.page === self {
                parent.margin.page = nil
            }
        }

        /// The place on the page before the text was last replaced.
        private(set) var placeBeforeReload: Places.Place?

        /// Records where you are in the scene on screen.
        func reportPlace() {
            guard let textView, let scene = loadedScene, !loading else { return }
            parent.places.record(textView.currentPlace, for: scene)
        }

        /// Puts new text from disk on the page and finds each comment's passage in it.
        func load(_ text: String) {
            guard let textView else { return }
            placeBeforeReload = loadedScene == nil ? nil : textView.currentPlace
            loadedVersion = parent.version
            loadedScene = parent.scene
            pendingEdit = nil
            loading = true
            capsLine = nil
            textView.string = text
            loading = false
            // "--" stays two hyphens in a script; smart quotes are fine.
            textView.isAutomaticDashSubstitutionEnabled = !parent.screenplay
            if let storage = textView.textStorage {
                if parent.screenplay { ScreenplayStyler.apply(to: storage) } else { MarkdownStyler.apply(to: storage, verse: parent.verse) }
            }
            textView.typingAttributes = parent.screenplay ? ScreenplayStyler.baseAttributes : MarkdownStyler.baseAttributes
            reportElement()
            parent.margin.anchor(scene: parent.scene, text: text)
            overlay?.invalidate()
            modes?.update(loaded: true)
            gutter?.loaded()
        }

        // MARK: CommentPage

        var pageTextView: NSTextView? { textView }

        func pageRange(scene: URL, local: NSRange) -> NSRange? {
            scene == parent.scene ? local : nil
        }

        func selectionInScene() -> (scene: URL, range: NSRange)? {
            guard let textView else { return nil }
            return (parent.scene, textView.selectedRange())
        }

        func text(of scene: URL) -> String? {
            scene == parent.scene ? textView?.string : nil
        }

        // MARK: Editing

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !loading else { return }
            pendingEdit = pendingEdit.map { NSUnionRange($0, editedRange) } ?? editedRange
            parent.margin.textDidEdit(scene: parent.scene, range: editedRange, delta: delta) { textStorage.string as NSString }
            // Undo and Redo change the text without always telling the text view's delegate:
            // report every edit once the storage is done, unless typing already did.
            unreported = true
            if !reportScheduled {
                reportScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.reportScheduled = false
                    if self.unreported, let textView = self.textView {
                        self.report(textView)
                    }
                }
            }
        }

        private var unreported = false
        private var reportScheduled = false

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            report(textView)
        }

        private func report(_ textView: NSTextView) {
            unreported = false
            parent.onChange(textView.string, loadedVersion)
            parent.margin.textDidSettle(scene: parent.scene, text: textView.string)
            gutter?.edited()
            guard !textView.hasMarkedText() else { return }
            restyle(textView)
            overlay?.invalidate()
            modes?.update()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !loading else { return }
            parent.margin.caretMoved(scene: parent.scene, location: textView.selectedRange().location)
            modes?.update()
            if let line = capsLine {
                let string = textView.string as NSString
                let at = textView.selectedRange().location
                let start = at >= string.length && (string.length == 0 || string.character(at: string.length - 1) == 0x0A)
                    ? at : string.lineRange(for: NSRange(location: min(at, max(string.length - 1, 0)), length: 0)).location
                if start != line { capsLine = nil }
            }
            reportElement()
        }

        /// The element the caret is in, for the status bar (screenplays only).
        private func reportElement() {
            guard let live = parent.live else { return }
            guard parent.screenplay, let textView else {
                live.setElement(nil)
                return
            }
            if capsLine != nil {
                live.setElement("Character")
                return
            }
            let kind = ScreenplayStyler.element(at: textView.selectedRange().location, in: textView.string as NSString)
            live.setElement(Self.name(of: kind))
        }

        static func name(of kind: Fountain.Kind) -> String {
            switch kind {
            case .blank, .action: return "Action"
            case .titleKey, .titleValue: return "Title Page"
            case .sceneHeading: return "Scene Heading"
            case .character: return "Character"
            case .parenthetical: return "Parenthetical"
            case .dialogue: return "Dialogue"
            case .transition: return "Transition"
            case .centered: return "Centred"
            case .lyric: return "Lyric"
            case .pageBreak: return "Page Break"
            case .section: return "Section"
            case .synopsis: return "Synopsis"
            }
        }

        private func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let edited = pendingEdit ?? NSRange(location: 0, length: storage.length)
            pendingEdit = nil
            let around = NSRange(
                location: min(edited.location, storage.length),
                length: max(0, min(NSMaxRange(edited), storage.length) - min(edited.location, storage.length))
            )
            if parent.screenplay {
                ScreenplayStyler.restyle(storage, around: around)
            } else {
                MarkdownStyler.restyle(storage, around: around, verse: parent.verse)
            }
            if selection.location <= storage.length {
                textView.setSelectedRange(NSRange(
                    location: selection.location,
                    length: min(selection.length, storage.length - selection.location)
                ))
            }
            textView.typingAttributes = parent.screenplay ? ScreenplayStyler.baseAttributes : MarkdownStyler.baseAttributes
        }
    }
}
