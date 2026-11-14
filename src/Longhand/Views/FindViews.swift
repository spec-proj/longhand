import SwiftUI
import AppKit

// MARK: - Command palette

/// ⌘K: type part of a scene, chapter or book title, or of a command, then Return. With
/// nothing typed it lists scenes; commands come up as you type ("new", "focus", "theme").
/// Arrow keys move the choice; Escape or a click outside closes it.
struct QuickOpen: View {
    @EnvironmentObject private var store: LibraryStore
    /// Its group, query and choice: the store's, so a previewed theme (which draws the window
    /// again) leaves the palette as it was.
    @ObservedObject var palette: PaletteState
    @Environment(\.colorScheme) private var scheme

    struct Item: Identifiable {
        let id: String
        let title: String
        /// Where it lives (a scene's chapter), or a command's shortcut.
        let detail: String
        let command: Bool
        /// A group's items (owner, 2026-11-13: "Theme › [list of themes]").
        var children: [Item]? = nil
        /// Ticked: the theme in use, the branch you're on.
        var current = false
        /// A theme: shown with its colours, and previewed while it is the choice.
        var theme: AppTheme? = nil
        var run: @MainActor () -> Void = {}
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dims the window behind, as the cheat sheet does (ink at a low alpha lightened
            // dark pages).
            Color.black.opacity(0.10)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Symbol.search.view(size: 14)
                        .foregroundStyle(Color(PaperTheme.tertiary))
                    if let group = palette.group {
                        // The group you're in, as a framed crumb; click it to go back.
                        Button { back() } label: {
                            Text(group)
                                .font(.system(size: Layout.chromeSize, weight: .medium))
                                .foregroundStyle(Color(PaperTheme.ink))
                                .boxed()
                        }
                        .buttonStyle(.plain)
                        .help("Back to all commands")
                    }
                    KeyField(
                        text: $palette.query,
                        placeholder: palette.group == nil ? "Go to a scene or run a command" : "Choose",
                        size: 15,
                        releasesOnSubmit: true,
                        onSubmit: open,
                        onMove: move,
                        onCancel: { if palette.group != nil { back() } else { close() } },
                        onBackspaceEmpty: { guard palette.group != nil else { return false }; back(); return true },
                        keepsOnSubmit: { matches.indices.contains(palette.chosen) && matches[palette.chosen].children != nil }
                    )
                    .onChange(of: palette.query) { palette.chosen = 0; previewChoice() }
                    .onChange(of: palette.chosen) { previewChoice() }
                    .onChange(of: palette.group) { previewChoice() }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                let items = matches
                if !items.isEmpty {
                    Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
                    // A group can hold more than fits (Theme): it scrolls, nine rows high.
                    ScrollViewReader { scroller in
                    ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                palette.chosen = index
                                open()
                            } label: {
                                HStack {
                                    if palette.group != nil {
                                        Symbol.checkmark.view(size: 11)
                                            .foregroundStyle(Color(PaperTheme.ink))
                                            .opacity(item.current ? 1 : 0)
                                            .frame(width: 14)
                                    }
                                    if let theme = item.theme {
                                        // The theme's own colours (its dark ones in a dark window).
                                        Image(nsImage: ThemeStrip.image(theme, dark: scheme == .dark))
                                    }
                                    Text(item.title)
                                        .foregroundStyle(Color(PaperTheme.ink))
                                        .lineLimit(1)
                                    Spacer(minLength: 12)
                                    if item.children != nil {
                                        Symbol.caretRight.view(size: 11)
                                            .foregroundStyle(Color(PaperTheme.secondary))
                                    } else if item.command {
                                        // The shortcut as key caps, like the cheat sheet's.
                                        HStack(spacing: 3) {
                                            ForEach(Array(Key.caps(item.detail).enumerated()), id: \.offset) { KeyCap(key: $0.element) }
                                        }
                                    } else {
                                        Text(item.detail)
                                            .font(.system(size: Layout.detailSize).monospacedDigit())
                                            .foregroundStyle(Color(PaperTheme.secondary))
                                            .lineLimit(1)
                                    }
                                }
                                .font(.system(size: Layout.chromeSize))
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(index == palette.chosen ? Color(PaperTheme.selection) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { hover(index) } }
                            .id(index)
                        }
                    }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: min(CGFloat(items.count), 9) * 34)
                    .onChange(of: palette.chosen) { _, index in scroller.scrollTo(index) }
                    // Drawn again for a previewed theme: back where the choice was.
                    .onAppear { if palette.chosen > 0 { scroller.scrollTo(palette.chosen) } }
                    }
                }
            }
            .frame(width: 480)
            .background(Color(PaperTheme.card))
            .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
            .padding(.top, 48)
        }
        .onAppear {
            // Drawn again for a previewed theme: the palette stays as it was.
            guard !palette.isOpen else { return }
            palette.isOpen = true
            if let preset = Snapshot.quickQuery {
                // "Theme›" opens that group (pictures).
                if preset.hasSuffix("›") { palette.group = String(preset.dropLast()) } else { palette.query = preset }
            }
        }
    }

    /// The few things worth doing from the keyboard without hunting through the menus. On/off
    /// pairs are one "Toggle" each; long lists (themes, branches) are groups you open.
    private var commands: [Item] {
        let defaults = UserDefaults.standard
        func flip(_ key: String) { defaults.set(!defaults.bool(forKey: key), forKey: key) }
        // The side columns are shown unless switched off.
        func shown(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        func command(_ title: String, _ keys: String = "", _ run: @escaping @MainActor () -> Void) -> Item {
            Item(id: "do:" + title, title: title, detail: keys, command: true, run: run)
        }
        func group(_ title: String, _ items: [Item]) -> Item {
            Item(id: "group:" + title, title: title, detail: "", command: true, children: items)
        }
        let versions = store.versions
        // Inside a story you make scenes and chapters; stories and folders are made in the
        // Library.
        var list: [Item] = store.openBook != nil
            ? [
                command("New Scene", "⌘N") { store.createSceneInContext() },
                command("New Chapter", "⇧⌘N") { store.createChapterInContext() },
                command("Back to Library", "⌘4") { store.openBook = nil },
            ]
            : [
                command("New Story", "⌥⌘N") { store.createBook() },
                command("New Folder") { store.createFolder() },
            ]
        list += [
            command("Switch Scene…", "⌘L") { store.switcherShown = true },
            command("Find in Library…", "⇧⌘F") { store.searchShown = true },
            command("Comment on Selection", "⌘J") { Commands.comment(margin: store.margin) },
        ]
        if store.library?.books.isEmpty == false {
            list.append(command("Export…", "⌘E") { store.exportRequested = true })
        }

        // Views of where you are.
        if case .book = store.selection, store.openBook != nil {
            let page = defaults.bool(forKey: StoryPage.key)
            list.append(command("Toggle Contents / Page", "⌘R") {
                defaults.set(false, forKey: "showCards")
                defaults.set(!page, forKey: StoryPage.key)
            })
        }
        if case .chapter = store.selection {
            let reading = defaults.object(forKey: ChapterDocumentView.readingKey) as? Bool ?? true
            list.append(command("Toggle Read / Write", "⌘R") {
                defaults.set(false, forKey: "showCards")
                defaults.set(!reading, forKey: ChapterDocumentView.readingKey)
            })
        }
        list += [
            command("Toggle Cards", "⌘3") { flip("showCards") },
            command("Toggle Contents Column", "⌘1") { defaults.set(!shown("showSidebar"), forKey: "showSidebar") },
            command("Toggle Margin", "⌘2") { defaults.set(!shown("showMargin"), forKey: "showMargin") },
            command("Toggle Distraction-Free Mode", "⌘.") { store.deskCleared.toggle() },
            command("Toggle Focus", "⌘D") { flip(WritingModes.focusKey) },
            command("Toggle Typewriter Scrolling", "⇧⌘T") { flip(WritingModes.typewriterKey) },
            command("Toggle Word Count") {
                defaults.set(!(defaults.object(forKey: StatusBar.countKey) as? Bool ?? true), forKey: StatusBar.countKey)
            },
            group("Text Size", [
                command("Bigger", "⌘+") { ProseSize.step(1) },
                command("Smaller", "⌘−") { ProseSize.step(-1) },
                command("Actual Size", "⌘0") { ProseSize.step(0) },
            ]),
        ]

        // Looks: one toggle for light and dark (unless the theme is dark only), every theme
        // in a group, the one in use ticked.
        if !AppTheme.current.darkOnly {
            list.append(command("Toggle Dark / Light") {
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                AppTheme.setMode(dark ? "light" : "dark")
            })
        }
        list.append(group("Theme", AppTheme.allCases.map { theme in
            Item(id: "theme:" + theme.rawValue, title: theme.title, detail: "", command: true,
                 current: theme == AppTheme.kept, theme: theme) { AppTheme.choose(theme) }
        }))

        // Git, in the menu's words: what applies to where the writer is now.
        var git: [Item] = [
            command("Commit…", "⇧⌘S") { versions.sheet = .save },
            command("New Tag…") { versions.sheet = .draft },
            command("Show Changes") { Commands.showChanges() },
            command("Compare Commits…", "⇧⌘D") { store.compareVersions() },
        ]
        if versions.currentRewrite == nil {
            git.append(command("New Branch…", "⇧⌘B") { versions.sheet = .rewrite })
        } else {
            git.append(command("Merge into main…") { versions.confirm = .keep })
            git.append(command("Delete Branch") { versions.confirm = .discard })
        }
        if versions.hasBackup {
            git.append(command("Push", "⇧⌘P") { store.saveNow(); versions.commitAndPush() })
            git.append(command("Fetch", "⌥⌘P") { versions.syncNow() })
            git.append(command("Git Activity…") { versions.sheet = .backup })
        } else {
            git.append(command("Connect Repository…") { versions.sheet = .backup })
        }
        list.append(group("Git", git))
        if !versions.rewrites.isEmpty {
            // Named by the branch, not its title: two branches may share a title.
            var branches = [Item(id: "branch:main", title: "main", detail: "", command: true,
                                 current: versions.currentRewrite == nil) { store.switchTo(nil) }]
            for rewrite in versions.rewrites {
                branches.append(Item(id: "branch:" + rewrite.id, title: rewrite.title, detail: "", command: true,
                                     current: rewrite == versions.currentRewrite) { store.switchTo(rewrite) })
            }
            list.append(group("Switch Branch", branches))
        }

        list += [
            command("Cheat Sheet", "⌘/") { store.cheatSheetShown = true },
            command("Git in Four Steps") { store.gitIntroShown = true },
            command("Open Library…", "⌘O") { store.chooseLibrary() },
            command("Show Library in Finder", "⇧⌘R") { store.revealLibrary() },
            command("Settings…", "⌘,") { Commands.openSettings() },
        ]
        return list
    }

    private var places: [Item] {
        guard let library = store.library else { return [] }
        var all: [Item] = []
        func place(_ selection: Selection, _ title: String, _ detail: String) {
            all.append(Item(id: "go:\(selection)", title: title, detail: detail, command: false) { store.selection = selection })
        }
        for book in library.books {
            place(.book(book.url), book.title, "Story")
            for chapter in book.chapters {
                place(.chapter(chapter.url), chapter.title, book.title)
                for scene in chapter.scenes {
                    place(.scene(scene.url), scene.title, "\(book.title) › \(chapter.title)")
                }
            }
        }
        return all
    }

    /// Best matches first: titles that start with the palette.query, then ones whose words start with
    /// its words (in any order), then ones that contain it, then ones that contain its
    /// letters in order. Accents and case are ignored.
    private var matches: [Item] {
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let needle = fold(palette.query.trimmingCharacters(in: .whitespaces))
        // Inside a group: its items, all of them until something is typed.
        if let group = palette.group, let items = commands.first(where: { $0.title == group })?.children {
            guard !needle.isEmpty else { return items }
            return items.filter { fold($0.title).contains(needle) || isSubsequence(needle, of: fold($0.title)) }
        }
        let places = self.places
        guard !needle.isEmpty else {
            // Nothing typed: the scenes last open, then the library's first ones.
            let scenes = places.filter { $0.detail.contains("›") }
            let recent = store.recentScenes.compactMap { url in scenes.first { $0.id == "go:\(Selection.scene(url))" } }
            let rest = scenes.filter { scene in !recent.contains { $0.id == scene.id } }
            return Array((recent + rest).prefix(8))
        }
        let words = needle.split(separator: " ")
        func score(_ item: Item) -> Int? {
            let title = fold(item.title)
            // A command whose name starts with what was typed comes before a place that
            // does ("new" is New Scene, not a scene called News); otherwise places lead.
            if title.hasPrefix(needle) { return item.command ? 0 : 1 }
            let base = item.command ? 1 : 0
            let parts = title.split(separator: " ")
            if words.allSatisfy({ word in parts.contains { $0.hasPrefix(word) } }) { return 2 + base }
            if title.contains(needle) { return 4 + base }
            var rest = Substring(needle)
            for character in title where rest.first == character { rest = rest.dropFirst() }
            return rest.isEmpty ? 6 + base : nil
        }
        // A group's items can be found from the top too ("commit" finds Git › Commit…), except
        // themes: they are chosen only inside Theme (owner, 2026-11-13).
        let commands = self.commands
        let nested = commands.filter { $0.title != "Theme" }.flatMap { parent in
            (parent.children ?? []).map { child in
                Item(id: child.id, title: "\(parent.title) › \(child.title)", detail: child.detail,
                     command: true, current: child.current, theme: child.theme, run: child.run)
            }
        }
        return (places + commands + nested).compactMap { item in score(item).map { (item, $0) } }
            .enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .prefix(9)
            .map(\.element.0)
    }

    private func isSubsequence(_ needle: String, of text: String) -> Bool {
        var rest = Substring(needle)
        for character in text where rest.first == character { rest = rest.dropFirst() }
        return rest.isEmpty
    }

    private func back() {
        palette.group = nil
        palette.query = ""
        palette.chosen = 0
        endPreview()
    }

    /// The choice is a theme: show it (a moment after the choice settles, so running the
    /// arrow down the list doesn't draw every one). Anything else: back to the kept theme.
    private func previewChoice() {
        let items = matches
        let theme = items.indices.contains(palette.chosen) ? items[palette.chosen].theme : nil
        palette.previewTask?.cancel()
        palette.previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, store.quickOpenShown else { return }
            if let theme {
                palette.previewing = true
                AppTheme.preview(theme)
            } else {
                endPreview()
            }
        }
    }

    private func endPreview() {
        palette.previewTask?.cancel()
        if palette.previewing {
            palette.previewing = false
            AppTheme.endPreview()
        }
    }

    /// The pointer over a row makes it the choice, only when the pointer moved (a window drawn
    /// again under a still pointer reports it over a row too).
    private func hover(_ index: Int) {
        let at = NSEvent.mouseLocation
        guard at != palette.pointer else { return }
        palette.pointer = at
        if palette.chosen != index { palette.chosen = index }
    }

    private func move(_ step: Int) {
        let count = matches.count
        guard count > 0 else { return }
        palette.chosen = (palette.chosen + step + count) % count
    }

    private func open() {
        let items = matches
        guard items.indices.contains(palette.chosen) else { return }
        let item = items[palette.chosen]
        if let children = item.children {
            palette.group = item.title
            palette.query = ""
            // Starts on the one in use (the kept theme, the branch you're on).
            palette.chosen = children.firstIndex(where: \.current) ?? 0
            return
        }
        if item.theme != nil {
            // Chosen: kept, not put back.
            palette.previewTask?.cancel()
            palette.previewing = false
        }
        close()
        item.run()
    }

    private func close() {
        store.quickOpenShown = false
    }
}

