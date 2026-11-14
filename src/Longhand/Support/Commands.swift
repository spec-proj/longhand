import AppKit

/// Actions shared by the toolbar and the menu bar.
@MainActor
enum Commands {
    /// Opens the find bar on the page being edited.
    static func showFind(in margin: MarginStore) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if !(window?.firstResponder is NSTextView),
           let page = margin.textView ?? window?.contentView.flatMap(pageTextView(in:)) {
            window?.makeFirstResponder(page)
        }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
    }

    /// Comments on the selected text, opening the margin on Comments if it is hidden.
    static func comment(margin: MarginStore) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "showMargin")
        defaults.set(MarginStore.Tab.comments.rawValue, forKey: "marginTab")
        margin.addCommentOnSelection()
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
        if let textView = view as? NSTextView, textView.isEditable, textView.isFieldEditor == false {
            return textView
        }
        for subview in view.subviews {
            if let found = pageTextView(in: subview) { return found }
        }
        return nil
    }
}
