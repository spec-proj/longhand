import AppKit
import SwiftUI
import Combine

/// The three places the keyboard can be: the contents column, the page (or its cards), the
/// margin.
enum Pane: String, CaseIterable {
    case contents, page, margin

    /// The setting that shows it (the page is always there).
    var shownKey: String? {
        switch self {
        case .contents: return "showSidebar"
        case .margin: return "showMargin"
        case .page: return nil
        }
    }
}

/// Where the keyboard is, and moving it without the mouse (Go › Contents, Page, Margin; Tab
/// and ⇧Tab from the contents, the cards and the margin; Escape back to the page).
///
/// All of it is AppKit's first responder. SwiftUI's own focus (`.focusable`, `@FocusState`)
/// could not be given the keyboard from a menu command while the page's text view held it,
/// and a view that had it was no use to hand the keyboard back to (see `KeyField`). Each pane
/// has a `PaneKeys` view behind it that can hold the keyboard and takes that pane's keys.
@MainActor
enum Panes {
    /// The pane that last held the keyboard: where it goes back to when what held it is gone
    /// (a palette command that changed the page, a comment's field that closed).
    static var active: Pane = .page

    /// Asks the margin's note field to take the keyboard (Return in the margin on Notes).
    static let typeNote = PassthroughSubject<Void, Never>()

    private final class Entry {
        weak var view: PaneKeys.KeysView?
        init(_ view: PaneKeys.KeysView) { self.view = view }
    }
    private static var entries: [Entry] = []

    static func register(_ view: PaneKeys.KeysView) {
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(view))
        if let store = view.store { self.store = store }
        pageArrived()
    }

    private static weak var store: LibraryStore?

    /// A page (its text, or its cards) has come on screen: if the one it replaces had the
    /// keyboard, so that nothing has it now, this one takes it. Asked again a moment later,
    /// when the page it replaces has gone.
    static func pageArrived() {
        for delay in [0, 120] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) {
                if let store { settle(in: store) }
            }
        }
    }

    static func unregister(_ view: PaneKeys.KeysView) {
        entries.removeAll { $0.view == nil || $0.view === view }
    }

    private static func onScreen(_ view: NSView) -> Bool {
        view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    /// The view that takes a pane's keys: the innermost one on screen (the cards' own, over
    /// the page area's plain one).
    static func keysView(_ pane: Pane) -> PaneKeys.KeysView? {
        entries.compactMap(\.view)
            .filter { $0.pane == pane && onScreen($0) }
            .max { $0.priority < $1.priority }
    }

    private static func window(_ store: LibraryStore) -> NSWindow? {
        entries.compactMap { $0.view?.window }.first
            ?? store.margin.textView?.window
            ?? NSApp.mainWindow
    }

    /// What takes the keyboard for the page: its text (to write in, or to read), else the
    /// cards, else the page area itself.
    private static func pageResponder(_ store: LibraryStore) -> NSView? {
        if let text = store.margin.textView, onScreen(text) { return text }
        return keysView(.page)
    }

    /// Whether a pane is on screen now.
    static func isShown(_ pane: Pane) -> Bool {
        guard let key = pane.shownKey else { return true }
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Gives a pane the keyboard, showing it first if it is hidden. The view may take a
    /// moment to come on screen, so it looks again for a third of a second.
    static func focus(_ pane: Pane, in store: LibraryStore, tries: Int = 12) {
        active = pane
        // (Hidden runs never write settings.)
        if let key = pane.shownKey, !isShown(pane), !Snapshot.isBackgroundRun {
            UserDefaults.standard.set(true, forKey: key)
        }
        // Find in Library stands where the contents does: put it away.
        if pane == .contents, store.searchShown { store.searchShown = false }
        if store.deskCleared, pane != .page { store.deskCleared = false }
        let target = pane == .page ? pageResponder(store) : keysView(pane)
        if let target, let window = target.window {
            if window.firstResponder !== target { window.makeFirstResponder(target) }
            return
        }
        guard tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
            // Something else was asked for meanwhile.
            guard active == pane else { return }
            focus(pane, in: store, tries: tries - 1)
        }
    }

    /// The pane after (or before) this one that is on screen: contents, page, margin, round.
    static func next(after pane: Pane, by step: Int) -> Pane {
        let order = Pane.allCases
        var index = order.firstIndex(of: pane) ?? 1
        for _ in order {
            index = (index + step + order.count) % order.count
            if isShown(order[index]) { return order[index] }
        }
        return .page
    }

    /// The pane holding the keyboard, if something on screen has it.
    static func current(in window: NSWindow) -> Pane? {
        guard let view = holder(in: window) else { return nil }
        if let keys = view as? PaneKeys.KeysView { return keys.pane }
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        // The page's plain view lies behind the whole page area; the side panes are beside it.
        for pane in [Pane.contents, .margin, .page] {
            let views = entries.compactMap(\.view).filter { $0.pane == pane && $0.window === window && onScreen($0) }
            if views.contains(where: { $0.convert($0.bounds, to: nil).contains(centre) }) { return pane }
        }
        return nil
    }

    /// The view on screen that has the keyboard (the field behind a field's shared editor),
    /// or nil when nothing does: the window itself, or a view that has been taken away.
    private static func holder(in window: NSWindow) -> NSView? {
        var view = window.firstResponder as? NSView
        if let editor = view as? NSTextView, editor.isFieldEditor { view = editor.delegate as? NSView }
        guard let view, view !== window.contentView, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return view
    }

    /// Nothing on screen has the keyboard (what had it was taken away): give it to the pane
    /// that had it last. Something on screen keeps it, and is remembered.
    static func settle(in store: LibraryStore) {
        guard let window = window(store), window.attachedSheet == nil else { return }
        if let view = holder(in: window) {
            // The palette's field on its way out doesn't count.
            if !((view as? KeyField.Field)?.isPalette == true && !store.quickOpenShown) {
                if let pane = current(in: window) { active = pane }
                return
            }
        }
        if !isShown(active) { active = .page }
        let target = active == .page ? pageResponder(store) : keysView(active)
        if let target, window.firstResponder !== target { window.makeFirstResponder(target) }
    }

    /// Settles now and a few more times: the view the keyboard should go to may still be on
    /// its way (a page being loaded, the window drawn again for a theme), and the one given
    /// it first may be on its way out.
    static func settleSoon(in store: LibraryStore, tries: Int = 8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            settle(in: store)
            if tries > 1 { settleSoon(in: store, tries: tries - 1) }
        }
    }
}