/// The palette's own state, kept by the store (see `QuickOpen.palette`).
@MainActor
final class PaletteState: ObservableObject {
    @Published var query = ""
    @Published var chosen = 0
    /// The group open (Theme, Text Size, Git …): its items replace the list; ⌫ or Esc goes back.
    @Published var group: String?
    /// Showing a theme that isn't kept: closing or going back puts the kept one back.
    var previewing = false
    var previewTask: Task<Void, Never>?
    var pointer: NSPoint = .zero
    /// Set when the palette opens, cleared when it closes (not when it is drawn again).
    var isOpen = false

    /// The palette closed, however it closed: a theme only previewed is put back, and the
    /// next opening starts empty.
    func finish() {
        previewTask?.cancel()
        if previewing {
            previewing = false
            AppTheme.endPreview()
        }
        query = ""
        chosen = 0
        group = nil
        isOpen = false
        pointer = .zero
    }
}

// MARK: - Find in Library

/// ⇧⌘F: the contents column becomes a search of every scene's text. Results are grouped by
/// scene with a line of context; choosing one opens the scene with the words selected.
struct LibrarySearch: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    @State private var query = ""
    @State private var results: [Group] = []
    @State private var texts: [(scene: Scene, chapter: String, text: NSString)] = []
    @State private var searchTask: Task<Void, Never>?

    struct Hit: Identifiable {
        let id: Int
        let range: NSRange
        let before: String
        let match: String
        let after: String
    }

    struct Group: Identifiable {
        var id: URL { scene.url }
        let scene: Scene
        let chapter: String
        let hits: [Hit]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Symbol.search.view(size: 13)
                    .foregroundStyle(Color(PaperTheme.tertiary))
                KeyField(
                    text: $query,
                    placeholder: "Find in Library",
                    size: Layout.chromeSize,
                    onCancel: { store.searchShown = false }
                )
                if !query.isEmpty {
                    Badge("\(results.reduce(0) { $0 + $1.hits.count })")
                }
                Button {
                    store.searchShown = false
                } label: {
                    Symbol.close.view(size: 12)
                }
                .buttonStyle(PlainSquareButtonStyle(height: 22, horizontalPadding: 0))
                .help("Close (Esc)")
            }
            // A 32pt header row, in line with the page's and the margin's.
            .padding(.horizontal, 8)
            .frame(height: Layout.headerHeight - 8)
            .background(Color(PaperTheme.card))
            .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
            .padding(.horizontal, 6)
            .frame(height: Layout.headerHeight)

            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { group in
                        HStack(spacing: 6) {
                            if let number = store.number(ofScene: group.scene.url) { Badge(number) }
                            Text(group.scene.title).fontWeight(.medium)
                            Text(group.chapter)
                                .font(.system(size: Layout.detailSize, weight: .medium))
                                .foregroundStyle(Color(PaperTheme.secondary))
                        }
                        .font(.system(size: Layout.chromeSize))
                        .foregroundStyle(Color(PaperTheme.ink))
                        .lineLimit(1)
                        .padding(.horizontal, Layout.pad)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        ForEach(group.hits) { hit in
                            Button {
                                open(group.scene, at: hit.range)
                            } label: {
                                Text("…\(hit.before)\(Text(hit.match).foregroundColor(Color(PaperTheme.ink)).fontWeight(.semibold))\(hit.after)…")
                                    .font(.system(size: Layout.detailSize))
                                    .foregroundStyle(Color(PaperTheme.secondary))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, Layout.pad + 8)
                                    .padding(.trailing, Layout.pad)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .background(Color(PaperTheme.sidebar))
        .onAppear {
            index()
            if let preset = Snapshot.searchQuery { query = preset }
        }
        .onChange(of: store.reloadCount) { index(); search() }
        .onChange(of: query) { search() }
    }

    /// Reads every scene once when the search opens (and when the library changes).
    private func index() {
        store.saveNow()
        guard let library = store.library else { texts = []; return }
        texts = library.books.flatMap { book in
            book.chapters.flatMap { chapter in
                chapter.scenes.map { (scene: $0, chapter: chapter.title, text: store.fileText(at: $0.url) as NSString) }
            }
        }
    }

    /// Case- and accent-insensitive, a moment after typing stops.
    private func search() {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { results = []; return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var groups: [Group] = []
            var total = 0
            for entry in texts {
                var hits: [Hit] = []
                var range = NSRange(location: 0, length: entry.text.length)
                while total < 500 {
                    let found = entry.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                    guard found.location != NSNotFound else { break }
                    hits.append(hit(hits.count, found, in: entry.text))
                    total += 1
                    let next = NSMaxRange(found)
                    range = NSRange(location: next, length: entry.text.length - next)
                }
                if !hits.isEmpty { groups.append(Group(scene: entry.scene, chapter: entry.chapter, hits: hits)) }
            }
            results = groups
        }
    }

    private func hit(_ id: Int, _ range: NSRange, in text: NSString) -> Hit {
        let start = max(0, range.location - 36)
        let end = min(text.length, NSMaxRange(range) + 60)
        // Context reads as prose: line breaks and Markdown symbols left out.
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "  ", with: " ")
        }
        return Hit(
            id: id,
            range: range,
            before: clean(text.substring(with: NSRange(location: start, length: range.location - start))),
            match: text.substring(with: range),
            after: clean(text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))))
        )
    }

    private func open(_ scene: Scene, at range: NSRange) {
        store.selection = .scene(scene.url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let page = margin.textView, NSMaxRange(range) <= (page.string as NSString).length else { return }
            page.window?.makeFirstResponder(page)
            page.setSelectedRange(range)
            page.scrollRangeToVisible(range)
            page.showFindIndicator(for: range)
        }
    }
}

