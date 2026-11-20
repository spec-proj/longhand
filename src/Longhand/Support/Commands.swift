import AppKit

/// Actions shared by the toolbar and the menu bar.
@MainActor
enum Commands {
    /// Opens the find bar on the page being edited.
    static func showFind(in margin: MarginStore) {
        performFind(action: .showFindInterface, in: margin)
    }

    /// Opens the find bar with the replace interface.
    static func showReplace(in margin: MarginStore) {
        performFind(action: .showReplaceInterface, in: margin)
    }

    /// Finds the next occurrence.
    static func findNext(in margin: MarginStore) {
        performFind(action: .nextMatch, in: margin)
    }

    /// Finds the previous occurrence.
    static func findPrevious(in margin: MarginStore) {
        performFind(action: .previousMatch, in: margin)
    }

    private static func performFind(action: NSTextFinder.Action, in margin: MarginStore) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let page = (window?.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? nil : $0 }
            ?? margin.textView
            ?? window?.contentView.flatMap(pageTextView(in:))
        guard let page else {
            let item = NSMenuItem()
            item.tag = action.rawValue
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            return
        }
        if action == .showFindInterface || action == .showReplaceInterface {
            if window?.firstResponder !== page && (window?.firstResponder as? NSTextView)?.isFieldEditor != true {
                window?.makeFirstResponder(page)
            }
        }
        let item = NSMenuItem()
        item.tag = action.rawValue
        page.performTextFinderAction(item)
    }

    /// Comments on the selected text, opening the margin on Comments if it is hidden.
    static func comment(margin: MarginStore) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "showMargin")
        defaults.set(MarginStore.Tab.comments.rawValue, forKey: "marginTab")
        margin.addCommentOnSelection()
    }

    /// Starts tracking the selected text as a name (the word at the caret if nothing is
    /// selected), and opens the margin on Names.
    static func trackName(store: LibraryStore) {
        let margin = store.margin
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let page = (window?.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? nil : $0 } ?? margin.textView
        guard let page, let book = margin.bookURL ?? store.openBook else { NSSound.beep(); return }
        var range = page.selectedRange()
        if range.length == 0 {
            range = page.selectionRange(forProposedRange: range, granularity: .selectByWord)
        }
        let name = (page.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "showMargin")
        defaults.set(MarginStore.Tab.names.rawValue, forKey: "marginTab")
        if name.isEmpty || !margin.trackName(name, in: book) { NSSound.beep() }
    }

    /// Bold or italic on the page being edited.
    static func format(_ style: MarkdownFormat.Style, margin: MarginStore) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let page = (window?.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? nil : $0 } ?? margin.textView
        guard let page, page.isEditable else { NSSound.beep(); return }
        MarkdownFormat.toggle(style, in: page)
    }

    /// Longhand › Settings… (the command palette's way in).
    static func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Opens the margin on the Changes tab.
    static func showChanges() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "showMargin")
        defaults.set(MarginStore.Tab.changes.rawValue, forKey: "marginTab")
    }

    private static func pageTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isSelectable, textView.isFieldEditor == false {
            return textView
        }
        for subview in view.subviews {
            if let found = pageTextView(in: subview) { return found }
        }
        return nil
    }
}