/// A view behind a pane that can hold the keyboard and is handed that pane's keys. Tab and
/// ⇧Tab go on to the next pane and Escape goes back to the page, unless `onKey` used them.
struct PaneKeys: NSViewRepresentable {
    let pane: Pane
    /// The cards' own view comes before the page area's plain one.
    var priority = 0
    let store: LibraryStore
    /// Returns true when the key was used.
    var onKey: (NSEvent) -> Bool = { _ in false }
    /// The pane took or lost the keyboard.
    var onFocus: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> KeysView {
        let view = KeysView()
        update(view)
        return view
    }

    func updateNSView(_ view: KeysView, context: Context) { update(view) }

    private func update(_ view: KeysView) {
        view.pane = pane
        view.priority = priority
        view.store = store
        view.onKey = onKey
        view.onFocus = onFocus
    }

    static func dismantleNSView(_ view: KeysView, coordinator: ()) {
        Panes.unregister(view)
    }

    final class KeysView: NSView {
        var pane = Pane.page
        var priority = 0
        weak var store: LibraryStore?
        var onKey: (NSEvent) -> Bool = { _ in false }
        var onFocus: (Bool) -> Void = { _ in }

        override var acceptsFirstResponder: Bool { true }
        // Clicks belong to what is drawn over it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Panes.register(self) } else { Panes.unregister(self) }
        }

        override func becomeFirstResponder() -> Bool {
            Panes.active = pane
            onFocus(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            onFocus(false)
            return true
        }

        override func keyDown(with event: NSEvent) {
            if onKey(event) { return }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if let store {
                switch event.keyCode {
                case 48 where flags.isEmpty || flags == .shift:          // Tab, ⇧Tab
                    Panes.focus(Panes.next(after: pane, by: flags == .shift ? -1 : 1), in: store)
                    return
                case 53 where flags.isEmpty && pane != .page:            // Escape
                    Panes.focus(.page, in: store)
                    return
                default:
                    break
                }
            }
            // Keys with nothing to do here are dropped quietly (no beep on a stray letter);
            // ⌘ keys go on to the menus.
            if flags.contains(.command) { super.keyDown(with: event) }
        }
    }
}
