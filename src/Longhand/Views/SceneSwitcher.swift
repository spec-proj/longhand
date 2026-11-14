import SwiftUI
import AppKit

/// Go › Switch Scene (⌘L), like the Mac's app switcher (⌘Tab): the scenes you had open, most
/// recent first, then the rest of the book, as cards. Hold ⌘ and press L to move along; let go
/// of ⌘ to open the chosen one, so a quick ⌘L goes back to the scene before. ← → move too,
/// Return opens, Esc cancels, a click opens. Opened from the menu with the mouse, it stays up
/// until Return, a click or Esc.
///
/// With `documents`, Go › Switch Document (⇧⌘L): the same, for every story in the library
/// (any shape, single documents included), the ones you were last in first, as covers on a
/// shelf, chosen the way New Document marks a cover (owner, 2026-11-14). Opening one goes back to where you were in it.
struct SceneSwitcher: View {
    @EnvironmentObject private var store: LibraryStore
    var documents = false
    @State private var chosen = 0
    @State private var cards: [Card] = []
    /// ⌘ was held as it opened: letting go chooses.
    @State private var holding = NSApp.currentEvent?.modifierFlags.contains(.command) ?? NSEvent.modifierFlags.contains(.command)

    struct Card: Identifiable {
        var id: URL { url }
        /// A scene, or a story's folder.
        let url: URL
        let title: String
        /// "2.1": the chapter's number and the scene's place in it.
        let number: String
        let chapter: String
        let synopsis: String
        let words: Int
        /// A story's cover picture (documents only).
        var cover: NSImage? = nil
        /// Its form, for the colour of a blank cover.
        var form: BookForm? = nil
        var collection: Bool? = nil
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 12) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: documents ? Self.shelfGap : 10) {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                                Group {
                                    if documents { bookView(card, selected: index == chosen) } else { cardView(card, selected: index == chosen) }
                                }
                                .id(index)
                                .onTapGesture { chosen = index; open() }
                            }
                        }
                        .padding(documents ? Self.shelfInset : 14)
                    }
                    .scrollIndicators(.never)
                    .background(alignment: .top) { if documents { shelf } }
                    .onChange(of: chosen) { _, index in
                        withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(index, anchor: .center) }
                    }
                }
                HStack(spacing: 14) {
                    KeyHint(keys: documents ? [.symbol("shift"), .symbol("command"), .letter("L")] : [.symbol("command"), .letter("L")],
                            label: "Next")
                    KeyHint(keys: [.symbol("arrow.left"), .symbol("arrow.right")], label: "Move")
                    KeyHint(keys: [.symbol("return")], label: "Open")
                    KeyHint(keys: [.text("Esc")], label: "Cancel")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: 860)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(PaperTheme.chrome), in: rounded(Layout.panelRadius))
            .roundedFrame(Color(PaperTheme.frame), radius: Layout.panelRadius)
            .padding(40)
        }
        .background(KeyCatcher(onKey: key, onCommandUp: { if holding { open() } }))
        .onAppear {
            load()
            // A tap too quick to see: ⌘ was let go before the switcher could listen.
            DispatchQueue.main.async {
                if holding, !NSEvent.modifierFlags.contains(.command), !(NSApp.currentEvent?.modifierFlags.contains(.command) ?? false) {
                    open()
                }
            }
        }
    }

    private static let shelfGap: CGFloat = 16
    private static let coverWidth: CGFloat = 98
    private static let shelfInset: CGFloat = 18
    private static let shelfRoom: CGFloat = 4

    /// The board the covers stand on: a hairline the panel's width, just under the covers.
    private var shelf: some View {
        Rectangle()
            .fill(Color(PaperTheme.frame))
            .frame(height: 1)
            .padding(.top, Self.shelfInset + Self.coverWidth * 1.6 + 10 + Self.shelfRoom / 2)
            .padding(.horizontal, Self.shelfInset)
    }

    /// A story on the shelf: its cover as the Library shows it, standing on a
    /// hairline shelf, then its name underneath (no word count, owner 2026-11-14). Chosen as New Document marks a cover.
    private func bookView(_ card: Card, selected: Bool) -> some View {
        VStack(spacing: 0) {
            // The cover the Library shows, picture or letter (owner, 2026-11-14).
            BookCover(title: card.title, image: card.cover, width: Self.coverWidth, form: card.form, collection: card.collection)
            .overlay(rounded(Layout.radius).strokeBorder(Color(selected ? PaperTheme.ink : PaperTheme.frame), lineWidth: selected ? 2 : 1))
            .padding(5)
            .background(rounded(Layout.radius + 2).fill(Color(selected ? PaperTheme.selection : .clear)))
            // Room for the shelf (`shelf`), drawn once across the whole panel.
            Color.clear.frame(height: Self.shelfRoom)
            Text(card.title)
                .font(.system(size: Layout.detailSize, weight: .medium))
                .foregroundStyle(Color(selected ? PaperTheme.ink : PaperTheme.secondary))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .padding(.top, 8)
            .frame(width: 108)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cardView(_ card: Card, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !card.number.isEmpty { Badge(card.number) }
                Text(card.chapter)
                    .font(.system(size: Layout.smallSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .lineLimit(1)
            }
            Text(card.title)
                .font(.system(size: Layout.chromeSize, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.ink))
                .lineLimit(2)
            Text(card.synopsis)
                .font(.system(size: Layout.detailSize))
                .foregroundStyle(Color(PaperTheme.secondary))
                .lineLimit(3)
                .padding(.top, 2)
            Spacer(minLength: 0)
            Badge(Estimate.words(card.words))
        }
        .padding(12)
        .frame(width: 180, height: 136, alignment: .topLeading)
        .background(Color(PaperTheme.card), in: rounded(Layout.radius))
        .overlay(rounded(Layout.radius).strokeBorder(Color(selected ? PaperTheme.accent : PaperTheme.cardBorder), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }

    private func load() {
        if documents { return loadDocuments() }
        guard let library = store.library else { return }
        var all: [URL: (Scene, Chapter)] = [:]
        for book in library.books { for chapter in book.chapters { for scene in chapter.scenes { all[scene.url] = (scene, chapter) } } }
        var order = store.recentScenes.filter { all[$0] != nil }
        // Then the rest of the open book, in order, so there is always somewhere to go.
        if case .scene(let url) = store.selection, let book = store.location(ofScene: url)?.book {
            for scene in book.chapters.flatMap(\.scenes) where !order.contains(scene.url) { order.append(scene.url) }
        }
        cards = order.prefix(16).compactMap { url in
            guard let (scene, chapter) = all[url] else { return nil }
            return Card(url: url, title: scene.title, number: store.number(ofScene: url) ?? "", chapter: chapter.title,
                        synopsis: store.margin.info(for: url).synopsis, words: store.wordCount(of: scene))
        }
        chosen = cards.count > 1 ? 1 : 0
    }

    /// Every story: the open one, then the ones whose scenes were open most recently, then
    /// the rest in the library's order. The one before is chosen, as with scenes.
    private func loadDocuments() {
        guard let library = store.library else { return }
        var order: [URL] = []
        if let open = store.openBook { order.append(open) }
        for scene in store.recentScenes {
            if let book = store.location(ofScene: scene)?.book.url, !order.contains(book) { order.append(book) }
        }
        for book in library.books where !order.contains(book.url) { order.append(book.url) }
        let folders = Dictionary(library.folders.map { ($0.url, $0.title) }, uniquingKeysWith: { first, _ in first })
        cards = order.prefix(16).compactMap { url in
            guard let book = library.books.first(where: { $0.url == url }) else { return nil }
            let info = store.margin.info(for: url)
            return Card(url: url, title: book.title, number: info.stage?.title ?? "",
                        chapter: book.folder.flatMap { folders[$0] } ?? "",
                        synopsis: info.synopsis, words: store.wordCount(of: book), cover: store.margin.cover(of: url), form: info.form, collection: info.collection)
        }
        chosen = cards.count > 1 && store.openBook != nil ? 1 : 0
    }

    private func move(_ step: Int) {
        guard !cards.isEmpty else { return }
        chosen = (chosen + step + cards.count) % cards.count
    }

    /// Returns true when the key was used.
    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: close(); return true                       // Esc
        case 36, 76: open(); return true                    // Return, Enter
        case 123: move(-1); return true                     // ←
        case 124: move(1); return true                      // →
        default: break
        }
        if event.charactersIgnoringModifiers?.lowercased() == "l", flags.contains(.command) {
            // Scenes: ⇧ goes back. Documents are ⇧⌘L already, so L always goes on.
            move(flags.contains(.shift) && !documents ? -1 : 1)
            return true
        }
        return false
    }

    private func open() {
        guard cards.indices.contains(chosen) else { return close() }
        let url = cards[chosen].url
        close()
        if documents { store.openDocument(url) } else { store.selection = .scene(url) }
    }

    private func close() {
        if documents { store.documentSwitcherShown = false } else { store.switcherShown = false }
    }
}

/// Catches keys (and ⌘ being let go) for the window while the switcher is up.
private struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    let onCommandUp: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        view.onCommandUp = onCommandUp
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
        view.onCommandUp = onCommandUp
    }

    final class CatcherView: NSView {
        var onKey: (NSEvent) -> Bool = { _ in false }
        var onCommandUp: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.type == .flagsChanged {
                    // Modifier changes may come without a window: any while ours is in front.
                    if window.isKeyWindow || event.window === window, !event.modifierFlags.contains(.command) {
                        self.onCommandUp()
                    }
                    return event
                }
                guard event.window === window else { return event }
                return self.onKey(event) ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.removeFromSuperview()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - Keys drawn as key caps

/// A key on a key cap: an SF Symbol (⌘ ⌥ ⌃ ⇧ arrows ↩), a letter, or a word ("esc").
enum Key: Hashable {
    case symbol(String)
    case letter(String)
    case text(String)

    /// A shortcut written as the menus write it ("⇧⌘F") as key caps: one box per key, the
    /// modifier keys and Return as SF Symbols. Only for code; the screen never shows the glyphs.
    static func caps(_ shortcut: String) -> [Key] {
        shortcut.map { glyph -> Key in
            switch glyph {
            case "⌘": return .symbol("command")
            case "⇧": return .symbol("shift")
            case "⌥": return .symbol("option")
            case "⌃": return .symbol("control")
            case "↩": return .symbol("return")
            case "+": return .symbol("plus")
            case "−", "-": return .symbol("minus")
            case "↑": return .symbol("arrow.up")
            case "↓": return .symbol("arrow.down")
            default: return .letter(String(glyph))
            }
        }
    }
}

/// A key cap: a small rounded box with the key in it.
struct KeyCap: View {
    let key: Key

    var body: some View {
        Group {
            switch key {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 10, weight: .semibold))
            case .letter(let letter):
                Text(letter).font(.system(size: 11, weight: .semibold))
            case .text(let word):
                Text(word).font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(Color(PaperTheme.ink))
        .frame(minWidth: 20, minHeight: 20)
        .padding(.horizontal, key.isWide ? 4 : 0)
        .background(Color(PaperTheme.controlFill), in: rounded(Layout.smallRadius + 1))
        .overlay(rounded(Layout.smallRadius + 1).strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
    }
}

private extension Key {
    var isWide: Bool { if case .text = self { return true }; return false }
}

/// Key caps for a shortcut, then what it does.
struct KeyHint: View {
    let keys: [Key]
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { KeyCap(key: $0) } }
            Text(label)
                .font(.system(size: Layout.detailSize, weight: .medium))
                .foregroundStyle(Color(PaperTheme.secondary))
        }
    }
}
