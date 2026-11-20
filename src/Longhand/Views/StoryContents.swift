import SwiftUI

/// What a story's page shows under Contents (issue #8). A story takes the contents that suit
/// its form: chapters for a novel, each poem for a book of poems, the poem itself for a single
/// poem or song, and for a single story or essay its headings, or its opening if it has none.
enum ContentsKind {
    /// Chapters, as a printed book's contents.
    case chapters
    /// A book of poems or songs: each one, in order.
    case poems
    /// One poem or song: the text itself, no contents.
    case poem
    /// One piece of prose in a single file: its headings, or its opening if it has none.
    case headings

    static func of(form: BookForm?, shape: BookShape) -> ContentsKind {
        let verse = form == .poetry || form == .lyrics
        switch shape {
        case .document:
            if form == .screenplay { return .chapters }
            return verse ? .poem : .headings
        case .scenes:
            return verse ? .poems : .chapters
        case .chaptersAndScenes, .chapters:
            return .chapters
        }
    }
}

/// A single document read for its page: the headings with where they fall, its opening, and
/// the text without its title.
struct DocumentSummary: Equatable {
    struct Entry: Identifiable, Equatable {
        /// The heading's place among the document's headings, as the outline counts them.
        let id: Int
        let level: Int
        let title: String
        let page: Int
        let words: Int
    }

    var headings: [Entry] = []
    /// The first paragraph or two, as Markdown.
    var opening = ""
    /// The whole text, without a title line at its head and the blank lines around it.
    var body = ""

    init(text: String = "") {
        let ns = text as NSString
        var start = 0
        // A title at the head of the file is the story's name, shown above.
        let ranges = OutlineHeading.ranges(in: text)
        var hasTitle = false
        if let first = ranges.first, ns.substring(to: first.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ns.substring(with: first).hasPrefix("# ") {
            start = NSMaxRange(first)
            hasTitle = true
        }
        body = ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)

        let all = OutlineHeading.all(in: text)
        let shown = all.indices.filter { !(hasTitle && $0 == 0) }
        // Words ahead of the first heading shown count toward the page it falls on.
        var before = shown.first.map { Self.words(ns.substring(with: NSRange(location: start, length: ranges[$0].location - start))) } ?? 0
        for index in shown {
            let heading = all[index]
            let range = ranges[index]
            let end = index + 1 < ranges.count ? ranges[index + 1].location : ns.length
            let words = Self.words(ns.substring(with: NSRange(location: NSMaxRange(range), length: max(0, end - NSMaxRange(range)))))
            headings.append(Entry(id: index, level: heading.level, title: heading.title,
                                  page: Int(Double(before) / Estimate.wordsPerPage) + 1, words: words))
            before += words
        }
        opening = Self.opening(of: body)
    }

    private static func words(_ text: String) -> Int { LiveCount.words(in: text as NSString) }

    /// The first paragraph, and the next if the first is short: a few lines to read, not a page.
    static func opening(of body: String) -> String {
        let paragraphs = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.allSatisfy { "*-_ ".contains($0) } }
        guard let first = paragraphs.first else { return "" }
        var out = first
        if Self.words(first) < 35, paragraphs.count > 1 { out += "\n\n" + paragraphs[1] }
        return out
    }
}

/// The Contents heading on a story's page: set larger than the page's other titles, in the
/// book's own face, as a printed contents page is (owner, 2026-11-20).
struct ContentsTitle: View {
    var body: some View {
        Text("Contents")
            .font(.system(size: 22, weight: .semibold, design: .serif))
            .foregroundStyle(Color(PaperTheme.ink))
    }
}

/// A single document's part of the story's page: the poem, or the headings, or the opening.
struct DocumentContents: View {
    @EnvironmentObject private var store: LibraryStore
    let kind: ContentsKind
    let document: Scene
    @State private var summary = DocumentSummary()
    @State private var hovering = false

    /// Read again when the document changes or is saved (its word count moves).
    private struct Reload: Equatable { let url: URL; let words: Int }

    var body: some View {
        // A stack, not a Group: a task on an empty Group (a document still being read) never runs.
        VStack(alignment: .leading, spacing: 0) {
            if kind == .poem {
                poem
            } else if summary.headings.isEmpty {
                opening
            } else {
                headings
            }
        }
        .task(id: Reload(url: document.url, words: store.wordCount(of: document))) {
            summary = DocumentSummary(text: store.fileText(at: document.url))
        }
    }

    private func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    /// The poem as written: every line, indent and blank line kept, set in the book's face.
    private var poem: some View {
        Text(attributed(summary.body))
            .font(.system(size: 17, design: .serif))
            .lineSpacing(6)
            .foregroundStyle(Color(PaperTheme.ink))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headings: some View {
        let top = summary.headings.map(\.level).min() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            ContentsTitle()
            VStack(spacing: 2) {
                ForEach(summary.headings) { heading in
                    ChapterLine(number: nil, title: heading.title, page: heading.page, words: heading.words,
                                status: nil, indent: CGFloat(heading.level - top) * 18) {
                        store.goTo(OutlineHeading(id: heading.id, level: heading.level, title: heading.title), in: document.url)
                    }
                }
            }
            .padding(.horizontal, -8)
        }
    }

    /// No headings: the first lines, to read before opening it.
    @ViewBuilder private var opening: some View {
        if !summary.opening.isEmpty {
            Button { store.selection = .scene(document.url) } label: {
                Text(attributed(summary.opening))
                    .font(.system(size: 16, design: .serif))
                    .lineSpacing(6)
                    .lineLimit(8)
                    .foregroundStyle(Color(PaperTheme.ink))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(hovering ? Color(PaperTheme.hover) : .clear, in: rounded())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.horizontal, -8)
            .help("Open \(document.title)")
        }
    }
}

extension LibraryStore {
    /// Opens a single document at one of its headings: selects it, then brings the heading to
    /// the top of the page (a screenplay being read goes to its scene).
    func goTo(_ heading: OutlineHeading, in document: URL) {
        if selection != .scene(document) { selection = .scene(document) }
        let screenplay = document.pathExtension.lowercased() == ProseFile.fountain
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            if screenplay, viewMode == .read {
                NotificationCenter.default.post(name: ScreenplayReader.goToScene, object: heading.id)
                return
            }
            // The page's own text, which may be newer than the file: the same heading by order.
            let ranges = { (text: String) in screenplay ? Fountain.headings(in: text).map(\.range) : OutlineHeading.ranges(in: text) }
            guard let page = margin.textView,
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
}
