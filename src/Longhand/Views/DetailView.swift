import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var store: LibraryStore
    /// Chapters and books show as cards rather than pages.
    @AppStorage("showCards") private var showCards = false
    @AppStorage(StoryPage.key) private var storyPage = false

    var body: some View {
        Group {
            switch store.selection {
            case .scene(let url):
                if let scene = store.scene(for: url), let version = store.historyPreview {
                    HistoryPreview(scene: scene, version: version)
                } else if let scene = store.scene(for: url) {
                    SceneEditorView(scene: scene)
                } else {
                    EmptyDetail(message: "This scene no longer exists.")
                }

            case .chapter(let url):
                if let chapter = store.chapter(for: url), showCards {
                    ChapterCardsView(chapter: chapter)
                } else if let chapter = store.chapter(for: url) {
                    // One page for every chapter: switching chapters, or adding, renaming or
                    // moving a scene, reloads it from the files (see `onChange` below) rather
                    // than building a new text view.
                    ChapterDocumentView(chapter: chapter)
                } else {
                    EmptyDetail(message: "This chapter no longer exists.")
                }

            case .book(let url):
                // In the Library, a book shows its Book Info page; inside it, the book as
                // cards (or, with Page chosen, its contents page).
                if let book = store.book(for: url), store.openBook == nil {
                    BookInfoPage(book: book)
                } else if let book = store.book(for: url), showCards {
                    BookCardsView(book: book)
                } else if let book = store.book(for: url), storyPage {
                    StoryPage(book: book)
                } else if let book = store.book(for: url) {
                    BookOverview(book: book)
                } else {
                    EmptyDetail(message: "This story no longer exists.")
                }

            case nil:
                EmptyDetail(message: "")
            }
        }
        .background(Color(PaperTheme.paper))
    }
}

/// Centres the writing column in whatever width the pane has.
private struct Column<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content.frame(maxWidth: Layout.column)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Scene editor

struct SceneEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    /// Handed to the page, not watched: the page itself redraws its comments, and watching
    /// the margin redrew this view (and the page) on every comment or note change.
    private var margin: MarginStore { store.margin }
    let scene: Scene

    var body: some View {
        VStack(spacing: 0) {
            if let location = store.location(ofScene: scene.url) {
                SceneHeader(scene: scene, book: location.book)
                    .deskFade(store.deskCleared)
            }
            Column {
                MarkdownEditor(
                    text: store.text,
                    version: store.textVersion,
                    scene: scene.url,
                    margin: margin,
                    changes: store.versions.changes,
                    places: store.places,
                    onChange: { store.updateText($0, fromEditor: true, version: $1) }
                )
                // One editor for every scene: switching swaps its text (and clears its undo)
                // rather than building a new text view and laying out the window again.
            }
        }
    }
}

/// The scene page's header: the scene's name, in line with the prose. Click it for a menu of the
/// book's scenes, by chapter; with the pointer over the row, ‹ › go to the scene before or
/// after (across chapters). 32pt with a hairline, like the contents' and margin's headers.
struct SceneHeader: View {
    @EnvironmentObject private var store: LibraryStore
    let scene: Scene
    let book: Book
    /// `LONGHAND_HOVER=1` shows the arrows in screenshots, as if the pointer were over the row.
    @State private var hovering = ProcessInfo.processInfo.environment["LONGHAND_HOVER"] == "1"

