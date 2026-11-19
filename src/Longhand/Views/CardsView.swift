import AppKit
import SwiftUI

// Index cards (owner, 2026-11-14: fix everything the audit found, then labels, sizes, editing on
// the card, dragging chapters and dragging to the Boneyard).
//
// One board for every shape that has cards:
// - a chapter: its scenes as a grid;
// - a scenes-only story: its scenes as a grid, headed by the story;
// - a chapters-only story: one card per chapter (its one file), as a grid; dragging reorders
//   the chapters;
// - a story of chapters and scenes: a column of cards per chapter.
// A single document or a screenplay has no cards.
//
// Click a card to choose it (its details show in the margin, its row in the contents);
// double-click or ⌘↓ opens it; Return edits its title and synopsis on the card. Arrow keys move
// between cards; ⌘⌫ moves the chosen one to the Trash (asking first). A card dropped on another
// takes its place; dropped on the empty end of a chapter it goes last; dropped on the Boneyard
// tab it is cut.

/// A colour on a scene's card, for whatever the writer wants it to mean.
enum CardLabel: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, grey
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: NSColor {
        switch self {
        case .red: return Self.pair(0xB8473D, 0xE07A70, name: "Red")
        case .orange: return Self.pair(0xC0702A, 0xE89A5A, name: "Orange")
        case .yellow: return Self.pair(0xA27F14, 0xD9B54E, name: "Yellow")
        case .green: return Self.pair(0x3F8A4A, 0x7CC487, name: "Green")
        case .blue: return Self.pair(0x3D6FB0, 0x7FA6DD, name: "Blue")
        case .purple: return Self.pair(0x7A55A8, 0xAE8ED6, name: "Purple")
        case .grey: return Self.pair(0x75736C, 0xA09E96, name: "Grey")
        }
    }

    private static func pair(_ light: Int, _ dark: Int, name: String) -> NSColor {
        func rgb(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: "CardLabel" + name) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }
}

/// How big the cards are: View › Card Size, the palette, and the switch above the cards.
enum CardSize: String, CaseIterable, Identifiable {
    case small, medium, large
    static let key = "cardSize"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: Symbol {
        switch self {
        case .small: return .cardsSmall
        case .medium: return .cardsMedium
        case .large: return .cardsLarge
        }
    }
    /// A grid card's narrowest width, and the most cards across.
    var gridMin: CGFloat { switch self { case .small: 160; case .medium: 200; case .large: 280 } }
    var maxColumns: Int { switch self { case .small: 6; case .medium: 4; case .large: 3 } }
    /// A grid card's height (cards in a row line up).
    var height: CGFloat { switch self { case .small: 124; case .medium: 184; case .large: 250 } }
    /// A chapter's column on the story's board, and a card's least height there.
    var columnWidth: CGFloat { switch self { case .small: 200; case .medium: 240; case .large: 300 } }
    var columnMinHeight: CGFloat { switch self { case .small: 72; case .medium: 96; case .large: 132 } }
    /// How many lines of synopsis a card shows at most: the card grows to hold them, so a
    /// long one is never cut in the middle of a line.
    static let synopsisLines = 12
    var titleSize: CGFloat { self == .small ? Layout.chromeSize : 15 }
    var synopsisSize: CGFloat { self == .small ? Layout.detailSize : Layout.chromeSize }

    /// The height of a line of synopsis.
    var lineHeight: CGFloat { ceil(synopsisSize * 1.2) + 2 }

    /// How many lines of synopsis fit on a card of this size: the number, the title (on two
    /// lines, the most it takes) and the word count have their room first.
    var fitLines: Int {
        let content = height - 14 - 12
        let used = 17 + 2 * ceil(titleSize * 1.2) + 4 * 6 + 17
        return max(0, Int((content - used) / lineHeight))
    }

    /// How many lines a synopsis takes at this width: the card is made tall enough for it.
    func linesNeeded(width: CGFloat, text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: synopsisSize)
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(width, 40), height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return max(1, Int((bounds.height / lineHeight).rounded(.up)))
    }
}

/// What is being dragged, and where a dropped card lands.
@MainActor
enum CardDrag {
    /// The payload of the drag in progress (set when it starts), so a card under it can show
    /// which side the dragged one will land on.
    static var payload: String?

    static func payload(scene url: URL) -> String { url.path }
    static func payload(chapter url: URL) -> String { "chapter:" + url.path }

    /// A scene's file in a payload (not a chapter's or a story's).
    static func scene(in payload: String) -> URL? {
        guard !payload.hasPrefix("chapter:"), !payload.hasPrefix("story:") else { return nil }
        return URL(fileURLWithPath: payload).canonical
    }

    static func chapter(in payload: String) -> URL? {
        guard payload.hasPrefix("chapter:") else { return nil }
        return URL(fileURLWithPath: String(payload.dropFirst("chapter:".count))).canonical
    }

    /// Where an item dropped on `target` goes, as an index among `list` without the dragged
    /// item: it takes the target's place. From earlier in the same list that is just after the
    /// target (so dropping a card on the next one moves it one place on), otherwise just before.
    nonisolated static func index(dropping dragged: URL, on target: URL, in list: [URL]) -> Int? {
        guard dragged != target else { return nil }
        let others = list.filter { $0 != dragged }
        guard let place = others.firstIndex(of: target) else { return nil }
        return lands(after: dragged, target, in: list) ? place + 1 : place
    }

