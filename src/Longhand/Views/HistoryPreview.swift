import SwiftUI
import AppKit

/// An earlier version of the open scene, shown read-only in place of the editor. Paragraphs
/// that differ from the scene as it is now are highlighted.
struct HistoryPreview: View {
    @EnvironmentObject private var store: LibraryStore
    let scene: Scene
    let version: HistoryStore.Version

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    Text(scene.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(" as it was \(Text(when).fontWeight(.semibold)), \(Estimate.words(version.words))")
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.ink))
                Spacer()
                Button("Back to Writing") { store.historyPreview = nil }
                    .buttonStyle(SquareButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Restore") { store.restore(version) }
                    .buttonStyle(SquareButtonStyle(primary: true))
                    .help("Restore this autosave. The current text is kept in the scene’s history.")
            }
            .padding(.horizontal, 24)
            .frame(height: 44)
            .background(Color(PaperTheme.selection))
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ReadOnlyPage(text: store.history.text(of: version), current: store.text)
                    .frame(maxWidth: Layout.column)
                Spacer(minLength: 0)
            }
        }
        .background(Color(PaperTheme.paper))
    }

    private var when: String {
        Moment.text(version.date, inSentence: true)
    }
}

/// Styled Markdown that can be read and copied but not edited.
private struct ReadOnlyPage: NSViewRepresentable {
    let text: String
    let current: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // The thin scroller, shown only while scrolling.
        scroll.verticalScroller?.controlSize = .small
        scroll.drawsBackground = false
        let page = HighlightTextView()
        page.isEditable = false
        page.isSelectable = true
        page.drawsBackground = false
        page.isVerticallyResizable = true
        page.autoresizingMask = [.width]
        page.textContainer?.widthTracksTextView = true
        page.textContainer?.lineFragmentPadding = 0
        page.textContainerInset = NSSize(width: Layout.gutter, height: 56)
        page.selectedTextAttributes = [.backgroundColor: PaperTheme.selection]
        scroll.documentView = page
        fill(page)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let page = scroll.documentView as? HighlightTextView, !(page.string as NSString).isEqual(to: text) else { return }
        fill(page)
    }

    private func fill(_ page: HighlightTextView) {
        page.string = text
        if let storage = page.textStorage { MarkdownStyler.apply(to: storage) }
        // Paragraphs not found, word for word, in the scene as it is now.
        let now = Set(current.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let string = text as NSString
        var changed: [(NSRange, NSColor)] = []
        var location = 0
        while location < string.length {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            var content = line
            while content.length > 0, [0x0A, 0x0D].contains(string.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            let trimmed = string.substring(with: content).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !now.contains(trimmed) { changed.append((content, PaperTheme.highlight)) }
            location = NSMaxRange(line)
        }
        page.highlights = changed
    }
}
