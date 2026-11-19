import SwiftUI
import AppKit

/// The right-hand margin: Comments, Notes and Versions.
struct MarginView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    @AppStorage("marginTab") private var tab = MarginStore.Tab.comments.rawValue
    /// The margin has the keyboard (its chosen tab is framed).
    @State private var hasKeys = false

    var body: some View {
        // One panel, tabs to foot, the same height as the page and the contents.
        VStack(spacing: 0) {
            tabs
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
            Group {
                if current == .notes {
                    NotesPane()
                } else if current == .changes {
                    ChangesPane(changes: store.versions.changes)
                } else {
                    CommentsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(PaperTheme.well))
        // The margin's keys, while it has the keyboard (Go › Margin).
        .background(PaneKeys(pane: .margin, store: store, onKey: key, onFocus: { on in
            if hasKeys != on { hasKeys = on }
        }))
        .panel()
    }

    /// The tabs on offer, in order.
    private var shownTabs: [MarginStore.Tab] { inLibrary ? [.notes, .changes] : [.comments, .notes, .changes] }

    /// The margin's keys: ← → change tab; on Comments ↑ ↓ go through the comments (each
    /// one's passage comes into view) and Return edits the chosen one; on Notes Return goes
    /// into the note.
    private func key(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 123, 124:
            let tabs = shownTabs
            guard let index = tabs.firstIndex(of: current) else { return false }
            tab = tabs[(index + (event.keyCode == 124 ? 1 : -1) + tabs.count) % tabs.count].rawValue
        case 125, 126:
            guard current == .comments else { return false }
            let open = margin.comments.filter { !$0.resolved }
            guard !open.isEmpty else { return true }
            let index = open.firstIndex { $0.id == margin.focused }
            let step = event.keyCode == 125 ? 1 : -1
            let next = index.map { min(max($0 + step, 0), open.count - 1) } ?? (step > 0 ? 0 : open.count - 1)
            margin.scrollTo(open[next].id)
        case 36, 76:
            switch current {
            case .comments:
                guard let id = margin.focused else { return false }
                margin.editingRequest = id
            case .notes:
                Panes.typeNote.send()
            default:
                return false
            }
        default:
            return false
        }
        return true
    }

    /// The tab shown. History became part of Versions (2026-11-08).
    private var current: MarginStore.Tab {
        let chosen = MarginStore.Tab(rawValue: tab) ?? .comments
        if inLibrary, chosen == .comments { return .notes }
        return chosen == .history ? .changes : chosen
    }

    /// In the Library the column lists stories and nothing is open to comment on, so the
    /// margin shows the chosen story's notes and versions only (the remembered tab is kept
    /// for when a story is opened).
    private var inLibrary: Bool { store.openBook == nil }

    /// A strip of square segments across the top of the panel, the chosen one pressed in;
    /// hairlines between them, the panel's own frame around them.
    private var tabs: some View {
        HStack(spacing: 0) {
            if !inLibrary {
                tabButton(.comments, title: "Comments", count: openCount)
                divider
            }
            tabButton(.notes, title: "Notes", count: nil)
            divider
            tabButton(.changes, title: "Changes", count: nil) {
                ChangeCount(changes: store.versions.changes, selection: store.selection)
            }
        }
        .frame(height: Layout.headerHeight)
    }

    private var divider: some View {
        Rectangle().fill(Color(PaperTheme.hairline)).frame(width: 1)
    }

    private var openCount: Int? {
        let count = margin.comments.filter { !$0.resolved }.count
        return count > 0 ? count : nil
    }

    private func tabButton(_ value: MarginStore.Tab, title: String, count: Int?) -> some View {
        tabButton(value, title: title, count: count) { EmptyView() }
    }

    /// Segments are as wide as their labels need, sharing what is left: with four tabs,
    /// equal widths cut "Comments 2" short.
    private func tabButton<Extra: View>(_ value: MarginStore.Tab, title: String, count: Int?,
                                        @ViewBuilder extra: () -> Extra) -> some View {
        let selected = current == value
        return Button {
            tab = value.rawValue
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .fontWeight(selected ? .semibold : .medium)
                    .foregroundStyle(Color(selected ? PaperTheme.ink : PaperTheme.secondary))
                if let count { Badge("\(count)") }
                extra()
            }
            .font(.system(size: Layout.chromeSize))
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color(PaperTheme.controlOn) : .clear)
            .overlay(Rectangle().strokeBorder(Color(PaperTheme.controlOnBorder), lineWidth: selected && hasKeys ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The Changes tab's count: scenes changed since the last version. Its own view, so only it
/// redraws when the count moves.
private struct ChangeCount: View {
    @ObservedObject var changes: ChangeState
    let selection: Selection?

    /// Changed scenes in what is selected (none shown for a single scene: its own changes are
    /// right there in the tab).
    private var count: Int {
        switch selection {
        case .chapter(let url), .book(let url): return changes.changes(inside: url).filter { !$0.onlyMoved }.count
        case nil: return changes.count
        case .scene: return 0
        }
    }

    var body: some View {
        if count > 0 { Badge("\(count)") }
    }
}

// MARK: - Comments

/// While a scene or a chapter's page is open, its comments are a list in page order, each
/// with the passage it is about; choosing one shows its passage. Elsewhere (a chapter's cards
/// or a book), the comments of every scene inside are listed; choosing one opens its scene.
private struct CommentsPane: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore

    /// The list follows the page while a scene, a chapter's page or a story's Page is open.
    private var sceneOpen: Bool {
        switch store.selection {
        case .scene: return true
        case .chapter: return store.viewMode != .cards
        case .book: return store.viewMode == .page && store.openBook != nil
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if sceneOpen {
                if margin.showResolved {
                    resolvedList
                } else {
                    commentList
                }
                footer
            } else {
                ScopeComments()
            }
        }
    }

    /// Open comments in the order their passages come on the page (the store keeps them so).
    private var open: [SceneComment] { margin.comments.filter { !$0.resolved } }
    private var resolved: [SceneComment] { margin.comments.filter(\.resolved) }

    private var commentList: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(open) { comment in
                        CommentCard(comment: comment, focused: comment.id == margin.focused)
                            .id(comment.id)
                        Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: margin.focused) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id) }
            }
        }
    }

    private var resolvedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(resolved) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        CommentContext(comment: comment, focused: false)
                        Text(comment.text)
                            .font(.system(size: Layout.chromeSize))
                            .foregroundStyle(Color(PaperTheme.ink))
                            .lineSpacing(3)
                        HStack {
                            Text(CommentDate.text(comment.created))
                                .font(.system(size: Layout.detailSize, weight: .medium))
                                .foregroundStyle(Color(PaperTheme.secondary))
                            Spacer()
                            Button("Reopen") { margin.setResolved(false, comment.id) }
                                .buttonStyle(PlainSquareButtonStyle(height: 24))
                            Button("Delete") { margin.delete(comment.id) }
                                .buttonStyle(PlainSquareButtonStyle(height: 24))
                        }
                    }
                    .padding(.top, Layout.pad)
                    .padding(.leading, Layout.pad)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
                }
            }
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var footer: some View {
        if !resolved.isEmpty {
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
            HStack {
                Button(margin.showResolved ? "Hide Resolved" : "Show \(resolved.count) Resolved") {
                    margin.showResolved.toggle()
                }
                .buttonStyle(PlainSquareButtonStyle(height: 24, horizontalPadding: 6))
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: Layout.barHeight)
        }
    }
}