    private var order: [Scene] { book.chapters.flatMap(\.scenes) }
    private var index: Int? { order.firstIndex { $0.url == scene.url } }
    private var previous: Scene? { index.flatMap { $0 > 0 ? order[$0 - 1] : nil } }
    private var next: Scene? { index.flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil } }

    var body: some View {
        VStack(spacing: 0) {
            Column {
                HStack(spacing: 6) {
                  if book.shape == .document {
                    // One document: its story's name, and nowhere else to go.
                    Text(book.title)
                        .font(.system(size: Layout.chromeSize, weight: .semibold))
                        .foregroundStyle(Color(PaperTheme.ink))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                  } else {
                    Menu {
                        switch book.shape {
                        case .scenes, .chapters:
                            // One level: the story's scenes, or its chapters (each its own file).
                            ForEach(Array(order.enumerated()), id: \.element.id) { place, item in
                                Toggle("\(place + 1)  \(title(of: item))", isOn: Binding(
                                    get: { item.url == scene.url },
                                    set: { if $0 { store.selection = .scene(item.url) } }))
                            }
                        default:
                            ForEach(Array(book.chapters.enumerated()), id: \.element.id) { number, chapter in
                                Section("\(number + 1)  \(chapter.title)") {
                                    ForEach(Array(chapter.scenes.enumerated()), id: \.element.id) { place, item in
                                        Toggle("\(number + 1).\(place + 1)  \(item.title)", isOn: Binding(
                                            get: { item.url == scene.url },
                                            set: { if $0 { store.selection = .scene(item.url) } }))
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if let number = store.number(ofScene: scene.url) { Badge(number) }
                            Text(title(of: scene))
                                .font(.system(size: Layout.chromeSize, weight: .semibold))
                                .foregroundStyle(Color(PaperTheme.ink))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Symbol.caretDown.view(size: 9, weight: .semibold)
                                .foregroundStyle(Color(PaperTheme.secondary))
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    // Its own width, but never wider than the header: a long title is cut
                    // with an ellipsis instead of pushing the page into the gutters.
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Go to another \(part) in this story")
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        step(.back, to: previous, help: "Previous \(part)")
                        step(.caretRight, to: next, help: "Next \(part)")
                    }
                    .opacity(hovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                  }
                }
                .padding(.horizontal, Layout.proseInset)
                .frame(maxHeight: .infinity)
            }
            .frame(height: Layout.headerHeight)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
        }
    }

    /// What one step goes to: a scene, or a chapter in a chapters-only story (a notebook's note
    /// or folder).
    private var part: String {
        let names = store.names(of: book.url)
        return (book.shape == .chapters ? names.chapter : names.scene).lowercased()
    }

    /// A chapters-only story's file is named for its chapter, but the chapter's own name is
    /// the one shown (renaming the chapter renames both).
    private func title(of item: Scene) -> String {
        guard book.shape == .chapters else { return item.title }
        return book.chapters.first { $0.scenes.contains { $0.url == item.url } }?.title ?? item.title
    }

    private func step(_ icon: Symbol, to target: Scene?, help: String) -> some View {
        Button {
            if let target { store.selection = .scene(target.url) }
        } label: {
            icon.view(size: 11, weight: .semibold)
                .foregroundStyle(Color(PaperTheme.secondary))
        }
        .buttonStyle(PlainSquareButtonStyle(height: 24, horizontalPadding: 0))
        .frame(width: 24)
        .disabled(target == nil)
        .help(target.map { "\(help): \($0.title)" } ?? help)
    }
}

/// The chapter page's header, like the scene's: the chapter's number and name. Click for a
/// menu of the story's chapters; with the pointer over the row, ‹ › go to the chapter before
/// or after.
struct ChapterHeader: View {
    @EnvironmentObject private var store: LibraryStore
    let chapter: Chapter
    let book: Book
    @State private var hovering = ProcessInfo.processInfo.environment["LONGHAND_HOVER"] == "1"

    private var index: Int? { book.chapters.firstIndex { $0.url == chapter.url } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Menu {
                        ForEach(Array(book.chapters.enumerated()), id: \.element.id) { number, item in
                            Toggle("\(number + 1)  \(item.title)", isOn: Binding(
                                get: { item.url == chapter.url },
                                set: { if $0 { store.selection = .chapter(item.url) } }))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if let number = store.shownNumber(ofChapter: chapter.url) { Badge("\(number)") }
                            Text(chapter.title)
                                .font(.system(size: Layout.chromeSize, weight: .semibold))
                                .foregroundStyle(Color(PaperTheme.ink))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Symbol.caretDown.view(size: 9, weight: .semibold)
                                .foregroundStyle(Color(PaperTheme.secondary))
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Go to another \(store.names(of: book.url).chapter.lowercased())")
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        step(.back, by: -1, help: "Previous \(store.names(of: book.url).chapter.lowercased())")
                        step(.caretRight, by: 1, help: "Next \(store.names(of: book.url).chapter.lowercased())")
                    }
                    .opacity(hovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                }
                .padding(.horizontal, Layout.proseInset)
                .frame(maxWidth: Layout.column, maxHeight: .infinity)
                Spacer(minLength: 0)
            }
            .frame(height: Layout.headerHeight)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
        }
    }

    private func step(_ icon: Symbol, by offset: Int, help: String) -> some View {
        let target = index.flatMap { book.chapters.indices.contains($0 + offset) ? book.chapters[$0 + offset] : nil }
        return Button {
            if let target { store.selection = .chapter(target.url) }
        } label: {
            icon.view(size: 11, weight: .semibold)
                .foregroundStyle(Color(PaperTheme.secondary))
        }
        .buttonStyle(PlainSquareButtonStyle(height: 24, horizontalPadding: 0))
        .frame(width: 24)
        .disabled(target == nil)
        .help(target.map { "\(help): \($0.title)" } ?? help)
    }
}

/// The row across the top of the page: what the open page belongs to (a scene's chapter, a
/// chapter's book), set in line with the prose. 32pt with a hairline, like the contents'
/// header and the margin's tabs, so the three lines meet across the window. Click to go there.
struct PageHeader: View {
    let label: String?
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Column {
                Button(action: action) {
                    HStack(spacing: 8) {
                        if let label {
                            Text(label).foregroundStyle(Color(PaperTheme.secondary))
                        }
                        Text(title)
                            .fontWeight(.medium)
                            .foregroundStyle(Color(hovering ? PaperTheme.accent : PaperTheme.ink))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: Layout.chromeSize))
                    .padding(.horizontal, Layout.proseInset)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(help)
            }
            .frame(height: Layout.headerHeight)
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
        }
    }
}

// MARK: - Chapter as one document

struct ChapterDocumentView: View {
    @EnvironmentObject private var store: LibraryStore
    /// Handed to the page, not watched: the page itself redraws its comments, and watching
    /// the margin redrew this view (and the page) on every comment or note change.
    private var margin: MarginStore { store.margin }
    let chapter: Chapter

    /// The scenes' texts, and which scenes they are, read from disk when the chapter (or its
    /// list of scenes) changes.
    @State private var loaded: (key: [URL], scenes: [ChapterSceneText]) = ([], [])
    /// Read (set like the book) or Write (the same chapter, editable): the toolbar's switch.
    @AppStorage(ChapterDocumentView.readingKey) private var reading = true
    static let readingKey = "chapterReading"

    private var key: [URL] { [chapter.url] + chapter.scenes.map(\.url) }

    /// Never a new title over the last chapter's text: until `load` has run for this chapter
    /// (just after a switch), its texts are read here, once.
    private var scenes: [ChapterSceneText] {
        loaded.key == key ? loaded.scenes : texts()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let book = store.library?.books.first(where: { $0.chapters.contains { $0.url == chapter.url } }) {
                ChapterHeader(chapter: chapter, book: book)
                    .deskFade(store.deskCleared)
            }
            if chapter.scenes.isEmpty {
                empty
            } else {
                Column {
                    if reading {
                        ChapterReader(title: chapter.title, number: openerNumber, scenes: scenes, margin: margin)
                    } else {
                    ChapterEditor(
                        chapter: chapter.url,
                        title: chapter.title,
                        number: openerNumber,
                        scenes: scenes,
                        margin: margin,
                        changes: store.versions.changes,
                        places: store.places,
                        onEdit: { url, text in store.updateChapterScene(url, text: text) }
                    )
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.reloadCount) { load() }
        .onChange(of: key) { load() }
        // Either way shows what is on disk: write out anything typed, then read it again.
        .onChange(of: reading) { store.saveNow(); load() }
    }

    /// The names in this chapter's story (a notebook: folders and notes).
    private var names: PartNames { store.names(of: chapter.url.deletingLastPathComponent().canonical) }
    /// "Chapter 2" above the title; a notebook's folder has its title alone.
    private var openerNumber: Int? { names == .notebook ? nil : store.shownNumber(ofChapter: chapter.url) }

    private var empty: some View {
        VStack(spacing: 10) {
            Text("No \(names.scenes.lowercased()) yet")
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.secondary))
            Button("New \(names.scene)") {
                store.selection = .chapter(chapter.url)
                store.createSceneInContext()
            }
            .buttonStyle(SquareButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        loaded = (key, texts())
    }

    private func texts() -> [ChapterSceneText] {
        chapter.scenes.enumerated().map { index, scene in
            ChapterSceneText(id: index, url: scene.url, title: scene.title, text: store.fileText(at: scene.url))
        }
    }
}

// MARK: - The whole story

/// A story's Page (owner, 2026-11-13): the whole story to read, end to end, read only. Its
/// title and author, then every chapter set as its Read view sets it, comments included.
struct StoryPage: View {
    @EnvironmentObject private var store: LibraryStore
    private var margin: MarginStore { store.margin }
    @ObservedObject private var authors = AuthorProfiles.shared
    let book: Book

    /// Contents (false) or Page (true), beside Cards.
    static let key = "storyPage"

    /// The texts, read from disk when the story or its chapters change.
    @State private var loaded: (key: [URL], chapters: [ReadingChapter]) = ([], [])

    private var key: [URL] { [book.url] + book.chapters.flatMap { [$0.url] + $0.scenes.map(\.url) } }

    private var chapters: [ReadingChapter] { loaded.key == key ? loaded.chapters : texts() }

    private var heading: StoryHeading {
        let info = margin.info(for: book.url)
        let byline = authors.profile(info.authorProfile)?.byline
            ?? [info.authorPenName, info.authorName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return StoryHeading(title: book.title, byline: byline)
    }

    var body: some View {
        Group {
            if book.chapters.allSatisfy(\.scenes.isEmpty) {
                Text("Nothing written yet")
                    .font(.system(size: Layout.chromeSize))
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Column {
                    ChapterReader(story: chapters, heading: heading, margin: margin)
                }
            }
        }
        .onAppear { store.saveNow(); load() }
        .onChange(of: store.reloadCount) { load() }
        .onChange(of: key) { load() }
    }

    private func load() { loaded = (key, texts()) }

    private func texts() -> [ReadingChapter] {
        var id = 0
        return book.chapters.map { chapter in
            ReadingChapter(title: chapter.title, number: store.names(of: book.url) == .notebook ? nil : store.shownNumber(ofChapter: chapter.url), scenes: chapter.scenes.map { scene in
                defer { id += 1 }
                return ChapterSceneText(id: id, url: scene.url, title: scene.title, text: store.fileText(at: scene.url))
            })
        }
    }
}

// MARK: - Book overview

/// The book's contents page: the title as an opener, then each chapter with its scenes
/// beneath, like the contents of a printed book. Everything is clickable.
struct BookOverview: View {
    @EnvironmentObject private var store: LibraryStore
    let book: Book

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Column {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(book.title)
                            .font(Font(EditorFont.serif(32)))
                            .foregroundStyle(Color(PaperTheme.ink))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 64)
                            .padding(.bottom, 16)
                        BookProgress(book: book)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 32)

                        ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                            chapterEntry(chapter, number: index + 1)
                        }

                        if book.chapters.isEmpty {
                            Text("No \(store.names(of: book.url).chapters.lowercased()) yet")
                                .font(.system(size: Layout.chromeSize))
                                .foregroundStyle(Color(PaperTheme.secondary))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Layout.proseInset)
                    .padding(.bottom, 48)
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func chapterEntry(_ chapter: Chapter, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.selection = .chapter(chapter.url)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // The number hangs in the margin, so titles share the prose edge.
                    if store.shownNumber(ofChapter: chapter.url) != nil {
                        Text("\(number)")
                            .font(.system(size: 15).monospacedDigit())
                            .foregroundStyle(Color(PaperTheme.secondary))
                            .frame(width: Layout.hang, alignment: .leading)
                            .padding(.leading, -Layout.hang)
                    }
                    Text(chapter.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(PaperTheme.ink))
                    Spacer(minLength: 12)
                    Badge(store.wordCount(of: chapter).formatted())
                        .help(Estimate.words(store.wordCount(of: chapter)))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(chapter.title)")

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(chapter.scenes.enumerated()), id: \.element.id) { place, scene in
                    Button {
                        store.selection = .scene(scene.url)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if store.shownNumber(ofChapter: chapter.url) != nil {
                                Text("\(number).\(place + 1)")
                                    .font(.system(size: Layout.smallSize).monospacedDigit())
                                    .foregroundStyle(Color(PaperTheme.tertiary))
                                    .frame(minWidth: 26, alignment: .leading)
                            }
                            Text(scene.title)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(PaperTheme.secondary))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(scene.title)")
                }
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(PaperTheme.hairline))
                .frame(height: 1)
        }
    }
}