    /// The card an arrow key moves to: in a grid, across and by rows of `gridColumns`; on the
    /// story's board, up and down a column, across to the next chapter that has cards.
    nonisolated static func neighbour(of current: URL?, dx: Int, dy: Int, lists: [[URL]], gridColumns: Int?) -> URL? {
        guard let current else { return lists.first { !$0.isEmpty }?.first }
        if let columns = gridColumns {
            let list = lists.first ?? []
            guard let index = list.firstIndex(of: current) else { return list.first }
            let next = index + dx + dy * columns
            return list.indices.contains(next) ? list[next] : nil
        }
        guard let c = lists.firstIndex(where: { $0.contains(current) }), let r = lists[c].firstIndex(of: current) else {
            return lists.first { !$0.isEmpty }?.first
        }
        if dy != 0 {
            let next = r + dy
            return lists[c].indices.contains(next) ? lists[c][next] : nil
        }
        var column = c + dx
        while lists.indices.contains(column) {
            if !lists[column].isEmpty { return lists[column][min(r, lists[column].count - 1)] }
            column += dx
        }
        return nil
    }

    /// Whether a dropped item lands after `target` rather than before it.
    nonisolated static func lands(after dragged: URL, _ target: URL, in list: [URL]) -> Bool {
        guard let from = list.firstIndex(of: dragged), let to = list.firstIndex(of: target) else { return false }
        return from < to
    }
}

/// The kind of board.
enum CardBoardKind {
    case chapter(Chapter)
    case loose(Book)
    case chapters(Book)
    case book(Book)
}

/// One card: the file it stands for, and where it is.
private struct CardItem: Identifiable {
    let scene: Scene
    let number: String?
    let chapter: Chapter
    let book: Book
    /// A chapters-only story: the card stands for the whole chapter.
    let isChapter: Bool
    var id: URL { scene.url }
    var title: String { isChapter ? chapter.title : scene.title }
    var manuscriptItem: ManuscriptItem {
        isChapter
            ? ManuscriptItem(url: chapter.url, title: chapter.title, order: chapter.order, kind: .chapter)
            : ManuscriptItem(url: scene.url, title: scene.title, order: scene.order, kind: .scene)
    }
}

/// A chapter's cards (from DetailView).
struct ChapterCardsView: View {
    @EnvironmentObject private var store: LibraryStore
    let chapter: Chapter

    var body: some View {
        if let book = store.library?.books.first(where: { $0.chapters.contains { $0.url == chapter.url } }) {
            CardBoard(kind: .chapter(chapter), book: book)
        }
    }
}

/// A story's cards (from DetailView), by its shape.
struct BookCardsView: View {
    let book: Book

    var body: some View {
        switch book.shape {
        case .scenes: CardBoard(kind: .loose(book), book: book)
        case .chapters: CardBoard(kind: .chapters(book), book: book)
        default: CardBoard(kind: .book(book), book: book)
        }
    }

    /// Whether a story has cards at all (not a single document or a screenplay).
    static func hasCards(_ book: Book) -> Bool { book.shape != .document }
}

/// Where a card sits on the board. Cards keep their view while a drop renames the files
/// under them, so they are named by place rather than by file.
private struct Spot: Hashable {
    let column: Int
    let row: Int
}