/// One comment in the list: the passage it is about, then the comment. The comment in focus
/// is shaded and shows Resolve and a menu.
private struct CommentCard: View {
    @EnvironmentObject private var margin: MarginStore
    let comment: SceneComment
    let focused: Bool

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if comment.isDetached {
                Text("The text this was on is gone.")
                    .font(.system(size: Layout.detailSize))
                    .foregroundStyle(Color(PaperTheme.secondary))
            } else if !comment.quote.isEmpty {
                CommentContext(comment: comment, focused: focused)
                    .padding(.bottom, 3)
            }
            TextField("Comment", text: $text, prompt: .placeholder("Comment"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.ink))
                .lineSpacing(2)
                .focused($editing)
                // Return finishes the comment and goes back to writing; ⇧ or ⌥ Return starts a
                // new line in it. Escape finishes it too.
                .onKeyPress(keys: [.return, .escape], phases: .down) { press in
                    if press.key == .return, !press.modifiers.isDisjoint(with: [.shift, .option]) {
                        // Left alone, the field would end editing and select its text.
                        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                        return .handled
                    }
                    editing = false
                    margin.finishEditing(comment.id)
                    return .handled
                }
                .onChange(of: text) { _, value in margin.setText(value, of: comment.id) }
                .onChange(of: editing) { _, now in
                    // Clicking into the comment to edit it also brings its passage into view.
                    // (Not for a comment just made: its passage is the selection on screen.)
                    if now, margin.focused != comment.id { margin.scrollTo(comment.id) }
                    if !now { margin.dropIfEmpty(comment.id) }
                }