// MARK: - Status bar

/// The bar along the foot of the window, Classic Mac style: what's open and its count on the
/// left (click to cycle words, reading time and characters; the choice is remembered), and
/// the chapter and book it belongs to on the right, with the book's target if it has one.
struct StatusBar: View {
    @EnvironmentObject private var store: LibraryStore
    /// Book targets, copied from the margin store when they change, so the bar doesn't
    /// redraw on every other margin change (comment focus, notes).
    @State private var targets: [URL: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(PaperTheme.frame)).frame(height: 1)
            HStack(spacing: 6) {
                // What's open keeps its count in full; the chapter and book give way first.
                leading
                    .layoutPriority(1)
                Spacer(minLength: 12)
                // Chapter and book totals are in the contents; here only where you are in
                // the versions.
                if store.libraryURL != nil {
                    GitStatus(changes: store.versions.changes)
                        .layoutPriority(1)
                    SyncItem(versions: store.versions, sync: store.versions.sync, changes: store.versions.changes)
                }
            }
            .font(.system(size: Layout.detailSize, weight: .medium).monospacedDigit())
            .foregroundStyle(Color(PaperTheme.secondary))
            .padding(.horizontal, 14)
            .frame(height: Layout.statusHeight - 1)
        }
        .background(Color(PaperTheme.chrome))
        .onReceive(store.margin.$infos) { infos in
            let now = infos.compactMapValues { $0.target }
            if now != targets { targets = now }
        }
    }

    /// View › Show Word Count: the count at the left of the status bar, on or off.
    @AppStorage(StatusBar.countKey) private var showCount = true
    static let countKey = "showWordCount"

    @ViewBuilder
    private var leading: some View {
        if showCount { count }
    }

    @ViewBuilder
    private var count: some View {
        switch store.selection {
        case .scene(let url):
            if let scene = store.scene(for: url) {
                SceneCount(title: scene.title, live: store.live)
            }
        case .chapter(let url):
            if let chapter = store.chapter(for: url) {
                CycleCount(title: chapter.title, words: store.wordCount(of: chapter), characters: nil)
            }
        case .book(let url):
            if let book = store.book(for: url) {
                HStack(spacing: 7) {
                    Text(book.title).lineLimit(1).truncationMode(.middle)
                    Text(bookWords(book)).lineLimit(1).fixedSize().boxed(height: 18, padding: 7)
                }
            }
        case nil:
            EmptyView()
        }
    }

    /// "175", or "175 of 80,000" when the book has a target.
    private func bookWords(_ book: Book) -> String {
        let words = store.wordCount(of: book).formatted()
        if let goal = targets[book.url], goal > 0 {
            return "\(words) of \(goal.formatted()) words"
        }
        return "\(words) words"
    }
}

