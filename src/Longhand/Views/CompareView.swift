import SwiftUI
import AppKit

/// File › Compare Versions…: in place of the page, every scene that changed between two
/// versions, with added words highlighted and removed words struck through. Only the paragraphs
/// that changed are shown; a ⋯ stands for those left out.
struct CompareView: View {
    @EnvironmentObject private var versions: VersionStore
    @EnvironmentObject private var store: LibraryStore
    @State private var confirmRestore = false

    var body: some View {
        if let detail = versions.detail {
            CompareSceneView(change: detail)
        } else {
            all
        }
    }

    private var all: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Changes from")
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .fixedSize()
                VersionMenu(selection: versions.compareFrom, allowsNow: false) { versions.compare(from: $0, to: versions.compareTo) }
                Text("to")
                    .foregroundStyle(Color(PaperTheme.secondary))
                VersionMenu(selection: versions.compareTo, allowsNow: true) { versions.compare(from: versions.compareFrom, to: $0) }
                if versions.comparingBusy {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                } else if let summary, let comparison = versions.comparison {
                    // Shown whole or not at all: in a narrow window it gives way first, and
                    // the buttons never wrap.
                    ViewThatFits(in: .horizontal) {
                        Text("\(Text(summary + ", ").foregroundStyle(Color(PaperTheme.secondary)))\(Text("+\(comparison.wordsAdded.formatted())").foregroundStyle(Color(PaperTheme.diffAddedMark))) \(Text("−\(comparison.wordsRemoved.formatted())").foregroundStyle(Color(PaperTheme.diffRemovedMark)))\(Text(" words").foregroundStyle(Color(PaperTheme.secondary)))")
                            .monospacedDigit()
                            .lineLimit(1)
                            .padding(.leading, 8)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .layoutPriority(-1)
                }
                Spacer(minLength: 12)
                if versions.compareTo == nil, let comparison = versions.comparison, !visible(comparison).isEmpty {
                    Button("Restore All…") { confirmRestore = true }
                        .buttonStyle(SquareButtonStyle())
                        .fixedSize()
                        .disabled(versions.busy || versions.comparingBusy)
                        .help("Restore the whole library from \(versions.fromTitle)")
                }
                Button("Back to Writing") { versions.comparing = false }
                    .buttonStyle(SquareButtonStyle())
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: Layout.chromeSize))
            .padding(.horizontal, 24)
            .frame(height: 44)
            .background(Color(PaperTheme.selection))
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

            if let comparison = versions.comparison, !visible(comparison).isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ComparePage(scenes: visible(comparison)) { versions.detail = $0 }
                        .frame(maxWidth: Layout.column)
                    Spacer(minLength: 0)
                }
            } else {
                VStack {
                    Spacer()
                    if versions.comparison != nil {
                        Text("No scene changed between these commits.")
                            .font(.system(size: Layout.chromeSize))
                            .foregroundStyle(Color(PaperTheme.secondary))
                    } else if !versions.comparingBusy {
                        Text("No commits yet")
                            .font(.system(size: Layout.chromeSize))
                            .foregroundStyle(Color(PaperTheme.secondary))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(PaperTheme.paper))
        .alert("Restore the whole library to \(versions.fromTitle)?", isPresented: $confirmRestore) {
            Button("Restore All") { store.restoreLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every scene, note and comment returns to that commit. The library as it is now is committed first, so you can come back to it.")
        }
    }

    /// Scenes whose words changed, or which were moved or renamed. A change of spacing alone
    /// isn't worth a heading.
    private func visible(_ comparison: Comparison) -> [Comparison.SceneChange] {
        comparison.scenes.filter { !$0.onlyMoved || $0.oldPath != nil || $0.status != .changed }
    }

    private var summary: String? {
        guard let comparison = versions.comparison else { return nil }
        let scenes = visible(comparison).count
        guard scenes > 0 else { return nil }
        return scenes == 1 ? "1 scene" : "\(scenes) scenes"
    }
}

/// A version chosen from a menu: Now (on the newer side), drafts, then every version.
private struct VersionMenu: View {
    @EnvironmentObject private var versions: VersionStore
    let selection: String?
    let allowsNow: Bool
    let choose: (String?) -> Void

    var body: some View {
        Menu {
            if allowsNow {
                Button("Now") { choose(nil) }
                Divider()
            }
            if !versions.branchTips.isEmpty {
                Section("Branches") {
                    ForEach(versions.branchTips, id: \.id) { tip in
                        Button(tip.title) { choose(tip.id) }
                    }
                }
            }
            let drafts = versions.allPoints.filter { !$0.drafts.isEmpty }
            if !drafts.isEmpty {
                Section("Tags") {
                    ForEach(drafts) { point in
                        Button("\(versions.label(of: point)), \(when(point.date))") { choose(point.id) }
                    }
                }
            }
            Section("Commits") {
                ForEach(versions.allPoints.prefix(100)) { point in
                    Button(point.note.isEmpty ? when(point.date) : "\(when(point.date)): \(point.note)") { choose(point.id) }
                }
            }
        } label: {
            Text(label)
                .font(.system(size: Layout.chromeSize, weight: .medium))
                .foregroundStyle(Color(PaperTheme.ink))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color(PaperTheme.card))
        .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
    }

    private var label: String {
        guard let selection else { return allowsNow ? "Now" : "—" }
        if let tip = versions.branchTips.first(where: { $0.id == selection }) { return tip.title }
        guard let point = versions.allPoints.first(where: { $0.id == selection }) else { return "—" }
        return versions.label(of: point)
    }

    private func when(_ date: Date) -> String {
        Moment.text(date)
    }
}

/// The changed scenes as one read-only page, set like any diff: the old paragraph on a red row,
/// the new one on a green row, the exact words that changed in a darker shade, − and + in the
/// gutter.
private struct ComparePage: NSViewRepresentable {
    let scenes: [Comparison.SceneChange]
    /// Whole scene, no headings (the one-scene view).
    var whole = false
    var open: ((Comparison.SceneChange) -> Void)?

    /// Cheap to compute on every SwiftUI update, unlike comparing the texts themselves.
    private var signature: [String] {
        scenes.map { "\($0.path)|\($0.wordsAdded)|\($0.wordsRemoved)|\($0.segments.count)" } + [whole ? "whole" : "list"]
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // The thin scroller, shown only while scrolling.
        scroll.verticalScroller?.controlSize = .small
        scroll.drawsBackground = false
        // TextKit 2, like the editors: only what is on screen is laid out (TextKit 1 laid out
        // the whole comparison in the background, holding up everything else for a moment).
        // Nothing here may touch `layoutManager`, which would switch the view back mid-draw.
        let page = DiffTextView(usingTextLayoutManager: ProcessInfo.processInfo.environment["LONGHAND_TK1"] != "1")
        page.isEditable = false
        page.isSelectable = true
        page.drawsBackground = false
        page.isVerticallyResizable = true
        page.autoresizingMask = [.width]
        page.textContainer?.widthTracksTextView = true
        page.textContainer?.lineFragmentPadding = 0
        page.textContainerInset = NSSize(width: Layout.gutter, height: 40)
        page.selectedTextAttributes = [.backgroundColor: PaperTheme.selection]
        page.linkTextAttributes = [.foregroundColor: PaperTheme.ink, .cursor: NSCursor.pointingHand]
        page.delegate = context.coordinator
        scroll.documentView = page
        context.coordinator.open = open
        context.coordinator.shown = scenes
        context.coordinator.signature = signature
        fill(page)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.open = open
        let now = signature
        guard context.coordinator.signature != now, let page = scroll.documentView as? DiffTextView else { return }
        context.coordinator.signature = now
        context.coordinator.shown = scenes
        fill(page)
        page.scrollToBeginningOfDocument(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown: [Comparison.SceneChange] = []
        var signature: [String] = []
        var open: ((Comparison.SceneChange) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let index = link as? Int, shown.indices.contains(index) else { return false }
            open?(shown[index])
            return true
        }
    }

    private func fill(_ page: DiffTextView) {
        let built = CompareText.build(scenes, whole: whole)
        page.string = built.text
        guard let storage = page.textStorage else { return }
        MarkdownStyler.apply(to: storage)
        storage.beginEditing()
        // Headings line up with the prose (the styler indents it to make room for hung symbols).
        let indent = built.rows.first.flatMap { row -> CGFloat? in
            row.range.location < storage.length
                ? (storage.attribute(.paragraphStyle, at: row.range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent
                : nil
        } ?? Layout.hang
        for (index, range) in built.headings.enumerated() {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacingBefore = index == 0 ? 0 : 40
            style.paragraphSpacing = 14
            storage.setAttributes([
                .font: NSFont.systemFont(ofSize: Layout.chromeSize, weight: .semibold),
                .foregroundColor: PaperTheme.ink,
                .paragraphStyle: style
            ], range: range)
        }
        for (index, range) in built.titles.enumerated() where open != nil {
            storage.addAttributes([.link: index, .toolTip: "Open the whole scene"], range: range)
        }
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: Layout.chromeSize, weight: .regular)
        for range in built.counts { storage.addAttributes([.font: countFont, .foregroundColor: PaperTheme.secondary], range: range) }
        for range in built.plusCounts { storage.addAttributes([.font: countFont, .foregroundColor: PaperTheme.diffAddedMark], range: range) }
        for range in built.minusCounts { storage.addAttributes([.font: countFont, .foregroundColor: PaperTheme.diffRemovedMark], range: range) }
        for range in built.elisions { storage.addAttribute(.foregroundColor, value: PaperTheme.tertiary, range: range) }
        storage.endEditing()
        page.rows = built.rows
        page.words = built.words
    }
}

/// Draws diff rows and word marks behind the text, only for what is on screen, so a long
/// comparison scrolls as lightly as a short one.
final class DiffTextView: NSTextView {
    struct Row {
        let range: NSRange
        let added: Bool
    }

    struct Word {
        let range: NSRange
        let added: Bool
    }

    /// Sorted by location.
    var rows: [Row] = [] { didSet { needsDisplay = true } }
    var words: [Word] = [] { didSet { needsDisplay = true } }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let origin = textContainerOrigin
        let width = textContainer?.size.width ?? bounds.width
        let visible = characterRange(in: rect)
        let markFont = NSFont.monospacedSystemFont(ofSize: Layout.chromeSize, weight: .medium)

        for row in Self.slice(rows, by: \.range, within: visible) {
            var first = true
            for line in lineBands(of: row.range) {
                let band = NSRect(x: origin.x - 8, y: line.minY, width: width + 16, height: line.height)
                guard band.intersects(rect) else { first = false; continue }
                (row.added ? PaperTheme.diffAddedRow : PaperTheme.diffRemovedRow).setFill()
                band.fill()
                if first {
                    let mark = NSAttributedString(string: row.added ? "+" : "−", attributes: [
                        .font: markFont,
                        .foregroundColor: row.added ? PaperTheme.diffAddedMark : PaperTheme.diffRemovedMark
                    ])
                    mark.draw(at: NSPoint(x: origin.x + 4, y: band.minY + (band.height - mark.size().height) / 2))
                    first = false
                }
            }
        }
        for word in Self.slice(words, by: \.range, within: visible) {
            (word.added ? PaperTheme.diffAddedWord : PaperTheme.diffRemovedWord).setFill()
            for line in lineRects(of: word.range) {
                let trim = max(0, (line.height - Layout.textSize * 1.3) / 2)
                NSBezierPath(rect: line.insetBy(dx: -1, dy: trim)).fill()
            }
        }
    }

    /// The items whose ranges meet `visible`, found by binary search (items are sorted and
    /// don't overlap).
    static func slice<T>(_ items: [T], by key: KeyPath<T, NSRange>, within visible: NSRange) -> ArraySlice<T> {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(items[mid][keyPath: key]) < visible.location { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < items.count, items[end][keyPath: key].location <= NSMaxRange(visible) { end += 1 }
        return items[low..<end]
    }
}

/// Lays out the comparison as text, with the ranges to style.
enum CompareText {
    struct Built {
        var text = ""
        var headings: [NSRange] = []
        /// The scene's name in each heading (clickable).
        var titles: [NSRange] = []
        var counts: [NSRange] = []
        var plusCounts: [NSRange] = []
        var minusCounts: [NSRange] = []
        var elisions: [NSRange] = []
        var rows: [DiffTextView.Row] = []
        var words: [DiffTextView.Word] = []

        var added: [NSRange] { words.filter(\.added).map(\.range) }
        var removed: [NSRange] { words.filter { !$0.added }.map(\.range) }
    }

    private typealias Line = [Comparison.Segment]

    static func build(_ scenes: [Comparison.SceneChange], whole: Bool = false) -> Built {
        var built = Built()
        let out = NSMutableString()
        func append(_ string: String) -> NSRange {
            let range = NSRange(location: out.length, length: (string as NSString).length)
            out.append(string)
            return range
        }
        func hasText(_ parts: [Comparison.Segment], _ kind: Comparison.Segment.Kind) -> Bool {
            parts.contains { $0.kind == kind && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        /// One row of a diff: the paragraph as it was (`added == false`) or as it is.
        func row(_ line: Line, added: Bool) {
            let start = out.length
            for part in line where part.kind != (added ? .removed : .added) {
                let range = append(part.text)
                if part.kind != .same, !part.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    built.words.append(.init(range: range, added: added))
                }
            }
            built.rows.append(.init(range: NSRange(location: start, length: out.length - start), added: added))
            _ = append("\n")
        }

        for scene in scenes {
            if !whole {
                if out.length > 0 { _ = append("\n") }
                let headingStart = out.length
                built.titles.append(append(scene.title))
                _ = append("   ")
                switch scene.status {
                case .added: built.counts.append(append("new scene  "))
                case .removed: built.counts.append(append("removed  "))
                case .changed where scene.oldPath != nil: built.counts.append(append(scene.onlyMoved ? "moved or renamed" : "moved or renamed  "))
                case .changed: break
                }
                if !scene.onlyMoved {
                    built.plusCounts.append(append("+\(scene.wordsAdded.formatted())"))
                    _ = append(" ")
                    built.minusCounts.append(append("−\(scene.wordsRemoved.formatted())"))
                }
                _ = append("\n")
                built.headings.append(NSRange(location: headingStart, length: out.length - headingStart))
            }

            var kept = false
            var skipped = false
            for line in split(scene.segments) {
                let blank = line.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                if blank { continue }
                let added = hasText(line, .added), removed = hasText(line, .removed)
                guard added || removed else {
                    if whole {
                        if kept { _ = append("\n") }
                        _ = append(line.map(\.text).joined())
                        _ = append("\n")
                        kept = true
                    } else {
                        skipped = true
                    }
                    continue
                }
                if kept || skipped { _ = append("\n") }
                if skipped {
                    built.elisions.append(append("⋯"))
                    _ = append("\n\n")
                }
                // Old above new; a paragraph only added or only cut has one row.
                let existed = removed || hasText(line, .same)
                let remains = added || hasText(line, .same)
                if existed && (removed || !added) { row(line, added: false) }
                if remains && (added || !removed) { row(line, added: true) }
                kept = true
                skipped = false
            }
            if skipped && kept {
                _ = append("\n")
                built.elisions.append(append("⋯"))
                _ = append("\n")
            }
        }
        built.text = out as String
        return built
    }

    /// Splits the segments into paragraphs (lines), keeping each piece's kind.
    private static func split(_ segments: [Comparison.Segment]) -> [Line] {
        var lines: [Line] = [[]]
        for segment in segments {
            let parts = segment.text.components(separatedBy: "\n")
            for (index, part) in parts.enumerated() {
                if index > 0 { lines.append([]) }
                if !part.isEmpty { lines[lines.count - 1].append(.init(kind: segment.kind, text: part)) }
            }
        }
        return lines
    }
}

/// One scene from the comparison, all of it, with the changes marked; and a way to put it back.
private struct CompareSceneView: View {
    @EnvironmentObject private var versions: VersionStore
    @EnvironmentObject private var store: LibraryStore
    let change: Comparison.SceneChange

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Two texts, so a long scene name gives way before what it is compared with.
                HStack(spacing: 0) {
                    Text(change.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(", compared with \(Text(versions.fromTitle).fontWeight(.semibold))")
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .foregroundStyle(Color(PaperTheme.ink))
                Spacer(minLength: 12)
                Button("All Changes") { versions.detail = nil }
                    .buttonStyle(SquareButtonStyle())
                Button("Back to Writing") { versions.comparing = false }
                    .buttonStyle(SquareButtonStyle())
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
                if versions.compareTo == nil, change.status != .added, !change.onlyMoved {
                    Button("Restore This Scene") { store.restoreScene(change) }
                        .buttonStyle(SquareButtonStyle(primary: true))
                        .help("Restore this scene from \(versions.fromTitle). The current text is kept in its history.")
                }
            }
            .font(.system(size: Layout.chromeSize))
            .padding(.horizontal, 24)
            .frame(height: 44)
            .background(Color(PaperTheme.selection))
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ComparePage(scenes: [change], whole: true)
                    .frame(maxWidth: Layout.column)
                Spacer(minLength: 0)
            }
        }
        .background(Color(PaperTheme.paper))
    }
}