            HStack(spacing: 2) {
                Text(CommentDate.text(comment.created))
                    .font(.system(size: Layout.detailSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.secondary))
                Spacer()
                if focused {
                    SquareToolbarButton(icon: .checkmark, tooltip: "Resolve", size: 22, iconSize: 13) {
                        margin.setResolved(true, comment.id)
                    }
                    .frame(width: 22, height: 20)
                    SquareToolbarButton(
                        icon: .more,
                        tooltip: "More",
                        size: 22,
                        iconSize: 13,
                        menuItems: [
                            ToolbarMenuItem(title: "Copy Comment", separatorAfter: true) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(comment.text, forType: .string)
                            },
                            ToolbarMenuItem(title: "Delete Comment") { margin.delete(comment.id) }
                        ]
                    )
                    .frame(width: 22, height: 20)
                }
            }
            .frame(height: 20)
        }
        .padding(.top, Layout.pad)
        .padding(.leading, Layout.pad)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Color(PaperTheme.commentFocus) : .clear)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { margin.scrollTo(comment.id) })
        .onAppear {
            text = comment.text
            if margin.editingRequest == comment.id {
                margin.editingRequest = nil
                DispatchQueue.main.async { editing = true }
            }
        }
        .onChange(of: margin.editingRequest) { _, request in
            if request == comment.id {
                margin.editingRequest = nil
                editing = true
            }
        }
    }
}

/// The comments of every scene in the selected chapter or book, by scene. Choosing one opens
/// the scene with the comment in focus.
private struct ScopeComments: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore

    var body: some View {
        let groups = scenes.compactMap { scene -> (Scene, [SceneComment])? in
            // The margin already counts each scene's open comments: read only the files of
            // scenes that have some (this list was reading every scene's file on each redraw).
            guard (margin.openCounts[scene.url] ?? 0) > 0 else { return nil }
            let open = margin.readComments(for: scene.url).filter { !$0.resolved }
            return open.isEmpty ? nil : (scene, open)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(groups, id: \.0.id) { scene, comments in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scene.title)
                            .font(.system(size: Layout.detailSize, weight: .semibold))
                            .foregroundStyle(Color(PaperTheme.secondary))
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)
                        ForEach(comments) { comment in
                            Button {
                                open(comment, in: scene)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    if !comment.quote.isEmpty { CommentContext(comment: comment, focused: false) }
                                    Text(comment.text)
                                        .font(.system(size: Layout.chromeSize))
                                        .foregroundStyle(Color(PaperTheme.ink))
                                        .lineSpacing(3)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(PlainSquareButtonStyle(height: 0))
                        }
                    }
                }
            }
            .padding(.horizontal, Layout.pad - 8)
            .padding(.vertical, Layout.pad)
        }
        .scrollIndicators(.never)
    }

    private var scenes: [Scene] {
        guard let library = store.library else { return [] }
        switch store.selection {
        case .chapter(let url):
            return store.chapter(for: url)?.scenes ?? []
        case .book(let url):
            return store.book(for: url)?.chapters.flatMap(\.scenes) ?? []
        default:
            return library.books.flatMap(\.chapters).flatMap(\.scenes)
        }
    }

    private func open(_ comment: SceneComment, in scene: Scene) {
        margin.revealOnLoad = comment.id
        store.selection = .scene(scene.url)
    }
}

