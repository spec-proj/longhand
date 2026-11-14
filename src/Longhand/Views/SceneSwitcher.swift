import SwiftUI
import AppKit

/// Go › Switch Scene (⌘L), like the Mac's app switcher (⌘Tab): the scenes you had open, most
/// recent first, then the rest of the book, as cards. Hold ⌘ and press L to move along; let go
/// of ⌘ to open the chosen one, so a quick ⌘L goes back to the scene before. ← → move too,
/// Return opens, Esc cancels, a click opens. Opened from the menu with the mouse, it stays up
/// until Return, a click or Esc.
struct SceneSwitcher: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var chosen = 0
    @State private var cards: [Card] = []
    /// ⌘ was held as it opened: letting go chooses.
    @State private var holding = NSApp.currentEvent?.modifierFlags.contains(.command) ?? NSEvent.modifierFlags.contains(.command)

    struct Card: Identifiable {
        var id: URL { url }
        let url: URL
        let title: String
        /// "2.1": the chapter's number and the scene's place in it.
        let number: String
        let chapter: String
        let synopsis: String
        let words: Int
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 12) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                                cardView(card, selected: index == chosen)
                                    .id(index)
                                    .onTapGesture { chosen = index; open() }
                            }
                        }
                        .padding(14)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: chosen) { _, index in
                        withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(index, anchor: .center) }
                    }
                }
                HStack(spacing: 14) {
                    KeyHint(keys: [.symbol("command"), .letter("L")], label: "Next")
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
            move(flags.contains(.shift) ? -1 : 1)
            return true
        }
        return false
    }

    private func open() {
        guard cards.indices.contains(chosen) else { return close() }
        let url = cards[chosen].url
        close()
        store.selection = .scene(url)
    }

    private func close() {
        store.switcherShown = false
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
