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

        /// Return in a list or a quote carries its symbol to the next line.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            selector == #selector(NSResponder.insertNewline(_:)) && MarkdownFormat.continueBlock(in: textView)
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

        func detach() {
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
            textView.string = text
            loading = false
            if let storage = textView.textStorage {
                MarkdownStyler.apply(to: storage)
            }
            textView.typingAttributes = MarkdownStyler.baseAttributes
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
        }

        private func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let edited = pendingEdit ?? NSRange(location: 0, length: storage.length)
            pendingEdit = nil
            MarkdownStyler.restyle(storage, around: NSRange(
                location: min(edited.location, storage.length),
                length: max(0, min(NSMaxRange(edited), storage.length) - min(edited.location, storage.length))
            ))
            if selection.location <= storage.length {
                textView.setSelectedRange(NSRange(
                    location: selection.location,
                    length: min(selection.length, storage.length - selection.location)
                ))
            }
            textView.typingAttributes = MarkdownStyler.baseAttributes
        }
    }
}
