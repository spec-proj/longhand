import SwiftUI

/// Scenes as index cards: a chapter as a grid, a book as a column of cards per chapter.
///
/// Click a card to see its synopsis, status, target and notes in the margin; double-click to
/// open the scene. Drag a card onto another to put it there (in the same chapter or another);
/// drop it on the empty part of a chapter to put it last.
struct ChapterCardsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    let chapter: Chapter
    /// As many columns of cards at least 200pt wide as fit in `width`, up to four.
    private func columns(_ width: CGFloat) -> [GridItem] {
        let count = max(1, min(4, Int((width + 16) / 216)))
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
    }

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 6) {
                    Text(chapter.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(PaperTheme.ink))
                        .lineLimit(1)
                        .padding(.trailing, 6)
                    Badge(chapter.scenes.count == 1 ? "1 scene" : "\(chapter.scenes.count) scenes")
                    Badge(Estimate.words(store.wordCount(of: chapter)))
                }
                .padding(.bottom, 24)

                let chapterNumber = store.shownNumber(ofChapter: chapter.url)
                LazyVGrid(columns: columns(geometry.size.width - 64), alignment: .leading, spacing: 16) {
                    ForEach(Array(chapter.scenes.enumerated()), id: \.element.id) { index, scene in
                        DraggableCard(scene: scene, number: index + 1, chapterNumber: chapterNumber, chapter: chapter, compact: false)
                    }
                }

                Button {
                    store.selection = .chapter(chapter.url)
                    store.createSceneInContext()
                } label: {
                    HStack(spacing: 6) {
                        Symbol.add.view(size: 12)
                        Text("New Scene")
                    }
                    .foregroundStyle(Color(PaperTheme.ink))
                }
                .buttonStyle(PlainSquareButtonStyle())
                .padding(.top, 16)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        }
        .background(Color(PaperTheme.paper))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            _ = drop(items, at: chapter.scenes.count)
        }
    }

    private func drop(_ items: [String], at index: Int) -> Bool {
        guard let path = items.first else { return false }
        store.placeScene(URL(fileURLWithPath: path).canonical, inChapter: chapter.url, at: index)
        return true
    }
}

/// A book's chapters side by side, each a column of cards.
struct BookCardsView: View {
    @EnvironmentObject private var store: LibraryStore
    let book: Book

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(book.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420, alignment: .leading)
                BookProgress(book: book)
            }
            // Lazy: only the columns in view are built (a novel has dozens of chapters).
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                    ChapterColumn(chapter: chapter, number: index + 1)
                }
            }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 32)
        }
        .scrollIndicators(.never)
        .background(Color(PaperTheme.paper))
    }
}

private struct ChapterColumn: View {
    @EnvironmentObject private var store: LibraryStore
    let chapter: Chapter
    let number: Int
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                store.selection = .chapter(chapter.url)
            } label: {
                HStack(spacing: 0) {
                    Text("\(number)")
                        .monospacedDigit()
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .frame(width: 22, alignment: .leading)
                    Text(chapter.title)
                        .fontWeight(.medium)
                        .foregroundStyle(Color(PaperTheme.ink))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Badge(store.wordCount(of: chapter).formatted())
                }
                .font(.system(size: Layout.chromeSize))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(chapter.title)")
            .padding(.bottom, 4)

            let chapterNumber = store.shownNumber(ofChapter: chapter.url)
            ForEach(Array(chapter.scenes.enumerated()), id: \.element.id) { index, scene in
                DraggableCard(scene: scene, number: index + 1, chapterNumber: chapterNumber, chapter: chapter, compact: true)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The rest of the column takes drops that put a scene last.
            Rectangle()
                .fill(targeted ? Color(PaperTheme.selection) : Color.clear)
                .frame(height: chapter.scenes.isEmpty ? 120 : 64)
                .overlay {
                    if chapter.scenes.isEmpty {
                        rounded().strokeBorder(Color(PaperTheme.hairline), lineWidth: 1)
                    }
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let path = items.first else { return false }
                    store.placeScene(URL(fileURLWithPath: path).canonical, inChapter: chapter.url, at: chapter.scenes.count)
                    return true
                } isTargeted: { targeted = $0 }
        }
        .frame(width: 240)
    }
}