private struct CardBoard: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    @AppStorage(CardSize.key) private var sizeName = CardSize.medium.rawValue
    let kind: CardBoardKind
    let book: Book

    /// The card being edited on the board, and what has been typed.
    @State private var editing: URL?
    @State private var draftTitle = ""
    @State private var draftSynopsis = ""
    @State private var editField: CardEditor.Field = .title
    @State private var trashTarget: ManuscriptItem?
    @State private var endTargeted: URL?
    /// A card just made, to edit once it is on the board.
    @State private var pendingEdit: URL?
    /// The column the pointer is over: its New Scene shows while it is there.
    @State private var hovering: URL?
    /// The pointer is over the board itself (the grid's own New Scene).
    @State private var hoveringBoard = false

    private var size: CardSize { CardSize(rawValue: sizeName) ?? .medium }
    private var hidesNumbers: Bool { margin.info(for: book.url).hideChapterNumbers == true }
    private var names: PartNames { store.names(of: book.url) }

    /// The cards, a list per column of the story's board, or one list for a grid.
    private var lists: [(chapter: Chapter, items: [CardItem])] {
        switch kind {
        case .chapter(let chapter):
            let number = store.shownNumber(ofChapter: chapter.url)
            return [(chapter, chapter.scenes.enumerated().map { index, scene in
                CardItem(scene: scene, number: number.map { "\($0).\(index + 1)" } ?? (hidesNumbers ? nil : "\(index + 1)"),
                         chapter: chapter, book: book, isChapter: false)
            })]
        case .loose(let book):
            guard let chapter = book.chapters.first else { return [] }
            return [(chapter, chapter.scenes.enumerated().map { index, scene in
                CardItem(scene: scene, number: hidesNumbers ? nil : "\(index + 1)", chapter: chapter, book: book, isChapter: false)
            })]
        case .chapters(let book):
            let items = book.chapters.enumerated().compactMap { index, chapter -> CardItem? in
                guard let file = chapter.scenes.first else { return nil }
                return CardItem(scene: file, number: hidesNumbers ? nil : "\(index + 1)", chapter: chapter, book: book, isChapter: true)
            }
            return [(book.chapters.first ?? Chapter(url: book.url, title: book.title, order: 0, scenes: []), items)]
        case .book(let book):
            return book.chapters.enumerated().map { chapterIndex, chapter in
                (chapter, chapter.scenes.enumerated().map { index, scene in
                    CardItem(scene: scene, number: hidesNumbers ? nil : "\(chapterIndex + 1).\(index + 1)",
                             chapter: chapter, book: book, isChapter: false)
                })
            }
        }
    }

    private var isGrid: Bool { if case .book = kind { return false } else { return true } }

    var body: some View {
        let lists = self.lists
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                Group {
                    if isGrid {
                        grid(lists.first?.items ?? [], width: geometry.size.width)
                    } else {
                        columnsBoard(lists)
                    }
                }
                // The board's keys, while it has the keyboard (a click on it, or Go › Page).
                .background(PaneKeys(pane: .page, priority: 1, store: store, onKey: { event in
                    keyPressed(event, lists: lists, columns: gridColumns(geometry.size.width), proxy: proxy)
                }))
            }
        }
        .background(Color(PaperTheme.paper))
        .alert(
            "Move to Trash?",
            isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let target = trashTarget { store.delete(target) }
                trashTarget = nil
            }
            Button("Cancel", role: .cancel) { trashTarget = nil }
        } message: {
            Text("“\(trashTarget?.title ?? "")” goes to the Trash. You can put it back from there.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.ink))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.trailing, 6)
                .layoutPriority(2)
            ForEach(headerBadges, id: \.self) { Badge($0).fixedSize().layoutPriority(2) }
            if case .chapter = kind {} else {
                // The target's rule gives way first; its words never do.
                BookProgress(book: book)
                    .frame(maxWidth: 260)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 16)
            CardSizeSwitch(size: Binding(get: { size }, set: { sizeName = $0.rawValue }))
        }
    }

    private var headerTitle: String {
        if case .chapter(let chapter) = kind { return chapter.title }
        return book.title
    }

    private var headerBadges: [String] {
        switch kind {
        case .chapter(let chapter):
            return [names.count(chapter.scenes.count), Estimate.words(store.wordCount(of: chapter))]
        case .loose(let book):
            return [names.count(book.chapters.first?.scenes.count ?? 0), Estimate.words(book.chapters.reduce(0) { $0 + store.wordCount(of: $1) })]
        case .chapters(let book), .book(let book):
            return [names.count(book.chapters.count, chapters: true), Estimate.words(book.chapters.reduce(0) { $0 + store.wordCount(of: $1) })]
        }
    }

    // MARK: Grid

    private func gridColumns(_ width: CGFloat) -> Int {
        max(1, min(size.maxColumns, Int((width - 64 + 16) / (size.gridMin + 16))))
    }

    private func grid(_ items: [CardItem], width: CGFloat) -> some View {
        let columns = gridColumns(width)
        let urls = items.map(\.id)
        // The width a card's text has: the column's width, less the card's own padding.
        let cell = (width - 64 - 16 * CGFloat(columns - 1)) / CGFloat(columns) - 32
        // The cards are as tall as the longest synopsis needs, so no card is cut short and
        // they still line up.
        let lines = min(CardSize.synopsisLines, items.map {
            size.linesNeeded(width: cell, text: margin.info(for: $0.id).synopsis)
        }.max() ?? 0)
        let height = size.height + CGFloat(max(0, lines - size.fitLines)) * size.lineHeight
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 24)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns),
                          alignment: .leading, spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.offset) { row, item in
                        card(item, spot: Spot(column: 0, row: row), list: urls, axis: .horizontal, lines: lines, height: height)
                    }
                }
                newButton.padding(.top, 16)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .contentShape(Rectangle())
        .onTapGesture { finishEditing(); takeKeys() }
        // The board's own New Scene shows while the pointer is over it.
        .onHover { hoveringBoard = $0 }
        // The empty part of the board: dropped cards go last.
        .dropDestination(for: String.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            return dropAtEnd(payload, of: lists.first?.chapter)
        }
    }

    /// The board's own New Scene (or New Chapter, in a chapters-only story): it shows while
    /// the pointer is over the board.
    @ViewBuilder private var newButton: some View {
        switch kind {
        case .chapters(let book):
            addButton("New \(names.chapter)") { startNew(store.createChapter(in: book.url, open: false)) }
                .opacity(hoveringBoard ? 1 : 0)
        case .chapter(let chapter):
            addButton("New \(names.scene)") { startNew(store.createScene(inChapter: chapter.url, open: false)) }
                .opacity(hoveringBoard ? 1 : 0)
        case .loose(let book):
            if let chapter = book.chapters.first {
                addButton("New \(names.scene)") { startNew(store.createScene(inChapter: chapter.url, open: false)) }
                    .opacity(hoveringBoard ? 1 : 0)
            }
        case .book:
            EmptyView()
        }
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Symbol.add.view(size: 12)
                Text(title)
            }
            .foregroundStyle(Color(PaperTheme.ink))
        }
        .buttonStyle(PlainSquareButtonStyle())
    }

    // MARK: Columns (a story of chapters and scenes)

    private func columnsBoard(_ lists: [(chapter: Chapter, items: [CardItem])]) -> some View {
        let chapterURLs = lists.map(\.chapter.url)
        // The heading stays put; the chapters scroll under and beside it.
        return VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 20)
            ScrollView([.horizontal, .vertical]) {
                // Lazy: only the columns in view are built (a novel has dozens of chapters).
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(lists.enumerated()), id: \.offset) { index, list in
                        column(list.chapter, items: list.items, column: index, number: hidesNumbers ? nil : index + 1, chapters: chapterURLs)
                    }
                    // The last column: a new chapter (owner, 2026-11-15).
                    newChapterColumn
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            // The board is wider than the window with more than a few chapters: say so.
            .scrollIndicators(.visible, axes: .horizontal)
            .scrollIndicators(.never, axes: .vertical)
        }
        .contentShape(Rectangle())
        .onTapGesture { finishEditing(); takeKeys() }
    }

    /// The board's last column: a new chapter, level with the chapter headings.
    private var newChapterColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 24)
            addButton("New \(names.chapter)") { store.createChapter(in: book.url) }
            Spacer(minLength: 0)
        }
        .frame(width: size.columnWidth)
    }

    private func column(_ chapter: Chapter, items: [CardItem], column: Int, number: Int?, chapters: [URL]) -> some View {
        let urls = items.map(\.id)
        return VStack(alignment: .leading, spacing: 10) {
            ChapterColumnHeader(chapter: chapter, number: number, words: store.wordCount(of: chapter),
                                chapters: chapters, onOpen: { store.selection = .chapter(chapter.url) },
                                onDrop: { dropOnChapter($0, chapter: chapter, chapters: chapters) },
                                onCut: { store.moveChapterToBoneyard(chapter.url) })
                .padding(.bottom, 4)

            ForEach(Array(items.enumerated()), id: \.offset) { row, item in
                card(item, spot: Spot(column: column, row: row), list: urls, axis: .vertical)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The rest of the column takes drops that put a scene last.
            let targeted = endTargeted == chapter.url
            Rectangle()
                .fill(targeted ? Color(PaperTheme.selection) : Color.clear)
                .frame(height: chapter.scenes.isEmpty ? 120 : 40)
                .overlay {
                    if chapter.scenes.isEmpty {
                        rounded().strokeBorder(Color(PaperTheme.hairline), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .dropDestination(for: String.self) { payloads, _ in
                    guard let payload = payloads.first else { return false }
                    return dropAtEnd(payload, of: chapter)
                } isTargeted: { endTargeted = $0 ? chapter.url : (endTargeted == chapter.url ? nil : endTargeted) }

            // New scene, under the column: it shows while the pointer is over the column.
            addButton("New \(names.scene)") { startNew(store.createScene(inChapter: chapter.url, open: false)) }
                .foregroundStyle(Color(PaperTheme.secondary))
                .opacity(hovering == chapter.url ? 1 : 0)
        }
        .frame(width: size.columnWidth)
        .onHover { over in
            hovering = over ? chapter.url : (hovering == chapter.url ? nil : hovering)
        }
    }

    // MARK: A card

    private func card(_ item: CardItem, spot: Spot, list: [URL], axis: Axis, lines: Int = CardSize.synopsisLines,
                      height: CGFloat? = nil) -> some View {
        BoardCard(
            item: item,
            size: size,
            compact: axis == .vertical,
            synopsisLines: lines,
            height: height,
            selected: margin.sceneURL == item.id,
            comments: margin.openCounts[item.id] ?? 0,
            info: margin.info(for: item.id),
            words: item.isChapter ? store.wordCount(of: item.chapter) : store.wordCount(of: item.scene),
            axis: axis,
            editing: editing == item.id,
            draftTitle: $draftTitle,
            draftSynopsis: $draftSynopsis,
            editField: $editField,
            accepts: { accepts($0, on: item) },
            landsAfter: { landsAfter($0, on: item, in: list) },
            onDrop: { drop($0, on: item, in: list) },
            onClick: { count in
                if editing != nil, editing != item.id { finishEditing() }
                takeKeys()
                if count >= 2 { open(item) } else { select(item) }
            },
            onCommit: finishEditing,
            onCancel: { editing = nil; takeKeys() },
            onEnd: { if editing == item.id { finishEditing() } }
        )
        .id(spot)
        .contextMenu { menu(item) }
        .onChange(of: item.id, initial: true) {
            if pendingEdit == item.id { pendingEdit = nil; edit(item) }
            if let picture = Snapshot.cardPicture, lists.flatMap(\.items).first?.id == item.id {
                Snapshot.cardPicture = nil
                if picture == "edit" { edit(item) } else { select(item) }
            }
        }
    }

    @ViewBuilder private func menu(_ item: CardItem) -> some View {
        Button("Open") { open(item) }
        Button("Edit Card") { edit(item) }
        Divider()
        Menu("Status") {
            ForEach(SceneInfo.Status.allCases, id: \.self) { status in
                Toggle(status.title, isOn: Binding(
                    get: { margin.info(for: item.id).status == status },
                    set: { _ in
                        var info = margin.info(for: item.id)
                        info.status = info.status == status ? nil : status
                        margin.setInfo(info, for: item.id)
                    }))
            }
        }
        Menu("Label") {
            ForEach(CardLabel.allCases) { label in
                Toggle(label.title, isOn: Binding(
                    get: { margin.info(for: item.id).label == label },
                    set: { _ in setLabel(margin.info(for: item.id).label == label ? nil : label, on: item) }))
            }
            Divider()
            Button("None") { setLabel(nil, on: item) }
        }
        if !item.isChapter, item.book.shape == .chaptersAndScenes, item.book.chapters.count > 1 {
            Menu("Move To") {
                ForEach(item.book.chapters.filter { $0.url != item.chapter.url }) { chapter in
                    Button(chapter.title) {
                        store.placeScene(item.scene.url, inChapter: chapter.url, at: chapter.scenes.count)
                    }
                }
            }
        }
        Divider()
        if !item.isChapter, store.canMoveToBoneyard(item.scene.url) {
            Button("Move to Boneyard") { store.moveToBoneyard(item.scene.url) }
        }
        Button("Show in Finder") { store.reveal(item.scene.url) }
        Button("Move to Trash", role: .destructive) { trashTarget = item.manuscriptItem }
    }

    private func setLabel(_ label: CardLabel?, on item: CardItem) {
        var info = margin.info(for: item.id)
        info.label = label
        margin.setInfo(info, for: item.id)
    }

    // MARK: Choosing, opening, editing

    private func select(_ item: CardItem) {
        margin.focusScene(item.id, chapter: item.chapter.implicit ? nil : item.chapter.url, book: book.url)
        UserDefaults.standard.set(MarginStore.Tab.notes.rawValue, forKey: "marginTab")
    }

    private func open(_ item: CardItem) {
        finishEditing()
        store.selection = .scene(item.id)
    }

    private func edit(_ item: CardItem) {
        finishEditing()
        select(item)
        draftTitle = item.title
        draftSynopsis = margin.info(for: item.id).synopsis
        editField = .title
        editing = item.id
    }

    /// A card just made: choose it and type its title once the board shows it.
    private func startNew(_ url: URL?) {
        finishEditing()
        pendingEdit = url
    }

    /// Keeps what was typed on the card being edited: the synopsis first (renaming moves the
    /// file, and its details with it), then the title.
    private func finishEditing() {
        guard let url = editing else { return }
        editing = nil
        takeKeys()
        guard let item = lists.flatMap(\.items).first(where: { $0.id == url }) else { return }
        var info = margin.info(for: url)
        let synopsis = draftSynopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        if info.synopsis != synopsis {
            info.synopsis = synopsis
            margin.setInfo(info, for: url)
        }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != item.title { store.rename(item.manuscriptItem, to: title) }
    }

    // MARK: Keys

    private func takeKeys() {
        Panes.active = .page
        if let keys = Panes.keysView(.page) { keys.window?.makeFirstResponder(keys) }
    }

    /// The board's keys: arrows move the choice, Return edits the card, ⌘↓ opens its scene,
    /// ⌘⌫ moves it to the Trash (asking first). True when the key was used.
    private func keyPressed(_ event: NSEvent, lists: [(chapter: Chapter, items: [CardItem])], columns: Int, proxy: ScrollViewProxy) -> Bool {
        guard editing == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let all = lists.flatMap(\.items)
        let current = all.first { $0.id == margin.sceneURL }
        let code = event.keyCode
        switch code {
        case 36, 76:
            guard let current, modifiers.isEmpty else { return false }
            edit(current)
            return true
        case 51:
            guard let current, modifiers == .command else { return false }
            trashTarget = current.manuscriptItem
            return true
        case 125 where modifiers == .command:
            guard let current else { return false }
            open(current)
            return true
        case 123...126:
            guard modifiers.isEmpty else { return false }
        default:
            return false
        }
        let dx = code == 123 ? -1 : code == 124 ? 1 : 0
        let dy = code == 126 ? -1 : code == 125 ? 1 : 0
        guard let next = CardDrag.neighbour(of: current?.id, dx: dx, dy: dy, lists: lists.map { $0.items.map(\.id) },
                                        gridColumns: isGrid ? columns : nil),
              let item = all.first(where: { $0.id == next }) else { return true }
        select(item)
        if let column = lists.firstIndex(where: { $0.items.contains { $0.id == item.id } }),
           let row = lists[column].items.firstIndex(where: { $0.id == item.id }) {
            proxy.scrollTo(Spot(column: column, row: row))
        }
        return true
    }

    // MARK: Drops

    /// Whether a payload can be dropped on this card.
    private func accepts(_ payload: String, on item: CardItem) -> Bool {
        if item.isChapter {
            guard let file = CardDrag.scene(in: payload), let found = store.location(ofScene: file) else { return false }
            return found.book.url == item.book.url && found.chapter.url != item.chapter.url
        }
        guard let scene = CardDrag.scene(in: payload), scene != item.id,
              let found = store.location(ofScene: scene) else { return false }
        return found.book.shape.hasScenes
    }

    private func landsAfter(_ payload: String, on item: CardItem, in list: [URL]) -> Bool {
        if item.isChapter {
            guard let file = CardDrag.scene(in: payload), let chapter = store.location(ofScene: file)?.chapter else { return false }
            return CardDrag.lands(after: chapter.url, item.chapter.url, in: item.book.chapters.map(\.url))
        }
        guard let scene = CardDrag.scene(in: payload) else { return false }
        return CardDrag.lands(after: scene, item.id, in: list)
    }

    private func drop(_ payload: String, on item: CardItem, in list: [URL]) -> Bool {
        guard accepts(payload, on: item) else { return false }
        if item.isChapter {
            guard let file = CardDrag.scene(in: payload), let chapter = store.location(ofScene: file)?.chapter,
                  let index = CardDrag.index(dropping: chapter.url, on: item.chapter.url, in: item.book.chapters.map(\.url))
            else { return false }
            store.placeChapter(chapter.url, at: index)
            return true
        }
        guard let scene = CardDrag.scene(in: payload),
              let index = CardDrag.index(dropping: scene, on: item.id, in: list) else { return false }
        store.placeScene(scene, inChapter: item.chapter.url, at: index)
        return true
    }

    /// A card dropped on the empty end of a chapter (or of the board) goes last.
    private func dropAtEnd(_ payload: String, of chapter: Chapter?) -> Bool {
        switch kind {
        case .chapters(let book):
            guard let file = CardDrag.scene(in: payload), let found = store.location(ofScene: file),
                  found.book.url == book.url else { return false }
            store.placeChapter(found.chapter.url, at: book.chapters.count - 1)
            return true
        default:
            guard let chapter, let scene = CardDrag.scene(in: payload),
                  let found = store.location(ofScene: scene), found.book.shape.hasScenes else { return false }
            store.placeScene(scene, inChapter: chapter.url, at: chapter.scenes.count)
            return true
        }
    }

    /// On a chapter's heading: another chapter takes its place; a scene becomes its first.
    private func dropOnChapter(_ payload: String, chapter: Chapter, chapters: [URL]) -> Bool {
        if let dragged = CardDrag.chapter(in: payload) {
            guard chapters.contains(dragged),
                  let index = CardDrag.index(dropping: dragged, on: chapter.url, in: chapters) else { return false }
            store.placeChapter(dragged, at: index)
            return true
        }
        guard let scene = CardDrag.scene(in: payload), let found = store.location(ofScene: scene),
              found.book.shape.hasScenes else { return false }
        store.placeScene(scene, inChapter: chapter.url, at: 0)
        return true
    }
}

/// A chapter's heading on the story's board: click to open the chapter's cards, drag to move
/// the chapter, drop another chapter on it to take its place.
private struct ChapterColumnHeader: View {
    let chapter: Chapter
    let number: Int?
    let words: Int
    let chapters: [URL]
    let onOpen: () -> Void
    let onDrop: (String) -> Bool
    /// Sends the whole chapter to the Boneyard.
    var onCut: (() -> Void)?
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 0) {
            if let number {
                Text("\(number)")
                    .monospacedDigit()
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .frame(width: 22, alignment: .leading)
            }
            Text(chapter.title)
                .fontWeight(.medium)
                .foregroundStyle(Color(PaperTheme.ink))
                .lineLimit(1)
            Spacer(minLength: 8)
            Badge(words.formatted())
        }
        .font(.system(size: Layout.chromeSize))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help("Click to open \(chapter.title); drag to move it")
        .onDrag {
            DragProbe.mark()
            let payload = CardDrag.payload(chapter: chapter.url)
            CardDrag.payload = payload
            return NSItemProvider(object: payload as NSString)
        } preview: {
            DragChip(number: number.map(String.init), title: chapter.title)
        }
        .dropDestination(for: String.self) { payloads, _ in
            DragProbe.markDrop()
            targeted = false
            guard let payload = payloads.first else { return false }
            return onDrop(payload)
        } isTargeted: { targeted = $0 }
        // Where a dropped chapter will go: a rule beside this column, on the side it lands.
        .overlay(alignment: landsAfter ? .trailing : .leading) {
            Rectangle()
                .fill(targeted && CardDrag.payload.flatMap(CardDrag.chapter(in:)) != nil ? Color(PaperTheme.ink) : .clear)
                .frame(width: 2)
                .offset(x: landsAfter ? 9 : -9)
        }
        .background(targeted && CardDrag.payload.flatMap(CardDrag.scene(in:)) != nil ? Color(PaperTheme.selection) : .clear)
        .contextMenu {
            if let onCut {
                Button("Move to Boneyard", role: .destructive, action: onCut)
            }
        }
    }

    private var landsAfter: Bool {
        guard let dragged = CardDrag.payload.flatMap(CardDrag.chapter(in:)) else { return false }
        return CardDrag.lands(after: dragged, chapter.url, in: chapters)
    }
}

/// A card on the board: chosen with a click, opened with a double-click, dragged, dropped on,
/// and edited in place.
private struct BoardCard: View {
    let item: CardItem
    let size: CardSize
    let compact: Bool
    /// How many lines of synopsis the card shows.
    let synopsisLines: Int
    /// The card's height, when it is fixed (a grid's cards are all the same height).
    let height: CGFloat?
    let selected: Bool
    let comments: Int
    let info: SceneInfo
    let words: Int
    let axis: Axis
    let editing: Bool
    @Binding var draftTitle: String
    @Binding var draftSynopsis: String
    @Binding var editField: CardEditor.Field
    let accepts: (String) -> Bool
    let landsAfter: (String) -> Bool
    let onDrop: (String) -> Bool
    let onClick: (Int) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onEnd: () -> Void
    @State private var targeted = false

    var body: some View {
        content
            .overlay(alignment: indicatorAlignment) { indicator }
            .contentShape(Rectangle())
            // One gesture, so a single click chooses at once (two gestures wait to see
            // whether a second click is coming).
            .onTapGesture { onClick(NSApp.currentEvent?.clickCount ?? 1) }
            .onDrag {
                DragProbe.mark()
                let payload = CardDrag.payload(scene: item.id)
                CardDrag.payload = payload
                return NSItemProvider(object: payload as NSString)
            } preview: {
                DragChip(number: item.number, title: item.title)
            }
            .dropDestination(for: String.self) { payloads, _ in
                DragProbe.markDrop()
                targeted = false
                guard let payload = payloads.first else { return false }
                return onDrop(payload)
            } isTargeted: { targeted = $0 }
            .help("Double-click to open; Return to edit the card")
    }

    @ViewBuilder private var content: some View {
        if editing {
            CardEditor(title: $draftTitle, synopsis: $draftSynopsis, field: $editField, size: size, compact: compact,
                       label: info.label, onCommit: onCommit, onCancel: onCancel, onEnd: onEnd)
        } else {
            SceneCard(title: item.title, number: item.number, info: info, words: words, comments: comments,
                      selected: selected, size: size, compact: compact, synopsisLines: synopsisLines, height: height)
        }
    }

    private var showsIndicator: Bool {
        guard targeted, let payload = CardDrag.payload else { return false }
        return accepts(payload)
    }

    private var after: Bool { CardDrag.payload.map(landsAfter) ?? false }

    private var indicatorAlignment: Alignment {
        axis == .horizontal ? (after ? .trailing : .leading) : (after ? .bottom : .top)
    }

    /// Where a dropped card will go: a 2px ink rule on the side it lands (beside a card in a
    /// grid, above or below one in a column).
    @ViewBuilder private var indicator: some View {
        let colour = showsIndicator ? Color(PaperTheme.ink) : Color.clear
        if axis == .horizontal {
            Rectangle().fill(colour).frame(width: 2).offset(x: after ? 9 : -9)
        } else {
            Rectangle().fill(colour).frame(height: 2).offset(y: after ? 6 : -6)
        }
    }
}

/// An index card: its label's colour along the top, number, comments and status, the title,
/// the synopsis, and the word count (with progress towards a target, if the scene has one).
/// Framed by a hairline; the chosen card's frame is ink.
struct SceneCard: View {
    let title: String
    /// "2.1": the chapter's number and the scene's place in it (nil when numbers are off).
    let number: String?
    let info: SceneInfo
    let words: Int
    var comments: Int = 0
    let selected: Bool
    var size: CardSize = .medium
    let compact: Bool
    /// How many lines of synopsis the card shows.
    var synopsisLines: Int = CardSize.synopsisLines
    /// The card's height, when it is fixed (a grid's cards are all the same height).
    var height: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let number { Badge(number) }
                Spacer(minLength: 0)
                if comments > 0 { CommentCount(count: comments) }
                if let status = info.status { StatusBadge(status: status) }
            }
            .padding(.bottom, 2)

            Text(title)
                .font(.system(size: size.titleSize, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.ink))
                .lineLimit(2)

            if !info.synopsis.isEmpty {
                Text(info.synopsis)
                    .font(.system(size: size.synopsisSize))
                    .foregroundStyle(Color(PaperTheme.ink).opacity(0.78))
                    .lineSpacing(2)
                    .lineLimit(synopsisLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            CardFoot(words: words, target: info.target)
        }
        .cardFrame(size: size, compact: compact, label: info.label, selected: selected, height: height)
    }
}