// MARK: - A field that takes the keyboard

/// A one-line field that takes the keyboard as soon as it is on screen, and hands it back to
/// whatever had it (the page, usually) when it goes. SwiftUI's own focus, asked for as the
/// palette appeared, often lost to the editor's text view: ⌘K opened the palette and typing
/// still went into the scene.
struct KeyField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = Layout.chromeSize
    /// Give the keyboard back before `onSubmit` runs (the palette: the command it runs may
    /// put the keyboard somewhere of its own, which a later hand-back would undo).
    var releasesOnSubmit = false
    var onSubmit: () -> Void = {}
    /// ↓ (1) and ↑ (−1).
    var onMove: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    /// ⌫ in an empty field (the palette: back out of a group). True if it was used.
    var onBackspaceEmpty: () -> Bool = { false }
    /// Asked before Return gives the keyboard back: true keeps it (opening a palette group).
    var keepsOnSubmit: () -> Bool = { false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size)
        field.textColor = PaperTheme.ink
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: PaperTheme.tertiary
        ])
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = text
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: PaperTheme.tertiary
            ])
        }
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        field.handBack()
    }

    final class Field: NSTextField {
        /// What had the keyboard before this field took it.
        private weak var previous: NSResponder?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            take()
            // Again once the window has settled: a view put on screen in the same pass (the
            // page, re-made) may have taken the keyboard after us.
            DispatchQueue.main.async { [weak self] in self?.take() }
        }

        private func take() {
            guard let window, currentEditor() == nil else { return }
            let holder = window.firstResponder
            if let holder, holder !== window, !(holder is NSWindow) {
                // A field's editor is shared; remember the view behind it.
                previous = (holder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : $0 } ?? holder
            }
            window.makeFirstResponder(self)
        }

        /// Gives the keyboard back, if this field still has it.
        func handBack() {
            guard let window, currentEditor() != nil || window.firstResponder === self else { return }
            if let view = previous as? NSView, view.window === window {
                window.makeFirstResponder(view)
            } else {
                window.makeFirstResponder(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyField
        init(_ parent: KeyField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty, parent.onBackspaceEmpty() else { return false }
            case #selector(NSResponder.insertNewline(_:)):
                if parent.releasesOnSubmit, !parent.keepsOnSubmit() { (control as? Field)?.handBack() }
                parent.onSubmit()
            default: return false
            }
            return true
        }
    }
}