/// The passage a comment is on, in its line: a little of the text either side (from the
/// words saved with the comment), the passage itself highlighted as on the page, all beside
/// a thin rule like a quotation.
struct CommentContext: View {
    let comment: SceneComment
    let focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Color(PaperTheme.frame))
                .frame(width: 2)
            line
                .font(.system(size: Layout.detailSize))
                .lineSpacing(2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var line: Text {
        // The excerpt is read, not edited: it shows as the page reads (`plain`).
        let before = Self.plain(Self.lead(comment.prefix)), after = Self.plain(Self.tail(comment.suffix))
        var passage = AttributedString(Self.plain(comment.quote))
        passage.foregroundColor = Color(PaperTheme.ink)
        passage.backgroundColor = Color(focused ? PaperTheme.highlightFocus : PaperTheme.highlight)
        var start = AttributedString(before), end = AttributedString(after)
        start.foregroundColor = Color(PaperTheme.secondary)
        end.foregroundColor = Color(PaperTheme.secondary)
        return Text(start + passage + end)
    }

    private static let footnoteCall = try! NSRegularExpression(pattern: #"\[\^[^\]\s]*\]?"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\([^)\n]*\)?"#)
    private static let underscore = try! NSRegularExpression(pattern: #"(?<![\w])_+|_+(?![\w])"#)

    /// Markdown's symbols left out, as the reading page leaves them out: bold and italic
    /// marks, footnote calls, code ticks, and a link's address (its words stay). The quote
    /// may be cut mid-symbol, so half a call or link goes too.
    static func plain(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
        func replace(_ pattern: NSRegularExpression, with template: String) {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: template)
        }
        replace(footnoteCall, with: "")
        replace(link, with: "$1")
        replace(underscore, with: "")
        return out
    }

    /// The words before the passage on its line: from the last line break, else from a whole
    /// word, with "…" when cut.
    static func lead(_ prefix: String) -> String {
        if let newline = prefix.lastIndex(where: \.isNewline) {
            return String(prefix[prefix.index(after: newline)...]).trimmingLeadingMarkdown()
        }
        guard prefix.count >= SceneComment.contextLength - 1 else { return prefix.trimmingLeadingMarkdown() }
        guard let space = prefix.firstIndex(of: " ") else { return "…" + prefix }
        return "…" + prefix[prefix.index(after: space)...]
    }

    /// The words after the passage, to the end of its line or the last whole word.
    static func tail(_ suffix: String) -> String {
        if let newline = suffix.firstIndex(where: \.isNewline) { return String(suffix[..<newline]) }
        guard suffix.count >= SceneComment.contextLength - 1 else { return suffix }
        guard let space = suffix.lastIndex(of: " ") else { return suffix + "…" }
        return suffix[..<space] + "…"
    }
}

private extension String {
    /// Without a heading's #, a quotation's > or a list's marker at the start of a line.
    func trimmingLeadingMarkdown() -> String {
        var text = Substring(self)
        while let first = text.first, "#>-*+ \t".contains(first) { text = text.dropFirst() }
        return String(text)
    }
}

/// A moment with its time, written one way everywhere: "Today, 14:05", "Yesterday, 14:05",
/// "5 Nov, 14:05", and the year only when it isn't this one. In a sentence: "today at 14:05".
enum Moment {
    static func text(_ date: Date, inSentence: Bool = false) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(date) {
            day = inSentence ? "today" : "Today"
        } else if calendar.isDateInYesterday(date) {
            day = inSentence ? "yesterday" : "Yesterday"
        } else {
            day = CommentDate.text(date)
        }
        return inSentence ? "\(day) at \(time)" : "\(day), \(time)"
    }
}