/// The card's word count, with a progress rule towards its target.
private struct CardFoot: View {
    let words: Int
    let target: Int?

    var body: some View {
        HStack(spacing: 10) {
            Badge(Estimate.words(words))
            if let target, target > 0 {
                ProgressRule(fraction: Double(words) / Double(target))
                    .help("\(words.formatted()) of \(target.formatted()) words")
            }
        }
        .font(.system(size: Layout.detailSize, weight: .medium))
        .foregroundStyle(Color(PaperTheme.secondary))
    }
}

/// Open comments on a card, as the contents shows them.
private struct CommentCount: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Symbol.chat.view(size: 9)
            Text("\(count)")
                .font(.system(size: Layout.smallSize, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(Color(PaperTheme.secondary))
        .boxed()
        .help(count == 1 ? "1 open comment" : "\(count) open comments")
    }
}

private extension View {
    /// A card's paper, size, label band and frame.
    func cardFrame(size: CardSize, compact: Bool, label: CardLabel?, selected: Bool, height: CGFloat? = nil) -> some View {
        padding(.horizontal, compact ? 12 : 16)
            .padding(.top, (compact ? 10 : 14) + (label == nil ? 0 : 3))
            .padding(.bottom, compact ? 10 : 12)
            .frame(maxWidth: .infinity,
                   minHeight: compact ? size.columnMinHeight : (height ?? size.height),
                   maxHeight: compact ? nil : (height ?? size.height),
                   alignment: .topLeading)
            .background(Color(PaperTheme.card))
            .overlay(alignment: .top) {
                if let label {
                    Rectangle().fill(Color(label.color)).frame(height: 4)
                        .help(label.title)
                }
            }
            .roundedFrame(Color(selected ? PaperTheme.ink : PaperTheme.cardBorder), lineWidth: 1)
    }
}