/// Where the writer is and what isn't saved as a version yet, like a code editor's branch and
/// changes: the branch, then the words added and cut since your last commit. Watches only
/// the change state, which moves a moment after a save, never on a keystroke. Click for the
/// Git commands. (Where the library stands against GitHub is `SyncItem`, beside it.)
private struct GitStatus: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var changes: ChangeState
    /// The page's change bars (owner, 2026-11-14: a switch here).
    @AppStorage(PageMarks.changeBarsKey) private var changeBars = true

    var body: some View {
        Menu {
            Button("Show Changes") { Commands.showChanges() }
            Button("Commit…") { store.versions.sheet = .save }
            if changes.backup == .none {
                Button("Connect Repository…") { store.versions.sheet = .backup }
            } else {
                Button("Push") { store.saveNow(); store.versions.commitAndPush() }
                Button("Git Activity…") { store.versions.sheet = .backup }
            }
            Divider()
            if changes.branch != nil {
                Button("Switch to main") { store.switchTo(nil) }
            }
            ForEach(store.versions.rewrites.filter { $0.title != changes.branch }) { rewrite in
                Button("Switch to “\(rewrite.title)”") { store.switchTo(rewrite) }
            }
            if changes.branch != nil {
                Button("Merge into main…") { store.versions.confirm = .keep }
                Button("Delete Branch") { store.versions.confirm = .discard }
            } else {
                Button("New Branch…") { store.versions.sheet = .rewrite }
            }
            Button("Compare Commits…") { store.compareVersions() }
            Divider()
            Toggle("Show Change Bars", isOn: $changeBars)
                .onChange(of: changeBars) { _, on in PageMarks.changeBarsOn = on }
        } label: {
            // A diff indicator, as GitHub shows one: ± and the words added and cut since the
            // last version. The rewrite's name only while you're in one.
            let totals = self.totals   // worked out once per draw, not once per number
            HStack(spacing: 0) {
                // One box: the branch ("main", or the open branch's name), then the words
                // added and cut.
                Text(changes.branch ?? "main")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
                    .padding(.horizontal, 7)
                Rectangle().fill(Color(PaperTheme.controlBorder)).frame(width: 1, height: 18)
                // One small rounded badge, as Xcode and GitHub show a diff: for a scene, its
                // last version and the words added and cut since; for a chapter or book, the
                // words changed in its scenes since their versions.
                HStack(spacing: 6) {
                    if let label = sceneLabel {
                        Text(label).foregroundStyle(Color(PaperTheme.secondary))
                        Rectangle().fill(Color(PaperTheme.controlBorder)).frame(width: 1, height: 11)
                    }
                    Text("+\(totals.added.formatted())")
                        .foregroundStyle(Color(totals.added > 0 ? PaperTheme.diffAddedMark : PaperTheme.tertiary))
                    Text("−\(totals.removed.formatted())")
                        .foregroundStyle(Color(totals.removed > 0 ? PaperTheme.diffRemovedMark : PaperTheme.tertiary))
                }
                .font(.system(size: Layout.smallSize, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7)
            }
            .frame(height: 18)
            .background(Color(PaperTheme.controlFill), in: rounded(Layout.smallRadius + 1))
            .overlay(rounded(Layout.smallRadius + 1).strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tooltip)
    }

    /// The changes the badge counts: the open scene's, or those inside the chapter or book.
    private var scope: [Comparison.SceneChange] {
        switch store.selection {
        case .scene(let url): return changes.change(of: url).map { [$0] } ?? []
        case .chapter(let url), .book(let url): return changes.changes(inside: url)
        case nil: return changes.scenes
        }
    }

    private var totals: (added: Int, removed: Int) {
        (scope.reduce(0) { $0 + $1.wordsAdded }, scope.reduce(0) { $0 + $1.wordsRemoved })
    }

    /// "New" for a scene with no commit of yours yet.
    private var sceneLabel: String? {
        guard case .scene(let url) = store.selection else { return nil }
        return changes.label(of: url) == nil ? "New" : nil
    }

    private var tooltip: String {
        var lines: [String] = []
        if case .scene(let url) = store.selection {
            lines.append(changes.label(of: url).map { "Words added and cut since commit \($0)" } ?? "This scene has no commit of yours yet")
        } else {
            let count = scope.filter { !$0.onlyMoved }.count
            lines.append(count == 0 ? "No scene changed since your last commit"
                         : "\(count == 1 ? "1 scene" : "\(count) scenes") changed since your last commits")
        }
        lines.append("Branch: \(changes.branch ?? "main")")
        return lines.joined(separator: "\n")
    }

}

/// The open scene's count, watching only the live counts, so a keystroke redraws this alone.
private struct SceneCount: View {
    let title: String
    @ObservedObject var live: LiveCount

    var body: some View {
        CycleCount(title: title, words: live.words, characters: live.characters)
    }
}

/// "Arrival: 97 words". Clicking cycles words, reading time and characters.
private struct CycleCount: View {
    let title: String
    let words: Int
    let characters: Int?

    @AppStorage("counter") private var counter = 0

    var body: some View {
        Button(action: cycle) {
            // The count is never cut: a long title gives way, in the middle.
            HStack(spacing: 7) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(label)
                    .lineLimit(1)
                    .fixedSize()
                    .boxed(height: 18, padding: 7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(characters == nil ? "Words, pages or reading time" : "Words, pages, reading time or characters")
    }

    private var modes: Int { characters == nil ? 3 : 4 }

    private var label: String {
        switch counter % modes {
        case 1:
            return Estimate.pages(words)
        case 2:
            return Estimate.reading(words)
        case 3:
            return "\((characters ?? 0).formatted()) characters"
        default:
            return Estimate.words(words)
        }
    }

    private func cycle() {
        counter = (counter % modes + 1) % modes
    }
}

struct EmptyDetail: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(Color(PaperTheme.secondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