/// A card that can be clicked, double-clicked, dragged, and dropped on.
private struct DraggableCard: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    let scene: Scene
    let number: Int
    /// The chapter's number, handed down so a card doesn't search the library for its own.
    let chapterNumber: Int?
    let chapter: Chapter
    let compact: Bool
    @State private var targeted = false

    /// "2.1", or "1" when the story's numbers are off.
    private var label: String { chapterNumber.map { "\($0).\(number)" } ?? "\(number)" }

    var body: some View {
        SceneCard(
            scene: scene,
            number: label,
            info: margin.info(for: scene.url),
            words: store.wordCount(of: scene),
            selected: margin.sceneURL == scene.url,
            compact: compact
        )
        // Where a dropped card will go: a rule just above this one.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(targeted ? Color(PaperTheme.ink) : .clear)
                .frame(height: 2)
                .offset(y: -6)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.selection = .scene(scene.url) }
        .onTapGesture { select() }
        .draggable(scene.url.path) {
            SceneCard(scene: scene, number: label, info: margin.info(for: scene.url), words: store.wordCount(of: scene),
                      selected: true, compact: true)
                .frame(width: 240)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let path = items.first else { return false }
            let dragged = URL(fileURLWithPath: path).canonical
            guard dragged != scene.url else { return false }
            let others = chapter.scenes.filter { $0.url != dragged }
            let index = others.firstIndex { $0.url == scene.url } ?? others.count
            store.placeScene(dragged, inChapter: chapter.url, at: index)
            return true
        } isTargeted: { targeted = $0 }
        .help("Double-click to open the scene")
        .contextMenu {
            Button("Open") { store.selection = .scene(scene.url) }
            Divider()
            ForEach(SceneInfo.Status.allCases, id: \.self) { status in
                Button(status.title) {
                    var info = margin.info(for: scene.url)
                    info.status = info.status == status ? nil : status
                    margin.setInfo(info, for: scene.url)
                }
            }
        }
    }

    private func select() {
        let book = store.library?.books.first { $0.chapters.contains { $0.url == chapter.url } }
        margin.focusScene(scene.url, chapter: chapter.url, book: book?.url)
        UserDefaults.standard.set(MarginStore.Tab.notes.rawValue, forKey: "marginTab")
    }
}

/// An index card: number and status, title, synopsis, and the word count (with progress
/// towards a target, if the scene has one). Square, white, framed by a hairline; the selected
/// card's frame is ink.
struct SceneCard: View {
    let scene: Scene
    /// "2.1": the chapter's number and the scene's place in it.
    let number: String
    let info: SceneInfo
    let words: Int
    let selected: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Badge(number)
                Spacer()
                if let status = info.status { StatusBadge(status: status) }
            }
            .padding(.bottom, 2)

            Text(scene.title)
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.ink))
                .lineLimit(2)

            if !info.synopsis.isEmpty {
                Text(info.synopsis)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(Color(PaperTheme.ink).opacity(0.78))
                    .lineSpacing(2)
                    .lineLimit(compact ? 3 : 5)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Badge(Estimate.words(words))
                if let target = info.target, target > 0 {
                    ProgressRule(fraction: Double(words) / Double(target))
                        .help("\(words.formatted()) of \(target.formatted()) words")
                }
            }
            .font(.system(size: Layout.detailSize, weight: .medium))
            .foregroundStyle(Color(PaperTheme.secondary))
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.top, compact ? 10 : 14)
        .padding(.bottom, compact ? 10 : 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 96 : 184, maxHeight: compact ? nil : 184, alignment: .topLeading)
        .background(Color(PaperTheme.card))
        .roundedFrame(Color(selected ? PaperTheme.ink : PaperTheme.cardBorder), lineWidth: 1)
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