enum CommentDate {
    static func text(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Notes

/// Notes at three levels: the open scene, its chapter, and the book. Scene and chapter notes
/// are written straight into the margin; book notes are named files, opened in the margin.
private struct NotesPane: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    @State private var renameTarget: BookNote?

    var body: some View {
        VStack(spacing: 0) {
            if let note = margin.openBookNote {
                BookNoteEditor(note: note, rename: { renameTarget = note })
            } else {
                ScrollView {
                    // Only the open layer's notes (owner, 2026-11-14): a scene's on a scene, a
                    // chapter's on a chapter, the story's on the story. A single document (a
                    // screenplay among them) is the story itself.
                    VStack(alignment: .leading, spacing: 18) {
                        if let document = openDocument {
                            documentSection(document)
                        } else if let sceneURL = margin.sceneURL {
                            section(sceneTitle, kind: names.scene, first: true) {
                                SceneDetails(scene: sceneURL)
                                    .id(sceneURL)
                                label("Note")
                                NoteField(
                                    placeholder: "Notes on this \(names.scene.lowercased())",
                                    text: margin.sceneNote,
                                    onChange: margin.setSceneNote
                                )
                                .id(sceneURL)
                            }
                        } else if let chapterURL = margin.chapterURL {
                            section(store.chapter(for: chapterURL)?.title ?? names.chapter, kind: names.chapter, first: true) {
                                StatusSegments(url: chapterURL)
                                label("Note")
                                NoteField(
                                    placeholder: "Notes on this \(names.chapter.lowercased())",
                                    text: margin.chapterNote,
                                    onChange: margin.setChapterNote
                                )
                                .id(chapterURL)
                            }
                        } else if let bookURL = margin.bookURL {
                            // In the Library the story's own page is beside this, its name and
                            // target on it: the section doesn't say them again.
                            section(store.openBook == nil ? nil : store.book(for: bookURL)?.title ?? "Story", kind: "Story",
                                    first: true) {
                                if store.openBook != nil {
                                    BookTarget(book: bookURL)
                                        .id(bookURL)
                                }
                                // A story has many notes, each its own file in its Notes folder
                                // (a scene or chapter has one, typed in place).
                                storyNotes
                            }
                        }
                    }
                    // Full width, so a short section sits at the left, not in the middle.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Layout.pad)
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { margin.reloadBookNotes() }
        .sheet(item: $renameTarget) { note in
            RenameSheet(title: note.title) { margin.renameBookNote(note, to: $0) }
        }
    }

    /// The open single document (or screenplay), whose layer is the story.
    private var openDocument: Book? {
        guard let sceneURL = margin.sceneURL, let book = store.location(ofScene: sceneURL)?.book,
              book.document?.url == sceneURL else { return nil }
        return book
    }

    /// A single document: one section for the story, under its form ("Screenplay"): its
    /// target, the note typed in place (where Join into One Document gathered the old notes),
    /// then the story's note files.
    private func documentSection(_ book: Book) -> some View {
        let form = store.margin.info(for: book.url).form
        return section(book.title, kind: form?.title ?? "Story", first: true) {
            BookTarget(book: book.url)
                .id(book.url)
            label("Note")
            NoteField(
                placeholder: "Notes on this \((form?.title ?? "story").lowercased())",
                text: margin.sceneNote,
                onChange: margin.setSceneNote
            )
            .id(book.url)
            storyNotes
        }
    }

    /// The story's notes, each a file in its Notes folder, and New Note.
    private var storyNotes: some View {
        Group {
            label("Notes")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(margin.bookNotes) { note in
                    bookNoteRow(note)
                }
                newNoteRow
            }
            .padding(.horizontal, -8)
        }
    }

    private var sceneTitle: String {
        margin.sceneURL.flatMap { store.scene(for: $0)?.title } ?? names.scene
    }

    /// The open story's words for its parts (a notebook: folders and notes).
    private var names: PartNames {
        store.names(of: margin.sceneURL.flatMap { store.location(ofScene: $0)?.book.url }
            ?? margin.chapterURL.map { $0.deletingLastPathComponent().canonical })
    }

    private func label(_ text: String) -> some View {
        FieldLabel(text).padding(.top, 6)
    }

    /// A section: what the notes belong to (its kind small, its name in ink, larger than the
    /// labels), then its fields; a hairline above every section but the first.
    /// With no title, only the fields (the story in the Library, whose page says its name).
    private func section<Content: View>(_ title: String?, kind: String, first: Bool = false,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !first {
                Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
                    .padding(.horizontal, -Layout.pad)
                    .padding(.bottom, 10)
            }
            if let title {
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind)
                        .font(.system(size: Layout.smallSize, weight: .medium))
                        .foregroundStyle(Color(PaperTheme.secondary))
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(PaperTheme.ink))
                        .lineLimit(2)
                }
                .padding(.bottom, 4)
            }
            content()
        }
    }

    private func bookNoteRow(_ note: BookNote) -> some View {
        Button {
            margin.openNote(note)
        } label: {
            HStack(spacing: 8) {
                Symbol.document.view(size: 13)
                    .foregroundStyle(Color(PaperTheme.tertiary))
                Text(note.title)
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(CommentDate.text(note.modified))
                    .font(.system(size: Layout.smallSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PlainSquareButtonStyle(height: 28))
        .contextMenu {
            Button("Rename…") { renameTarget = note }
            Button("Show in Finder") { store.reveal(note.url) }
            Divider()
            Button("Move to Trash") { margin.trashBookNote(note) }
        }
    }

    /// New Note, under the story's notes, so it is plain whose note it makes.
    private var newNoteRow: some View {
        Button {
            margin.createBookNote()
        } label: {
            HStack(spacing: 8) {
                Symbol.add.view(size: 12, weight: .semibold)
                    .frame(width: 13)
                Text("New Note")
                    .fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(PaperTheme.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PlainSquareButtonStyle(height: 28))
        .help("A note on the whole story, kept as a file in its Notes folder")
    }
}

/// A note written in place: plain text, saved as you type.
private struct NoteField: View {
    let placeholder: String
    let text: String
    let onChange: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, prompt: .placeholder(placeholder), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(Color(PaperTheme.ink))
            .lineSpacing(4)
            .lineLimit(3...)
            .focused($focused)
            .fieldBox(focused: focused, minHeight: 64)
            .onReceive(Panes.typeNote) { focused = true }
            .onAppear { draft = text }
            .onChange(of: draft) { _, value in onChange(value) }
    }
}

/// A book note opened in the margin.
private struct BookNoteEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    let note: BookNote
    let rename: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    margin.openNote(nil)
                } label: {
                    Symbol.caretRight.view(size: 10)
                        .rotationEffect(.degrees(180))
                }
                .buttonStyle(PlainSquareButtonStyle(height: 26, horizontalPadding: 0))
                .help("All notes")

                Text(note.title)
                    .font(.system(size: Layout.chromeSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1)
                Spacer()
                SquareToolbarButton(
                    icon: .more,
                    tooltip: "More",
                    size: 26,
                    iconSize: 14,
                    menuItems: [
                        ToolbarMenuItem(title: "Rename…") { rename() },
                        ToolbarMenuItem(title: "Show in Finder", separatorAfter: true) { store.reveal(note.url) },
                        ToolbarMenuItem(title: "Move to Trash") { margin.trashBookNote(note) }
                    ]
                )
                .frame(width: 26, height: 26)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

            TextEditor(text: Binding(
                get: { margin.openBookNoteText },
                set: { margin.setOpenBookNoteText($0) }
            ))
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(Color(PaperTheme.ink))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            // The editor sets its text 5pt in from its own edge.
            .padding(.horizontal, Layout.pad - 5)
            .padding(.vertical, Layout.pad)
        }
    }
}

