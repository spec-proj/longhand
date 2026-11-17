import SwiftUI

/// The contents column: books as semibold root rows, numbered chapters with a disclosure
/// triangle, scenes beneath. No icons and no section headers. Counts on books and chapters
/// (a scene's count is in its tooltip and the status line); scenes with open comments show
/// how many. At the foot: New scene, and a menu for everything else.
struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    /// Open comments per scene, copied from the margin when they change: watching the whole
    /// margin redrew the contents on every comment focus or note edit.
    @State private var openCounts: [URL: Int] = [:]
    /// Scenes and chapters changed since your last commit, copied the same way.
    @State private var changeMarks: [URL: ChangeState.Kind] = [:]
    @State private var changedChapters: Set<URL> = []
    /// Moves when a cover changes, so rows showing covers draw again.
    @State private var coverVersion = 0
    /// The rows wholly on screen. A plain object, so scrolling doesn't redraw the list.
    @State private var onScreen = RowsOnScreen()
    /// Each book's stage and chapter-number setting, copied from the margin store's details.
    @State private var looks: [URL: Look] = [:]
    /// Scenes' and chapters' statuses (Draft, Revised, Done), copied so rows don't observe the margin.
    @State private var statuses: [URL: SceneInfo.Status] = [:]
    /// The book the contents is inside; empty for the Library (every book). Not a setting:
    /// it follows what is open (a scene or chapter opens its book).
    /// The card chosen on the cards (the margin's scene), copied so rows don't observe the
    /// margin: its row is marked while the cards show.
    @State private var cardFocus: URL?
    /// The Boneyard tab while a card or row is dragged over it.
    @State private var boneyardTargeted = false

    struct Look: Equatable {
        var stage: BookStage?
        var hideNumbers = false
        var form: BookForm?
        var genre: String?
        var collection: Bool?
        /// The author as a blank cover prints them (pen name, else name).
        var byline = ""
    }

    @State private var collapsedChapters: Set<URL> = []
    /// Stories whose Boneyard is open in the contents (folded away until opened).
    @State private var openBoneyards: Set<URL> = []
    /// A single document's headings (owner, 2026-11-14): its outline, in place of chapters.
    @State private var outline: [OutlineHeading] = []
    @State private var collapsedFolders: Set<URL> = []
    @State private var renameFolder: Folder?
    @State private var renameTarget: ManuscriptItem?
    @State private var deleteTarget: ManuscriptItem?
    /// A story waiting for Join into One Document to be confirmed.
    @State private var joinTarget: Book?
    /// The row being dragged, and the row it is over: scenes and chapters are reordered by
    /// dragging, as on the cards.
    @State private var dragging: Selection?
    @State private var dropTarget: Selection?
    /// The chapter whose end a drag is over.
    @State private var endTarget: URL?
    /// The contents has the keyboard (the chosen row is framed).
    @State private var hasKeys = false

    /// Indent per level of the outline (scenes without numbers).
    private let step: CGFloat = 14

    /// How wide a scene's number is in the contents ("12.10").
    static func numberWidth(_ number: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Layout.smallSize, weight: .regular)
        return ceil((number as NSString).size(withAttributes: [.font: font]).width)
    }
    /// Width of the disclosure triangle's cell.
    private let triangle: CGFloat = 20
    /// Width of a chapter's number column.
    private let numberColumn: CGFloat = 20
    /// The rows' first column (the disclosure triangles) starts here, so the triangle sits
    /// on the panel's 12pt edge.
    private var rowLeading: CGFloat { Layout.pad - 2 }
    /// Space between a chapter's number and its title.
    private let numberGap: CGFloat = 7

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
            // Inside a story: Contents | Boneyard.
            if let library = store.library, let book = openBook(in: library) {
                contentsTabs(book)
                Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
            }
            // A plain stack of rows rather than a SwiftUI List: a List re-checked every row of
            // the library on each selection change (several ms on a novel); here only the
            // rows that changed redraw (`OutlineRow` compares by value).
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let library = store.library {
                            if let book = openBook(in: library), store.contentsTab == .boneyard {
                                boneyardList(book)
                            } else if let book = openBook(in: library) {
                                // The book itself is the header above; here its chapters,
                                // a hairline between one chapter and the next.
                                // Scenes only: the story's scenes, numbered 1, 2, 3, with no
                                // chapter above them. One document: nothing (the card opens it).
                                if book.shape == .document, let document = book.document {
                                    ForEach(outline) { heading in
                                        headingRow(heading, in: document.url)
                                    }
                                }
                                if book.shape == .scenes {
                                    let numbered = !hideNumbers(book)
                                    let widest = numbered ? Self.numberWidth("\(book.looseScenes.count)") : 0
                                    ForEach(Array(book.looseScenes.enumerated()), id: \.element.id) { place, scene in
                                        sceneRow(scene, number: numbered ? "\(place + 1)" : nil, numberWidth: widest, flat: true)
                                    }
                                }
                                ForEach(Array(book.chapters.filter { !$0.implicit }.enumerated()), id: \.element.id) { index, chapter in
                                    if index > 0 {
                                        // A little space between chapters, no line (owner,
                                        // 2026-11-14). (The 8pt above is the end of the chapter
                                        // before, where a dragged scene can be dropped.)
                                        Color.clear.frame(height: 4)
                                    }
                                    let numbered = !hideNumbers(book)
                                    if book.shape == .chapters {
                                        // Chapters only: the chapter is its one file.
                                        chapterOnlyRow(chapter, number: numbered ? index + 1 : nil)
                                    } else {
                                        chapterRow(chapter, number: numbered ? index + 1 : nil)
                                    }

                                    if book.shape == .chaptersAndScenes && !collapsedChapters.contains(chapter.url) {
                                        // Numbered by where they sit: 2.1, 2.2. Moving a
                                        // scene renumbers it.
                                        // The widest number in the chapter sets where its scenes'
                                        // titles start, so they share an edge.
                                        let widest = numbered ? Self.numberWidth("\(index + 1).\(chapter.scenes.count)") : 0
                                        ForEach(Array(chapter.scenes.enumerated()), id: \.element.id) { place, scene in
                                            sceneRow(scene, number: numbered ? "\(index + 1).\(place + 1)" : nil, numberWidth: widest)
                                        }
                                    }
                                    endZone(of: chapter, last: index == book.chapters.count - 1)
                                }
                            } else {
                                // Folders first, each a group that opens and closes, then
                                // the stories at the top of the library.
                                ForEach(library.folders) { folder in
                                    folderRow(folder, count: library.books(in: folder.url).count)
                                    if !collapsedFolders.contains(folder.url) {
                                        ForEach(library.books(in: folder.url)) { book in
                                            libraryRow(book).padding(.leading, 14)
                                        }
                                    }
                                    Rectangle()
                                        .fill(Color(PaperTheme.hairline))
                                        .frame(height: 1)
                                        .padding(.leading, Layout.pad)
                                        .padding(.vertical, 6)
                                }
                                ForEach(library.books(in: nil)) { book in
                                    libraryRow(book)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .scrollIndicators(.never)
                .scrollEdgeEffectHidden(true, for: .all)
                .onChange(of: store.selection) { _, selection in
                    // Chosen elsewhere (the palette, a card, the path): go into its book and
                    // bring its row into view.
                    enterBook(of: selection)
                    // Only when it's off screen: asking the list to scroll walks every row
                    // (a quarter of the time it took to open a chapter).
                    if let selection, !onScreen.rows.contains(selection) { reader.scrollTo(selection) }
                }
                .onAppear { enterBook(of: store.selection); refreshOutline() }
                // Rows taken away don't always say they've left the screen.
                .onChange(of: store.openBook) { onScreen.rows.removeAll(); refreshOutline() }
                // The outline follows what is saved (Changes look again after each save).
                .onReceive(store.versions.changes.$generation) { _ in refreshOutline() }
            }
            .overlay {
                if let library = store.library, library.books.isEmpty {
                    emptyState
                }
            }

            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
            bottomBar
        }
        // One panel, header to foot, the same height as the page and the margin. (The
        // rewrite you're in and a failed backup are in the status bar.)
        .background(Color(PaperTheme.well))
        // The contents' keys, while it has the keyboard (Go › Contents, or a click on a row).
        .background(PaneKeys(pane: .contents, store: store, onKey: key, onFocus: { on in
            if hasKeys != on { hasKeys = on }
        }))
        .panel()
        .onReceive(store.margin.$sceneURL) { url in
            // Only while the cards show: switching scenes otherwise needn't redraw the contents.
            let next = store.viewMode == .cards ? url : nil
            if next != cardFocus { cardFocus = next }
        }
        .onReceive(store.margin.$openCounts) { counts in
            if counts != openCounts { openCounts = counts }
        }
        .onReceive(store.versions.changes.$marks) { marks in
            if marks != changeMarks { changeMarks = marks }
        }
        .onReceive(store.versions.changes.$chapterMarks) { chapters in
            if chapters != changedChapters { changedChapters = chapters }
        }
        .onReceive(store.margin.$coverVersion) { version in
            if version != coverVersion { coverVersion = version }
        }
        .onReceive(store.margin.$infos) { infos in
            var next: [URL: Look] = [:]
            for (url, info) in infos {
                let byline = [info.authorPenName, info.authorName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                guard info.stage != nil || info.hideChapterNumbers == true || info.form != nil || !(info.genre ?? "").isEmpty || !byline.isEmpty else { continue }
                next[url] = Look(stage: info.stage, hideNumbers: info.hideChapterNumbers == true, form: info.form, genre: info.genre, collection: info.collection, byline: byline)
            }
            if next != looks { looks = next }
            var marked: [URL: SceneInfo.Status] = [:]
            for (url, info) in infos { if let status = info.status { marked[url] = status } }
            if marked != statuses { statuses = marked }
        }
        .sheet(item: $renameFolder) { folder in
            RenameSheet(title: folder.title) { store.renameFolder(folder.url, to: $0) }
        }
        .sheet(item: $renameTarget) { item in
            RenameSheet(title: item.title) { newTitle in
                store.rename(item, to: newTitle)
            }
        }
        .alert(
            "Join “\(joinTarget?.title ?? "")” into one document?",
            isPresented: Binding(get: { joinTarget != nil }, set: { if !$0 { joinTarget = nil } })
        ) {
            Button("Join") {
                if let book = joinTarget { store.joinIntoOneDocument(book.url) }
                joinTarget = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { joinTarget = nil }
        } message: {
            Text(joinMessage)
        }
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let target = deleteTarget {
                    store.delete(target)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - Rows

    /// One outline row (`OutlineRow`). Its own view, compared by value, so a selection change
    /// redraws the two rows that changed rather than every row in the library.
    private func row<Menu: View>(
        leading: CGFloat,
        number: String?,
        numberWidth: CGFloat = 20,
        numberAlignment: Alignment = .trailing,
        title: String,
        weight: Font.Weight,
        count: Int?,
        comments: Int = 0,
        change: ChangeState.Kind? = nil,
        words: Int? = nil,
        status: SceneInfo.Status? = nil,
        selected: Bool,
        tag: Selection,
        disclosure: (collapsed: Bool, toggle: () -> Void)?,
        @ViewBuilder menu: @escaping () -> Menu
    ) -> some View {
        RowShell(
            row: OutlineRow(
                leading: leading,
                number: number,
                numberWidth: numberWidth,
                numberAlignment: numberAlignment,
                title: title,
                weight: weight,
                count: count,
                comments: comments,
                change: change,
                words: words,
                status: status,
                selected: selected,
                keyed: selected && hasKeys,
                collapsed: disclosure?.collapsed,
                toggle: disclosure?.toggle ?? {},
                triangle: triangle,
                numberGap: numberGap
            ),
            tap: { [store] in
                takeKeys()
                if store.selection != tag { store.selection = tag }
            },
            menu: menu
        )
        .equatable()
        .onScrollVisibilityChange(threshold: 0.9) { [onScreen] visible in
            if visible { onScreen.rows.insert(tag) } else { onScreen.rows.remove(tag) }
        }
        // Drag a scene or chapter to where it should go. A 2px rule shows where it will
        // land: above the row it is over, or under a chapter's row for a scene dropped on
        // the chapter (it becomes the chapter's first scene).
        .onDrag {
            dragging = tag
            return NSItemProvider(object: Self.payload(tag) as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            defer { dragging = nil; dropTarget = nil }
            return drop(items, on: tag)
        } isTargeted: { over in
            if over { dropTarget = tag } else if dropTarget == tag { dropTarget = nil }
        }
        .overlay(alignment: landsBelow(tag) ? .bottom : .top) {
            if dropTarget == tag, dragging != tag, accepts(tag) {
                Rectangle()
                    .fill(Color(PaperTheme.ink))
                    .frame(height: 2)
                    .padding(.horizontal, Layout.pad)
                    .allowsHitTesting(false)
            }
        }
        .id(tag)
    }

    /// The space under a chapter's last scene: drop a scene here to put it last in the
    /// chapter; under the last chapter, drop a chapter here to put it last in the story.
    /// (A row only takes a drop before itself, so without this nothing could go last.)
    private func endZone(of chapter: Chapter, last: Bool) -> some View {
        let tag = Selection.chapter(chapter.url)
        return Color.clear
            .frame(height: last ? 28 : 8)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                defer { dragging = nil; endTarget = nil }
                return dropAtEnd(items, of: chapter, last: last)
            } isTargeted: { over in
                if over { endTarget = chapter.url } else if endTarget == chapter.url { endTarget = nil }
            }
            .overlay(alignment: .top) {
                if endTarget == chapter.url, dragging != tag, last || dragging.map({ if case .scene = $0 { return true } else { return false } }) ?? true {
                    Rectangle()
                        .fill(Color(PaperTheme.ink))
                        .frame(height: 2)
                        .padding(.horizontal, Layout.pad)
                        .allowsHitTesting(false)
                }
            }
    }

    private func dropAtEnd(_ items: [String], of chapter: Chapter, last: Bool) -> Bool {
        guard let item = items.first, let library = store.library else { return false }
        if let dragged = chapterOfFile(item) {
            guard last, dragged.chapter.url != chapter.url else { return false }
            store.placeChapter(dragged.chapter.url, at: dragged.book.chapters.count - 1)
            return true
        }
        if item.hasPrefix("chapter:") {
            let dragged = URL(fileURLWithPath: String(item.dropFirst("chapter:".count))).canonical
            guard last, dragged != chapter.url,
                  let book = library.books.first(where: { $0.chapters.contains { $0.url == dragged } }),
                  book.chapters.contains(where: { $0.url == chapter.url }) else { return false }
            store.placeChapter(dragged, at: book.chapters.count - 1)
            return true
        }
        guard !item.hasPrefix("story:") else { return false }
        let dragged = URL(fileURLWithPath: item).canonical
        guard store.scene(for: dragged) != nil else { return false }
        store.placeScene(dragged, inChapter: chapter.url, at: chapter.scenes.filter { $0.url != dragged }.count)
        return true
    }

    /// What a dragged row carries: a scene its path (as the cards do), a chapter its path
    /// after "chapter:".
    private static func payload(_ tag: Selection) -> String {
        switch tag {
        case .scene(let url): return url.path
        case .chapter(let url): return "chapter:" + url.path
        case .book(let url): return "story:" + url.path
        }
    }

    /// A scene over a chapter's row lands under it, as that chapter's first scene.
    private func landsBelow(_ tag: Selection) -> Bool {
        if case .chapter = tag, case .scene = dragging { return true }
        return false
    }

    /// Whether the row being dragged can be dropped on this one.
    private func accepts(_ tag: Selection) -> Bool {
        switch (dragging, tag) {
        case (.scene, .scene), (.scene, .chapter), (.chapter, .chapter), (nil, _): return true
        default: return false
        }
    }

    /// A chapters-only story's rows carry their chapter's file: moving one moves the chapter.
    private func chapterOfFile(_ item: String) -> (book: Book, chapter: Chapter)? {
        guard !item.hasPrefix("chapter:"), !item.hasPrefix("story:"),
              let found = store.location(ofScene: URL(fileURLWithPath: item).canonical),
              found.book.shape == .chapters else { return nil }
        return found
    }

    private func drop(_ items: [String], on tag: Selection) -> Bool {
        guard let item = items.first, let library = store.library else { return false }
        if let dragged = chapterOfFile(item) {
            guard case .scene(let target) = tag, let over = store.location(ofScene: target),
                  over.book.url == dragged.book.url, over.chapter.url != dragged.chapter.url,
                  let index = dragged.book.chapters.filter({ $0.url != dragged.chapter.url }).firstIndex(where: { $0.url == over.chapter.url })
            else { return false }
            store.placeChapter(dragged.chapter.url, at: index)
            return true
        }
        if item.hasPrefix("chapter:") {
            let dragged = URL(fileURLWithPath: String(item.dropFirst("chapter:".count))).canonical
            guard case .chapter(let target) = tag, target != dragged,
                  let book = library.books.first(where: { $0.chapters.contains { $0.url == dragged } }),
                  let index = book.chapters.filter({ $0.url != dragged }).firstIndex(where: { $0.url == target }) else { return false }
            store.placeChapter(dragged, at: index)
            return true
        }
        guard !item.hasPrefix("story:") else { return false }
        let dragged = URL(fileURLWithPath: item).canonical
        guard store.scene(for: dragged) != nil else { return false }
        switch tag {
        case .scene(let target):
            guard target != dragged, let chapter = store.location(ofScene: target)?.chapter else { return false }
            let others = chapter.scenes.filter { $0.url != dragged }
            store.placeScene(dragged, inChapter: chapter.url, at: others.firstIndex { $0.url == target } ?? others.count)
            return true
        case .chapter(let target):
            store.placeScene(dragged, inChapter: target, at: 0)
            return true
        case .book:
            return false
        }
    }

    /// The rows on show, top to bottom (collapsed books and chapters hide theirs).
    private var visibleRows: [Selection] {
        guard let library = store.library else { return [] }
        guard let book = openBook(in: library) else {
            return library.books.filter { $0.folder.map { !collapsedFolders.contains($0) } ?? true }.map { .book($0.url) }
        }
        if store.contentsTab == .boneyard {
            return book.boneyardChapters.flatMap(\.scenes).map { .scene($0.url) }
                + (book.boneyard?.scenes ?? []).map { .scene($0.url) }
        }
        var rows: [Selection] = [.book(book.url)]
        switch book.shape {
        case .document: return rows
        case .scenes: return rows + book.looseScenes.map { .scene($0.url) }
        case .chapters: return rows + book.chapters.compactMap { $0.scenes.first.map { .scene($0.url) } }
        case .chaptersAndScenes: break
        }
        for chapter in book.chapters {
            rows.append(.chapter(chapter.url))
            guard !collapsedChapters.contains(chapter.url) else { continue }
            rows += chapter.scenes.map { .scene($0.url) }
        }
        return rows
    }

    // MARK: - Library and book

    /// A book's cover. Reads `coverVersion` so the view draws again when a cover is set.
    private func cover(of book: Book) -> NSImage? {
        _ = coverVersion
        return store.margin.cover(of: book.url)
    }

    /// The book's Info page can hide chapter numbers.
    private func hideNumbers(_ book: Book) -> Bool {
        looks[book.url]?.hideNumbers == true
    }

    private func openBook(in library: Library) -> Book? {
        guard let open = store.openBook else { return nil }
        return library.books.first { $0.url == open }
    }

    /// Goes into the book holding a chapter or scene chosen elsewhere. A book chosen with the
    /// arrow keys on the Library stays there until Return or a click.
    private func enterBook(of selection: Selection?) {
        guard let selection, let library = store.library else { return }
        let bookURL: URL
        switch selection {
        case .book: return
        case .chapter(let url): bookURL = url.deletingLastPathComponent().canonical
        case .scene(let url):
            // A scene's story by looking it up: a loose scene sits straight in the story's folder.
            guard let found = store.location(ofScene: url)?.book.url else { return }
            bookURL = found
        }
        guard let book = library.books.first(where: { $0.url.canonical == bookURL }), book.url != store.openBook else { return }
        store.openBook = book.url
    }

    /// "Library" above every book; inside a book, the book itself: ‹ back to all books, then
    /// its icon, name and count (click the name for the book's page).
    @ViewBuilder
    private var header: some View {
        if let library = store.library, let book = openBook(in: library) {
            bookCard(book)
        } else {
            HStack {
                Text("Library")
                    .font(.system(size: Layout.listSize, weight: .semibold))
                    .foregroundStyle(Color(PaperTheme.ink))
                Spacer()
            }
            .padding(.horizontal, Layout.pad)
            .frame(height: Layout.headerHeight)
        }
    }

    /// Inside a book, the book itself heads the column as a card, larger than the rows
    /// beneath it: ‹ back to every book, its icon in its colour, its name (up to two lines),
    /// its chapters and words, and the rule toward its target if it has one. Click it for the
    /// book's page.
    private func bookCard(_ book: Book) -> some View {
        let look = looks[book.url]
        let selected = store.selection == .book(book.url)
        let words = store.wordCount(of: book)
        let target = store.margin.info(for: book.url).target
        return VStack(spacing: 0) {
            // Back to every story: a labelled row the width of the column, in line with the
            // page's and the margin's header rows.
            Button {
                store.showLibrary()
            } label: {
                HStack(spacing: 6) {
                    Symbol.back.view(size: 11, weight: .semibold)
                    Text("Library")
                        .font(.system(size: Layout.listSize))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color(PaperTheme.ink))
                .padding(.horizontal, Layout.pad)
                .frame(height: Layout.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Library")
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

            Button {
                takeKeys()
                // A single document: the card opens it. Otherwise the story's page or cards.
                if let document = book.document {
                    if store.selection != .scene(document.url) { store.selection = .scene(document.url) }
                    return
                }
                store.selection = .book(book.url)
                // The story's cards, and remembered for that story.
                store.setViewMode(.cards)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    BookCover(title: book.title, image: cover(of: book), width: 64, form: looks[book.url]?.form, byline: looks[book.url]?.byline ?? "", collection: looks[book.url]?.collection)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(book.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color(PaperTheme.ink))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // As on the Library's rows: the stage's badge, the genre, the form, each
                        // on a line of its own.
                        if let stage = look?.stage { StageBadge(stage: stage) }
                        ForEach([look?.genre, look?.form?.title].compactMap { $0 }.filter { !$0.isEmpty }, id: \.self) { detail in
                            Text(detail)
                                .font(.system(size: Layout.detailSize, weight: .medium))
                                .foregroundStyle(Color(PaperTheme.secondary))
                                .lineLimit(1)
                        }
                        if let target, target > 0 {
                            // Pages for a screenplay, words for anything else.
                            let progress = store.targetProgress(of: book)
                            ProgressRule(fraction: Double(progress.done) / Double(target))
                                .frame(height: 2)
                                .padding(.top, 4)
                                .help("\(progress.done.formatted()) of \(target.formatted()) \(progress.unit)")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, Layout.pad)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(book.shape == .document ? "Open the document" : "Show the story as cards")
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowBackground(selected || (book.document.map { store.selection == .scene($0.url) } ?? false) ? Color(PaperTheme.selection) : .clear,
                           framed: hasKeys && (selected || (book.document.map { store.selection == .scene($0.url) } ?? false)))
            .padding(.vertical, 4)
            .contextMenu { bookMenu(book) }
        }
    }

    /// A folder on the Library: a chevron, a folder symbol, its name and how many stories it
    /// holds. Click to open or close it.
    private func folderRow(_ folder: Folder, count: Int) -> some View {
        let closed = collapsedFolders.contains(folder.url)
        return Button {
            toggle(&collapsedFolders, folder.url)
        } label: {
            HStack(spacing: 7) {
                (closed ? Symbol.caretRight : Symbol.caretDown).view(size: 10, weight: .semibold)
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .frame(width: 12)
                Symbol.folder.view(size: 13)
                    .foregroundStyle(Color(PaperTheme.secondary))
                Text(folder.title)
                    .font(.system(size: Layout.listSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Badge("\(count)")
            }
            .padding(.horizontal, Layout.pad)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(count == 1 ? "1 story" : "\(count) stories")
        .contextMenu {
            Button("Rename…") { renameFolder = folder }
            Divider()
            Button("Show in Finder") { store.reveal(folder.url) }
            Button("Move to Trash", role: .destructive) { store.deleteFolder(folder.url) }
                .disabled(count > 0)
        }
    }

    /// A book on the Library: its cover (or blank book), title and stage.
    private func libraryRow(_ book: Book) -> some View {
        LibraryRow(
            title: book.title,
            look: looks[book.url] ?? Look(),
            words: store.wordCount(of: book),
            pages: book.document.flatMap { $0.isScreenplay ? store.pages(of: $0) : nil },
            selected: store.selection == .book(book.url),
            keyed: hasKeys && store.selection == .book(book.url),
            cover: cover(of: book),
            enter: { store.openBook = book.url }
        )
        .equatable()
        .contentShape(Rectangle())
        // A click shows the Book Info page, staying in the Library; a double-click (or the
        // row's ›, or Return) goes into the book. One gesture, reading the click count, so a
        // single click isn't held back waiting to see if a second follows.
        .onTapGesture {
            takeKeys()
            if store.selection != .book(book.url) { store.selection = .book(book.url) }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { store.openBook = book.url }
        }
        // Not the book's selection id: the book's own row inside it has that one, and two
        // views sharing an id in the stack made SwiftUI show the wrong one.
        .id("library:" + book.url.path)
        .contextMenu { bookMenu(book) }
    }

    @ViewBuilder
    private func bookMenu(_ book: Book) -> some View {
        if book.shape.hasChapters {
            Button("New \(store.names(of: book.url).chapter)") {
                store.selection = .book(book.url)
                store.createChapterInContext()
            }
        }
        Button("Rename…") { renameTarget = item(for: book) }
        if (book.shape == .document || book.shape == .scenes) && !book.isScreenplay {
            Button("Split into \(store.names(of: book.url).chapters)") { store.splitIntoChapters(book.url) }
        }
        if book.shape != .document {
            Button("Join into One Document…") { joinTarget = book }
        }
        if let folders = store.library?.folders, !folders.isEmpty {
            Menu("Move to") {
                ForEach(folders.filter { $0.url != book.folder }) { folder in
                    Button(folder.title) { store.moveBook(book.url, toFolder: folder.url) }
                }
                if book.folder != nil {
                    Divider()
                    Button("Library") { store.moveBook(book.url, toFolder: nil) }
                }
            }
        }
        Divider()
        Button("Move Up") { store.move(item(for: book), by: -1) }
        Button("Move Down") { store.move(item(for: book), by: 1) }
        Divider()
        Button("Show in Finder") { store.reveal(book.url) }
        Button("Move to Trash", role: .destructive) { deleteTarget = item(for: book) }
    }

    /// ↑ and ↓ move the selection through the rows on show.
    private func takeKeys() {
        Panes.active = .contents
        if let keys = Panes.keysView(.contents) { keys.window?.makeFirstResponder(keys) }
    }

    /// The contents' keys. ↑ ↓ move the choice; → opens a chapter (or goes into a story in
    /// the Library) and ← closes it (or goes up to what holds the choice); the Finder's keys:
    /// Return renames (in the Library, goes into the story), ⌘⌫ moves to the Trash (asking
    /// first), ⌘↓ opens the choice on the page, ⌘↑ goes up to the Library.
    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let inLibrary = store.openBook == nil
        switch event.keyCode {
        case 126 where flags.isEmpty: moveSelection(by: -1)
        case 125 where flags.isEmpty: moveSelection(by: 1)
        case 126 where flags == .command:
            guard !inLibrary else { return false }
            store.showLibrary()
        case 125 where flags == .command:
            if inLibrary, case .book(let url) = store.selection { store.openBook = url } else { Panes.focus(.page, in: store) }
        case 124 where flags.isEmpty:
            switch store.selection {
            case .book(let url) where inLibrary: store.openBook = url
            case .chapter(let url):
                if collapsedChapters.contains(url) { collapsedChapters.remove(url) } else { moveSelection(by: 1) }
            default: return false
            }
        case 123 where flags.isEmpty:
            switch store.selection {
            case .chapter(let url) where !collapsedChapters.contains(url) && store.chapter(for: url)?.scenes.isEmpty == false
                && store.book(for: url.deletingLastPathComponent().canonical)?.shape == .chaptersAndScenes:
                collapsedChapters.insert(url)
            case .scene(let url):
                // Up to its chapter, where it has one in the contents.
                guard let place = store.location(ofScene: url), place.book.shape == .chaptersAndScenes,
                      !place.chapter.boneyard else { return false }
                store.selection = .chapter(place.chapter.url)
            case .book where !inLibrary: store.showLibrary()
            default: return false
            }
        case 36, 76:
            guard flags.isEmpty else { return false }
            if case .book(let url) = store.selection, inLibrary {
                store.openBook = url
            } else if let target = selectedItem, target.kind != .book {
                renameTarget = target
            } else {
                return false
            }
        case 51 where flags == .command:
            guard let target = selectedItem else { return false }
            deleteTarget = target
        default:
            return false
        }
        return true
    }

    private func moveSelection(by step: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let index = store.selection.flatMap { rows.firstIndex(of: $0) }
        let next = index.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        store.selection = rows[next]
    }

    private func chapterRow(_ chapter: Chapter, number: Int?) -> some View {
        row(
            leading: rowLeading,
            number: number.map(String.init),
            numberWidth: numberColumn,
            title: chapter.title,
            weight: .medium,
            count: store.wordCount(of: chapter),
            change: changedChapters.contains(chapter.url) ? .changed : nil,
            status: statuses[chapter.url],
            selected: store.selection == .chapter(chapter.url),
            tag: .chapter(chapter.url),
            disclosure: (collapsedChapters.contains(chapter.url), { toggle(&collapsedChapters, chapter.url) })
        ) {
            Button("New \(store.names(of: chapter.url.deletingLastPathComponent().canonical).scene)") {
                store.selection = .chapter(chapter.url)
                store.createSceneInContext()
            }
            Button("Rename…") { renameTarget = item(for: chapter) }
            statusMenu(chapter.url)
            Divider()
            if store.canMoveChapterToBoneyard(chapter.url) {
                Button("Move to Boneyard") { store.moveChapterToBoneyard(chapter.url) }
                Divider()
            }
            Button("Move Up") { store.move(item(for: chapter), by: -1) }
            Button("Move Down") { store.move(item(for: chapter), by: 1) }
            Divider()
            Button("Show in Finder") { store.reveal(chapter.url) }
            Button("Move to Trash", role: .destructive) { deleteTarget = item(for: chapter) }
        }
    }

    /// A heading in a single document's outline, indented by its level. Clicking it brings the
    /// heading to the top of the page, with the caret at its end.
    private func headingRow(_ heading: OutlineHeading, in document: URL) -> some View {
        Button {
            takeKeys()
            goTo(heading, in: document)
        } label: {
            HStack(spacing: 0) {
                if let number = heading.number {
                    Text(number)
                        .font(.system(size: Layout.listSize).monospacedDigit())
                        .foregroundStyle(Color(PaperTheme.tertiary))
                        .lineLimit(1)
                        .fixedSize()
                        // Room for "16A" and the like; longer numbers widen it.
                        .frame(minWidth: 30, alignment: .trailing)
                        .padding(.trailing, 7)
                }
                Text(heading.title)
                    .font(.system(size: Layout.listSize, weight: heading.level == 1 && heading.number == nil ? .medium : .regular))
                    .foregroundStyle(Color(heading.level <= 2 ? PaperTheme.ink : PaperTheme.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, heading.number != nil ? rowLeading : rowLeading + triangle + CGFloat(max(0, heading.level - outlineTop)) * step)
            .padding(.trailing, Layout.pad)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(heading.title)
    }

    /// The outline's top level: its highest heading, so a document of `##` headings isn't
    /// indented by one for nothing.
    private var outlineTop: Int { outline.map(\.level).min() ?? 1 }

    /// Reads the open document's headings from its file (saved a moment after typing).
    private func refreshOutline() {
        guard let library = store.library, let document = openBook(in: library)?.document else {
            if !outline.isEmpty { outline = [] }
            return
        }
        let text = store.fileText(at: document.url)
        let next = document.isScreenplay ? OutlineHeading.screenplay(in: text) : OutlineHeading.all(in: text)
        if next != outline { outline = next }
    }

    private func goTo(_ heading: OutlineHeading, in document: URL) {
        if store.selection != .scene(document) { store.selection = .scene(document) }
        let screenplay = document.pathExtension.lowercased() == ProseFile.fountain
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // A screenplay being read: its page.
            if screenplay, store.viewMode == .read {
                NotificationCenter.default.post(name: ScreenplayReader.goToScene, object: heading.id)
                return
            }
            // The page's own text, which may be newer than the file: the same heading by order.
            let ranges = { (text: String) in screenplay ? Fountain.headings(in: text).map(\.range) : OutlineHeading.ranges(in: text) }
            guard let page = store.margin.textView,
                  let range = ranges(page.string).dropFirst(heading.id).first else { return }
            page.window?.makeFirstResponder(page)
            page.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            page.scrollRangeToVisible(range)
            if let line = page.lineRects(of: range).first, let clip = page.enclosingScrollView?.contentView {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, line.minY - 24)))
                page.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
    }

    /// A chapters-only story's chapter: one row for the chapter and its one file. Clicking it
    /// opens the file; renaming it renames both.
    private func chapterOnlyRow(_ chapter: Chapter, number: Int?) -> some View {
        let scene = chapter.scenes.first
        let tag: Selection = scene.map { .scene($0.url) } ?? .chapter(chapter.url)
        return row(
            leading: rowLeading + triangle,
            number: number.map(String.init),
            numberWidth: numberColumn,
            title: chapter.title,
            weight: .medium,
            count: nil,
            comments: scene.map { openCounts[$0.url] ?? 0 } ?? 0,
            change: scene.flatMap { changeMarks[$0.url] },
            words: store.wordCount(of: chapter),
            status: statuses[scene?.url ?? chapter.url],
            selected: store.selection == tag || scene.map { onCards($0.url) } == true,
            tag: tag,
            disclosure: nil
        ) {
            Button("Rename…") { renameTarget = item(for: chapter) }
            statusMenu(scene?.url ?? chapter.url)
            Divider()
            Button("Move Up") { store.move(item(for: chapter), by: -1) }
            Button("Move Down") { store.move(item(for: chapter), by: 1) }
            Divider()
            Button("Show in Finder") { store.reveal(scene?.url ?? chapter.url) }
            Button("Move to Trash", role: .destructive) { deleteTarget = item(for: chapter) }
        }
    }

    /// A tree (owner, 2026-11-13): a chapter's scenes sit one level in, starting where the
    /// chapter's title starts, their numbers left-aligned and their titles on one edge.
    private func sceneRow(_ scene: Scene, number: String?, numberWidth: CGFloat, flat: Bool = false) -> some View {
        let chapterTitle = rowLeading + triangle + (number == nil ? 0 : numberColumn + numberGap)
        // A scenes-only story's scenes start where a chapter's title would.
        let leading = flat ? rowLeading + triangle : (number == nil ? chapterTitle + step : chapterTitle)
        return row(
            leading: leading,
            number: number,
            numberWidth: numberWidth,
            numberAlignment: .leading,
            title: scene.title,
            weight: .regular,
            count: nil,
            comments: openCounts[scene.url] ?? 0,
            change: changeMarks[scene.url],
            words: store.wordCount(of: scene),
            status: statuses[scene.url],
            selected: store.selection == .scene(scene.url) || onCards(scene.url),
            tag: .scene(scene.url),
            disclosure: nil
        ) {
            Button("Rename…") { renameTarget = item(for: scene) }
            statusMenu(scene.url)
            Divider()
            Button("Move Up") { store.move(item(for: scene), by: -1) }
            Button("Move Down") { store.move(item(for: scene), by: 1) }
            Divider()
            if store.canMoveToBoneyard(scene.url) {
                Button("Move to Boneyard") { store.moveToBoneyard(scene.url) }
            }
            Button("Show in Finder") { store.reveal(scene.url) }
            Button("Move to Trash", role: .destructive) { deleteTarget = item(for: scene) }
        }
    }

    /// Contents | Boneyard, across the top of the column inside a story, as the margin's tabs
    /// are across its own: square segments, the chosen one pressed in, the Boneyard's count in
    /// a box.
    private func contentsTabs(_ book: Book) -> some View {
        HStack(spacing: 0) {
            contentsTab(.contents, title: "Contents", count: nil)
            Rectangle().fill(Color(PaperTheme.hairline)).frame(width: 1)
            contentsTab(.boneyard, title: "Boneyard", count: (book.boneyard?.scenes.count ?? 0) + book.boneyardChapters.count)
        }
        .frame(height: Layout.headerHeight)
    }

    /// Whether a scene's card is the one chosen on the cards now showing.
    private func onCards(_ url: URL) -> Bool {
        guard store.viewMode == .cards, cardFocus == url else { return false }
        switch store.selection {
        case .chapter, .book: return true
        default: return false
        }
    }

    private func contentsTab(_ tab: LibraryStore.ContentsTab, title: String, count: Int?) -> some View {
        let selected = store.contentsTab == tab || (tab == .boneyard && boneyardTargeted)
        return Button {
            store.contentsTab = tab
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .fontWeight(selected ? .semibold : .medium)
                    .foregroundStyle(Color(selected ? PaperTheme.ink : PaperTheme.secondary))
                if let count, count > 0 { Badge("\(count)") }
            }
            .font(.system(size: Layout.chromeSize))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color(PaperTheme.controlOn) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab == .boneyard ? "Scenes and passages cut from this story: not in the manuscript, counts or export. Drop a card or scene here to cut it." : "The story's chapters and scenes")
        // A card or a scene's row dropped on the Boneyard tab is cut.
        .dropDestination(for: String.self) { payloads, _ in
            guard tab == .boneyard, let payload = payloads.first, let url = CardDrag.scene(in: payload),
                  store.canMoveToBoneyard(url) else { return false }
            store.moveToBoneyard(url)
            return true
        } isTargeted: { over in
            if tab == .boneyard { boneyardTargeted = over }
        }
    }

    /// The Boneyard tab: each cut chapter and cut scene, with where it was ("1.3") or, for a
    /// passage, the day it was cut. Click to open one; right-click to restore it. Empty when
    /// nothing is cut (owner: no line saying so).
    @ViewBuilder
    private func boneyardList(_ book: Book) -> some View {
        ForEach(book.boneyardChapters) { chapter in
            boneyardChapterRow(chapter, in: book)
        }
        ForEach(book.boneyard?.scenes ?? []) { scene in
            boneyardRow(scene, in: book)
        }
    }

    /// A cut chapter: the whole chapter, with the number it had. Clicking it opens its first
    /// scene; right-click puts the chapter back where it was.
    private func boneyardChapterRow(_ chapter: Chapter, in book: Book) -> some View {
        let cut = store.margin.info(for: chapter.url).cut
        let detail = cut?.number ?? cut.map { $0.date.formatted(.dateTime.day().month(.abbreviated)) }
        let first = chapter.scenes.first
        return Button {
            takeKeys()
            if let first, store.selection != .scene(first.url) { store.selection = .scene(first.url) }
        } label: {
            HStack(spacing: 8) {
                Text(chapter.title)
                    .font(.system(size: Layout.listSize))
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: Layout.detailSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color(PaperTheme.tertiary))
                        .fixedSize()
                }
            }
            .padding(.leading, Layout.pad)
            .padding(.trailing, Layout.pad)
            .frame(height: 24)
            .rowBackground(Color.clear, framed: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cut.map { "Cut from \($0.from)" } ?? chapter.title)
        .contextMenu {
            Button("Restore") { store.restoreChapter(chapter.url) }
            Divider()
            Button("Show in Finder") { store.reveal(chapter.url) }
            Button("Move to Trash", role: .destructive) { deleteTarget = item(for: chapter) }
        }
    }

    private func boneyardRow(_ scene: Scene, in book: Book) -> some View {
        let selected = store.selection == .scene(scene.url)
        let cut = store.margin.info(for: scene.url).cut
        let detail = cut?.number ?? cut.map { $0.date.formatted(.dateTime.day().month(.abbreviated)) }
        return Button {
            takeKeys()
            if !selected { store.selection = .scene(scene.url) }
        } label: {
            HStack(spacing: 8) {
                Text(scene.title)
                    .font(.system(size: Layout.listSize, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color(selected ? PaperTheme.ink : PaperTheme.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: Layout.detailSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color(PaperTheme.tertiary))
                        .fixedSize()
                }
            }
            .padding(.leading, Layout.pad)
            .padding(.trailing, Layout.pad)
            .frame(height: 24)
            .rowBackground(Color(selected ? PaperTheme.selection : .clear), framed: selected && hasKeys)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cut.map { "Cut from \($0.from)" } ?? scene.title)
        .contextMenu {
            Button("Restore") { store.restore(scene.url) }
            if book.document == nil, book.shape == .chaptersAndScenes, !book.chapters.isEmpty {
                Menu("Restore To") {
                    ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button("\(index + 1)  \(chapter.title)") { store.restore(scene.url, into: chapter.url) }
                    }
                }
            }
            Divider()
            Button("Show in Finder") { store.reveal(scene.url) }
            Button("Move to Trash", role: .destructive) { deleteTarget = item(for: scene) }
        }
    }

    /// Draft, Revised, Done (or none) for a chapter or scene.
    private func statusMenu(_ url: URL) -> some View {
        let current = statuses[url]
        return Menu("Status") {
            ForEach(SceneInfo.Status.allCases, id: \.self) { status in
                Toggle(status.title, isOn: Binding(get: { current == status }, set: { _ in setStatus(status, of: url) }))
            }
            Divider()
            Button("None") { setStatus(nil, of: url) }
        }
    }

    private func setStatus(_ status: SceneInfo.Status?, of url: URL) {
        var info = store.margin.info(for: url)
        info.status = info.status == status ? nil : status
        store.margin.setInfo(info, for: url)
    }

    // MARK: - Bottom bar

    /// In the Library: New Story, and New Folder in the menu. Inside a story: New Scene and
    /// New Chapter. Stories and folders are never made from inside a story.
    private var bottomBar: some View {
        let inLibrary = store.openBook == nil
        let open = store.library.flatMap { openBook(in: $0) }
        let shape = open?.shape ?? .chaptersAndScenes
        let names = store.names(of: open?.url)
        return HStack(spacing: 2) {
            if inLibrary {
                footButton("New Document", help: "New Document") { store.newDocumentShown = true }
            } else {
                // What the story's shape can take: a single document takes neither.
                if shape.hasScenes { footButton(names.scene, help: "New \(names.scene)") { store.createSceneInContext() } }
                if shape.hasChapters { footButton(names.chapter, help: "New \(names.chapter)") { store.createChapterInContext() } }
            }

            Spacer(minLength: 8)

            SquareToolbarButton(
                icon: .more,
                tooltip: "More",
                size: 24,
                width: 24,
                height: 24,
                iconSize: 13,
                bordered: false,
                menuItems: (inLibrary
                    ? [ToolbarMenuItem(title: "New Folder", separatorAfter: true) {
                        if let made = store.createFolder(), let folder = store.library?.folders.first(where: { $0.url == made }) {
                            renameFolder = folder
                        }
                    }]
                    : shapeItems + [ToolbarMenuItem(title: "Back to Library", separatorAfter: true) { store.showLibrary() }])
                    + [
                        ToolbarMenuItem(title: "Show Library in Finder", separatorAfter: true) {
                            store.revealLibrary()
                        },
                        ToolbarMenuItem(title: "Open Library…") { store.chooseLibrary() },
                        ToolbarMenuItem(title: "Close Library") { store.closeLibrary() }
                    ]
            )
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, Layout.pad - 6)
        .frame(height: Layout.barHeight)
    }

    /// Inside a story, the ··· menu offers to change how it is divided.
    private var shapeItems: [ToolbarMenuItem] {
        guard let book = store.library.flatMap({ openBook(in: $0) }) else { return [] }
        var items: [ToolbarMenuItem] = []
        if (book.shape == .document || book.shape == .scenes) && !book.isScreenplay {
            items.append(ToolbarMenuItem(title: "Split into \(store.names(of: book.url).chapters)") { store.splitIntoChapters(book.url) })
        }
        if book.shape != .document {
            items.append(ToolbarMenuItem(title: "Join into One Document…") { joinTarget = book })
        }
        if !items.isEmpty { items[items.count - 1].separatorAfter = true }
        return items
    }

    private func footButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Symbol.add.view(size: 11, weight: .semibold)
                Text(title)
                    .fontWeight(.medium)
            }
            .foregroundStyle(Color(PaperTheme.ink))
        }
        .buttonStyle(PlainSquareButtonStyle(height: 24, horizontalPadding: 6))
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No stories yet")
                .font(.system(size: Layout.listSize))
                .foregroundStyle(Color(PaperTheme.secondary))
            Button("New Document") { store.newDocumentShown = true }
                .buttonStyle(SquareButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var joinMessage: String {
        guard let book = joinTarget else { return "" }
        let scenes = book.chapters.reduce(0) { $0 + $1.scenes.count }
        let names = store.names(of: book.url)
        let what = book.shape == .chapters ? names.count(book.chapters.count, chapters: true) : names.count(scenes)
        let between = "* * * marks each break between \(names.scenes.lowercased())."
        let headings = book.shape.hasChapters ? " \(names.chapter) titles become headings, and \(between)" : " " + between.prefix(1).uppercased() + between.dropFirst()
        return "Its \(what) become one file, in order.\(headings) Comments and notes come along, and the old files go to the Trash."
    }

    private var deleteMessage: String {
        guard let target = deleteTarget else { return "" }
        let names = store.names(for: target)
        switch target.kind {
        case .book:
            return "The story goes to the Trash with its \(names.chapters.lowercased()) and \(names.scenes.lowercased()). You can put it back from there."
        case .chapter:
            return "The \(names.chapter.lowercased()) goes to the Trash with its \(names.scenes.lowercased()). You can put it back from there."
        case .scene:
            return "The \(names.scene.lowercased()) goes to the Trash. You can put it back from there."
        }
    }

    // MARK: - Helpers

    private func toggle(_ set: inout Set<URL>, _ url: URL) {
        if set.contains(url) { set.remove(url) } else { set.insert(url) }
    }

    /// The selected scene, chapter or story, as Rename and Move to Trash take it.
    private var selectedItem: ManuscriptItem? {
        switch store.selection {
        case .scene(let url): return store.scene(for: url).map(item(for:))
        case .chapter(let url): return store.chapter(for: url).map(item(for:))
        case .book(let url): return store.book(for: url).map(item(for:))
        case nil: return nil
        }
    }

    private func item(for book: Book) -> ManuscriptItem {
        ManuscriptItem(url: book.url, title: book.title, order: book.order, kind: .book)
    }

    private func item(for chapter: Chapter) -> ManuscriptItem {
        ManuscriptItem(url: chapter.url, title: chapter.title, order: chapter.order, kind: .chapter)
    }

    private func item(for scene: Scene) -> ManuscriptItem {
        ManuscriptItem(url: scene.url, title: scene.title, order: scene.order, kind: .scene)
    }
}

/// The disclosure chevron, turning a quarter when opened.
private struct DisclosureTriangle: View {
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Symbol.caretRight.view(size: 10, weight: .semibold)
                .foregroundStyle(Color(PaperTheme.secondary))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 20, height: Layout.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: collapsed)
    }
}

/// One row of the contents. No icons: books are semibold, chapters carry their number in a
/// tabular column, scenes are indented under the chapter title. The selected row is a flat
/// band, edge to edge (drawn by the list row background).
final class RowsOnScreen {
    var rows: Set<Selection> = []
}

/// A whole outline row: the row, its selection band, click and menu. Compared by the row's
/// values alone, so on a selection change SwiftUI rebuilds two rows, not every row's
/// modifiers. (The click and menu closures only capture the store and the row's own item.)
private struct RowShell<Menu: View>: View, Equatable {
    let row: OutlineRow
    let tap: () -> Void
    @ViewBuilder let menu: () -> Menu

    static func == (a: RowShell, b: RowShell) -> Bool { a.row == b.row }

    var body: some View {
        row
            .rowBackground(row.selected ? Color(PaperTheme.selection) : Color.clear, framed: row.keyed)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .contextMenu(menuItems: menu)
    }
}

private struct OutlineRow: View, Equatable {
    let leading: CGFloat
    /// A chapter's number ("2") or a scene's ("2.1").
    let number: String?
    let numberWidth: CGFloat
    /// Chapters' numbers end on one edge (9 and 10); scenes' start under their chapter's title.
    var numberAlignment: Alignment = .trailing
    let title: String
    let weight: Font.Weight
    let count: Int?
    let comments: Int
    /// Changed since your last commit: a bar at the row's left edge, like the page's.
    let change: ChangeState.Kind?
    /// A scene's words, for its tooltip.
    let words: Int?
    let status: SceneInfo.Status?
    let selected: Bool
    /// The chosen row while the contents has the keyboard: framed.
    var keyed = false
    /// Nil for a row without a disclosure triangle (a scene).
    let collapsed: Bool?
    let toggle: () -> Void
    let triangle: CGFloat
    let numberGap: CGFloat

    static func == (a: OutlineRow, b: OutlineRow) -> Bool {
        a.leading == b.leading && a.number == b.number && a.numberWidth == b.numberWidth && a.title == b.title && a.weight == b.weight
            && a.count == b.count && a.comments == b.comments && a.change == b.change && a.selected == b.selected && a.keyed == b.keyed
            && a.words == b.words && a.collapsed == b.collapsed && a.status == b.status
    }

    /// A scene's words, and whether it changed since its last version. Made only when the
    /// row draws (rows are compared first), not on every pass over the list.
    private var tooltip: String {
        guard let words else { return "" }
        let count = Estimate.words(words)
        switch change {
        case .added: return count + "\nNew since your last commit"
        case .changed: return count + "\nChanged since your last commit"
        case nil: return count
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: leading)

            if let collapsed {
                DisclosureTriangle(collapsed: collapsed, action: toggle)
                    .frame(width: triangle)
            }

            if let number {
                // Right-aligned, so 9 and 10 end at the same place before their titles.
                Text(number)
                    .font(.system(size: collapsed == nil ? Layout.smallSize : Layout.listSize, weight: weight).monospacedDigit())
                    .foregroundStyle(Color(PaperTheme.tertiary))
                    .lineLimit(1)
                    .frame(width: numberWidth, alignment: numberAlignment)
                    .padding(.trailing, numberGap)
            }

            Text(title)
                .font(.system(size: Layout.listSize, weight: selected ? (weight == .regular ? .medium : .semibold) : weight))
                .foregroundStyle(Color(PaperTheme.ink))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if let status {
                StatusBadge(status: status)
                    .padding(.trailing, comments > 0 || count != nil ? 6 : 0)
            }

            if comments > 0 {
                HStack(spacing: 3) {
                    Symbol.chat.view(size: 9)
                    Text("\(comments)")
                        .font(.system(size: Layout.smallSize, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(Color(PaperTheme.secondary))
                .boxed()
                .help(comments == 1 ? "1 open comment" : "\(comments) open comments")
            }

            if let count {
                Badge(count.formatted())
                    .padding(.leading, comments > 0 ? 6 : 0)
                    .help(Estimate.words(count))
            }
        }
        .padding(.trailing, Layout.pad)
        .frame(height: Layout.rowHeight)
        .help(tooltip)
        .overlay(alignment: .leading) {
            if let change {
                Rectangle()
                    .fill(Color(change == .added ? PaperTheme.diffAddedMark : PaperTheme.diffChangedMark))
                    .frame(width: 3, height: Layout.rowHeight - 8)
                    .padding(.leading, 3)
            }
        }
    }
}

/// A book on the Library: its icon (in its colour), title, and how many chapters and words.
private struct LibraryRow: View, Equatable {
    let title: String
    let look: SidebarView.Look
    let words: Int
    /// A screenplay's length, shown instead of its words.
    var pages: Int? = nil
    let selected: Bool
    var keyed = false
    /// The book's cover, if it has one.
    let cover: NSImage?
    var enter: () -> Void = {}

    /// The genre, then the form, whichever are set: one line each.
    private var details: [String] {
        [look.genre, look.form?.title].compactMap { $0 }.filter { !$0.isEmpty }
    }

    static func == (a: LibraryRow, b: LibraryRow) -> Bool {
        a.title == b.title && a.look == b.look && a.words == b.words && a.pages == b.pages && a.selected == b.selected && a.keyed == b.keyed && a.cover === b.cover
    }

    /// The Library's own row, larger than the rows inside a book: the cover (or its initial),
    /// then a line for each detail (owner, 2026-11-14): the title, its stage badge, genre, form,
    /// and its words. No icons for genres.
    var body: some View {
        HStack(spacing: 12) {
            BookCover(title: title, image: cover, width: 56, form: look.form, byline: look.byline, collection: look.collection)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Layout.listSize, weight: .semibold))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // Each detail on a line of its own (owner, 2026-11-14): the stage's badge, the
                // genre, the form, then the words.
                if let stage = look.stage { StageBadge(stage: stage).padding(.vertical, 1) }
                ForEach(details, id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: Layout.detailSize, weight: .medium))
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .lineLimit(1)
                }
                Text(pages.map { $0 == 1 ? "1 page" : "\($0.formatted()) pages" } ?? (words == 1 ? "1 word" : "\(words.formatted()) words"))
                    .font(.system(size: Layout.detailSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .help(Estimate.words(words))
            }
            Spacer(minLength: 2)
            Button(action: enter) {
                Symbol.caretRight.view(size: 11, weight: .semibold)
                    .foregroundStyle(Color(PaperTheme.secondary))
            }
            .buttonStyle(PlainSquareButtonStyle(height: 28, horizontalPadding: 0))
            .frame(width: 28)
            .help("Open the story")
        }
        .padding(.leading, Layout.pad)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowBackground(selected ? Color(PaperTheme.selection) : Color.clear, framed: keyed)
    }
}


/// A Markdown heading in a single document: `#` to `######` at the start of a line.
struct OutlineHeading: Identifiable, Equatable {
    /// Its place among the document's headings, counting from 0.
    let id: Int
    let level: Int
    let title: String
    /// A screenplay's scene number.
    var number: String? = nil

    /// A screenplay's scene headings, numbered.
    static func screenplay(in text: String) -> [OutlineHeading] {
        Fountain.headings(in: text).enumerated().map { index, heading in
            OutlineHeading(id: index, level: 1, title: heading.title, number: heading.number)
        }
    }

    static func all(in text: String) -> [OutlineHeading] {
        let ns = text as NSString
        return ranges(in: text).enumerated().map { index, range in
            let line = ns.substring(with: range)
            let level = line.prefix { $0 == "#" }.count
            return OutlineHeading(id: index, level: level, title: line.dropFirst(level).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Each heading line's range (without its line break), in order.
    static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var found: [NSRange] = []
        var fenced = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let content = ns.substring(with: line)
            if content.hasPrefix("```") { fenced.toggle(); return }
            guard !fenced else { return }
            let hashes = content.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), content.dropFirst(hashes).first == " ",
                  !content.dropFirst(hashes).trimmingCharacters(in: .whitespaces).isEmpty else { return }
            found.append(line)
        }
        return found
    }
}