/// A card being edited: its title and synopsis in fields on the card itself. Tab moves
/// between them, Return keeps the changes, Escape drops them, Option-Return starts a new
/// line in the synopsis.
struct CardEditor: View {
    enum Field { case title, synopsis }
    @Binding var title: String
    @Binding var synopsis: String
    @Binding var field: Field
    let size: CardSize
    let compact: Bool
    let label: CardLabel?
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardField(text: $title, placeholder: "Title", font: .systemFont(ofSize: size.titleSize, weight: .semibold),
                      multiline: false, focused: field == .title,
                      onSubmit: onCommit, onCancel: onCancel, onTab: { _ in field = .synopsis }, onEnd: onEnd,
                      onBegin: { field = .title })
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
            CardField(text: $synopsis, placeholder: "Synopsis", font: .systemFont(ofSize: size.synopsisSize),
                      multiline: true, focused: field == .synopsis,
                      onSubmit: onCommit, onCancel: onCancel, onTab: { _ in field = .title }, onEnd: onEnd,
                      onBegin: { field = .synopsis })
            Spacer(minLength: 0)
        }
        .cardFrame(size: size, compact: compact, label: label, selected: true)
    }
}

/// A wrapping text field that takes the keyboard when asked (AppKit: SwiftUI's focus lost to
/// the editor's text view elsewhere; see `KeyField`).
struct CardField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let multiline: Bool
    let focused: Bool
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Tab (false) or Shift-Tab (true).
    var onTab: (Bool) -> Void = { _ in }
    /// The keyboard went somewhere other than another card field (a click elsewhere).
    var onEnd: () -> Void = {}
    /// A click put the keyboard in this field: the card follows it, so the field that had
    /// the keyboard stops asking for it back (it once took it again mid-typing).
    var onBegin: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = PaperTheme.ink
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: PaperTheme.tertiary
        ])
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.stringValue = text
        field.delegate = context.coordinator
        field.wantsKeyboard = focused
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        field.wantsKeyboard = focused
        if focused { field.take() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Field, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let sample = (text.isEmpty ? placeholder : text) as NSString
        let bounds = sample.boundingRect(with: NSSize(width: max(width - 4, 10), height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return CGSize(width: width, height: ceil(max(bounds.height, font.ascender - font.descender + font.leading)) + 2)
    }

    final class Field: NSTextField {
        var wantsKeyboard = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if wantsKeyboard { take() }
        }

        /// Takes the keyboard (once the window has settled: a view put on screen in the same
        /// pass may take it after us), with the caret at the end.
        func take() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsKeyboard, let window = self.window, self.currentEditor() == nil else { return }
                window.makeFirstResponder(self)
                if let editor = self.currentEditor() {
                    editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CardField
        init(_ parent: CardField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                guard parent.multiline else { parent.onSubmit(); return true }
                return false
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            case #selector(NSResponder.insertTab(_:)): parent.onTab(false)
            case #selector(NSResponder.insertBacktab(_:)): parent.onTab(true)
            default: return false
            }
            return true
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onBegin()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            let window = (notification.object as? NSView)?.window
            // A moment later: Tab hands the keyboard to the card's other field.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                let holder = window?.firstResponder as? NSTextView
                if holder?.isFieldEditor == true, holder?.delegate is CardField.Field { return }
                self.parent.onEnd()
            }
        }
    }
}

/// Small, medium or large cards: three square segments with SF Symbols.
struct CardSizeSwitch: View {
    @Binding var size: CardSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(CardSize.allCases.enumerated()), id: \.element) { index, option in
                if index > 0 { Rectangle().fill(Color(PaperTheme.controlBorder)).frame(width: 1) }
                Button { size = option } label: {
                    option.symbol.view(size: 11, weight: size == option ? .semibold : .regular)
                        .foregroundStyle(Color(size == option ? PaperTheme.ink : PaperTheme.secondary))
                        .frame(width: 28)
                        .frame(maxHeight: .infinity)
                        .background(size == option ? Color(PaperTheme.controlOn) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(option.title) cards")
                .accessibilityLabel("\(option.title) cards")
            }
        }
        .frame(height: Layout.controlHeight)
        .background(Color(PaperTheme.controlFill))
        .roundedFrame(Color(PaperTheme.controlBorder), lineWidth: 1)
    }
}

/// Progress as a thin square-ended rule: a hairline track with an ink fill.
struct ProgressRule: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(PaperTheme.hairline))
                Rectangle().fill(Color(PaperTheme.ink))
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 2)
    }
}