/// Draft | Revised | Done for a scene or chapter; click the chosen one again to clear it.
private struct StatusSegments: View {
    @EnvironmentObject private var margin: MarginStore
    let url: URL

    var body: some View {
        let info = margin.info(for: url)
        HStack(spacing: 0) {
            ForEach(Array(SceneInfo.Status.allCases.enumerated()), id: \.element) { index, status in
                if index > 0 { Rectangle().fill(Color(PaperTheme.cardBorder)).frame(width: 1) }
                Button {
                    var changed = margin.info(for: url)
                    changed.status = info.status == status ? nil : status
                    margin.setInfo(changed, for: url)
                } label: {
                    Text(status.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(info.status == status ? PaperTheme.ink : PaperTheme.secondary))
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        .background(info.status == status ? Color(PaperTheme.selection) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 24)
        .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
        .fixedSize()
    }
}

/// A scene's status, synopsis and word target, at the top of its notes.
private struct SceneDetails: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    let scene: URL

    @State private var synopsis = ""
    @State private var target = ""
    @FocusState private var editing: Field?
    enum Field { case synopsis, target }

    var body: some View {
        let info = margin.info(for: scene)
        VStack(alignment: .leading, spacing: 8) {
            StatusSegments(url: scene)

            FieldLabel("Synopsis").padding(.top, 6)
            TextField("", text: $synopsis, prompt: nil, axis: .vertical)
                .accessibilityLabel("Synopsis")
                .textFieldStyle(.plain)
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.ink))
                .lineSpacing(4)
                .lineLimit(2...)
                .focused($editing, equals: .synopsis)
                .fieldBox(focused: editing == .synopsis, minHeight: 46)
                .onChange(of: synopsis) { _, value in
                    var changed = margin.info(for: scene)
                    changed.synopsis = value
                    margin.setInfo(changed, for: scene)
                }

            FieldLabel("Target").padding(.top, 6)
            HStack(spacing: 8) {
                TextField("0", text: $target, prompt: .placeholder("0"))
                    .textFieldStyle(.plain)
                    .font(.system(size: Layout.chromeSize).monospacedDigit())
                    .focused($editing, equals: .target)
                    .fieldBox(focused: editing == .target)
                    .frame(width: 84)
                    .onChange(of: target) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { target = digits; return }
                        var changed = margin.info(for: scene)
                        changed.target = Int(digits).flatMap { $0 > 0 ? $0 : nil }
                        margin.setInfo(changed, for: scene)
                    }
                Text("words")
                    .font(.system(size: Layout.detailSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.secondary))
                Spacer(minLength: 4)
                Badge("\(words.formatted()) written")
            }
            if let goal = info.target, goal > 0 {
                ProgressRule(fraction: Double(words) / Double(goal))
                    .frame(width: 160)
            }
        }
        .onAppear {
            synopsis = info.synopsis
            target = info.target.map(String.init) ?? ""
        }
    }

    private var words: Int { store.wordCounts[scene] ?? 0 }
}

/// A word target for the whole book, with the count so far.
private struct BookTarget: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    let book: URL
    @State private var target = ""
    @FocusState private var editingTarget: Bool

    var body: some View {
        let goal = margin.info(for: book).target
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Target")
            HStack(spacing: 8) {
                TextField("0", text: $target, prompt: .placeholder("0"))
                    .textFieldStyle(.plain)
                    .font(.system(size: Layout.chromeSize).monospacedDigit())
                    .focused($editingTarget)
                    .fieldBox(focused: editingTarget)
                    .frame(width: 96)
                    .help(progress.unit == "pages" ? "Page target for the screenplay" : "Word target for the story")
                    .onChange(of: target) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { target = digits; return }
                        var info = margin.info(for: book)
                        info.target = Int(digits).flatMap { $0 > 0 ? $0 : nil }
                        margin.setInfo(info, for: book)
                    }
                Text(progress.unit)
                    .font(.system(size: Layout.detailSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.secondary))
                Spacer(minLength: 4)
                Badge("\(progress.done.formatted()) written")
            }
            if let goal, goal > 0 {
                ProgressRule(fraction: Double(progress.done) / Double(goal))
                    .frame(width: 200)
            }
        }
        .padding(.bottom, 8)
        .onAppear { target = goal.map(String.init) ?? "" }
    }

    /// Pages for a screenplay, words for anything else.
    private var progress: (done: Int, unit: String) {
        store.book(for: book).map(store.targetProgress(of:)) ?? (0, "words")
    }
}

/// "83,233 of 90,000 words" and a progress rule, for a book with a target.
struct BookProgress: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    let book: Book

    var body: some View {
        if let goal = margin.info(for: book.url).target, goal > 0 {
            let progress = store.targetProgress(of: book)
            HStack(spacing: 10) {
                Badge("\(progress.done.formatted()) of \(goal.formatted()) \(progress.unit)")
                    .fixedSize()
                ProgressRule(fraction: Double(progress.done) / Double(goal))
                    .frame(minWidth: 40, maxWidth: 160)
            }
        }
    }
}
