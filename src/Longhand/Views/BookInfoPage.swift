import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A book's own page (select a book in the Library). It reads like a book's page: the cover,
/// the title and its author, the stage, genre and form, the counts, the synopsis set as prose,
/// and the chapters. Edit (owner, 2026-11-13) turns the same page into its form: cover,
/// title, stage, form, genre, target, synopsis and author; Done goes back. Everything is saved
/// as it is typed, with the book's other details (`SceneInfo` on the book).
struct BookInfoPage: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    let book: Book

    @State private var synopsis = ""
    @State private var target = ""
    @State private var title = ""
    @ObservedObject private var authors = AuthorProfiles.shared
    /// Edit shows the form; otherwise the page is read only.
    @State private var isEditing = false
    @State private var dropping = false
    @State private var coverHover = false
    @State private var croppingCover = false
    @FocusState private var editing: Field?

    enum Field: Hashable { case title, synopsis, genre, target }

    private var info: SceneInfo { margin.info(for: book.url) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if isEditing {
                    header
                    section("Synopsis") {
                        TextField("", text: $synopsis, prompt: nil, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineSpacing(4)
                            .lineLimit(4...)
                            .focused($editing, equals: .synopsis)
                            .fieldBox(focused: editing == .synopsis, minHeight: 92)
                            .onChange(of: synopsis) { _, value in update { $0.synopsis = value } }
                    }
                    section("Author") { author }
                } else {
                    readingHeader
                    standing
                }
                chapters
            }
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(Color(PaperTheme.ink))
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .onAppear {
            // Pictures: LONGHAND_BOOKEDIT=1 shows the page in Edit.
            if ProcessInfo.processInfo.environment["LONGHAND_BOOKEDIT"] == "1" { isEditing = true }
            load()
        }
        .onChange(of: book.url) { isEditing = false; load() }
    }

    /// Edit, or Done: Done renames the story if its title was changed.
    private var editButton: some View {
        Button(isEditing ? "Done" : "Edit") {
            if isEditing {
                renameStory()
                editing = nil
            }
            isEditing.toggle()
        }
        .buttonStyle(FramedButtonStyle())
        .fontWeight(isEditing ? .semibold : .medium)
        .help(isEditing ? "Back to the story's page" : "Change the story's details")
    }

    // MARK: Reading

    /// The page as it reads: the cover, the title and its author, the stage with the genre and
    /// form, the counts, and the target's progress if there is one.
    private var readingHeader: some View {
        let info = self.info
        let byline = authors.profile(info.authorProfile)?.byline
            ?? [info.authorPenName, info.authorName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let told = info.synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        // Beside the cover: title, byline and the synopsis under them, like a book's jacket
        // (owner, 2026-11-13). The stage and figures follow below, the page's full width.
        return HStack(alignment: .top, spacing: 24) {
            let _ = margin.coverVersion
            BookCover(title: book.title, image: margin.cover(of: book.url), width: Self.coverWidth)
            VStack(alignment: .leading, spacing: 10) {
                // Edit sits where Done does in the form, so it never moves under the pointer.
                Text(book.title)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.trailing, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                    .overlay(alignment: .topTrailing) { editButton.padding(.top, 6) }
                if let byline {
                    Text(byline)
                        .font(.system(size: 20, design: .serif).italic())  // two-thirds of the title (owner: 15 was too small)
                        .foregroundStyle(Color(PaperTheme.secondary))
                }
                if !told.isEmpty {
                    Text(told)
                        .font(.system(size: Layout.blurbSize, design: .serif))
                        .lineSpacing(Layout.blurbSize * 0.45)
                        .foregroundStyle(Color(PaperTheme.ink))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Under the cover: the stage, genre and form, the figures and the target, in one framed
    /// strip on one line, split by hairlines (owner, 2026-11-13: the big target bar felt too
    /// important). The target is a small bar inside its part.
    private var standing: some View {
        let parts = standingParts
        return Group {
            if !parts.isEmpty {
                HStack(spacing: 0) {
                    ForEach(parts.indices, id: \.self) { index in
                        if index > 0 { Rectangle().fill(Color(PaperTheme.cardBorder)).frame(width: 1) }
                        parts[index].padding(.horizontal, 10).frame(maxHeight: .infinity)
                    }
                }
                .frame(height: 30)
                .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
            }
        }
    }

    private var standingParts: [AnyView] {
        let info = self.info
        let kind = [info.genre, info.form?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        var parts: [AnyView] = []
        if let stage = info.stage {
            // Not a badge inside the box: its part of the strip is filled with the stage's
            // tint, the word in its colour (owner, 2026-11-13). The fill reaches the part's
            // edges (the strip's padding is undone around it, then given back).
            let colour = Color(stage.colour.color)
            parts.append(AnyView(
                Text(stage.title)
                    .font(.system(size: Layout.chromeSize, weight: .semibold))
                    .foregroundStyle(colour)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
                    .background(colour.opacity(0.16))
                    .padding(.horizontal, -10)
                    .help("Stage: \(stage.title)")
            ))
        }
        if !kind.isEmpty { parts.append(AnyView(stripText(kind).lineLimit(1).truncationMode(.tail).help(kind))) }
        for fact in [StoryFact.words, .pages, .reading] where info.shows(fact) {
            switch fact {
            case .words: parts.append(AnyView(stripText(Estimate.words(words)).fixedSize()))
            case .pages: parts.append(AnyView(stripText(Estimate.pages(words)).fixedSize().help("Manuscript pages, at 250 words each")))
            case .reading: parts.append(AnyView(stripText(Estimate.reading(words)).fixedSize().help("Reading time, at 250 words a minute")))
            case .target: break
            }
        }
        if info.shows(.target), let goal = info.target, goal > 0 {
            parts.append(AnyView(
                HStack(spacing: 8) {
                    stripText("\(percent ?? 0)%").fixedSize()
                    MeterBar(fraction: Double(progress.done) / Double(goal), height: 4).frame(width: 48)
                }
                .fixedSize()
                .help("Target: \(words.formatted()) of \(goal.formatted()) words written")
            ))
        }
        return parts
    }

    /// The cover's width on the story's page.
    static let coverWidth: CGFloat = 160

    private func stripText(_ text: String) -> Text {
        Text(text)
            .font(.system(size: Layout.chromeSize, weight: .medium).monospacedDigit())
            .foregroundColor(Color(PaperTheme.secondary))
    }

    // MARK: Cover, title and facts

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            cover
            VStack(alignment: .leading, spacing: 14) {
                // The title is edited in place: Return or clicking away renames the story.
                TextField("", text: $title, prompt: .placeholder("Title"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1...5)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($editing, equals: .title)
                    .onSubmit { renameStory(); editing = nil }
                    .onChange(of: editing) { old, new in if old == .title, new != .title { renameStory() } }
                    .onChange(of: title) { _, value in
                        // Return in a growing field types a line break: take it as "done".
                        if value.contains("\n") { title = value.replacingOccurrences(of: "\n", with: ""); renameStory(); editing = nil }
                    }
                    .help("Click to rename")
                    .padding(.trailing, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                    .overlay(alignment: .topTrailing) { editButton.padding(.top, 6) }
                labelled("Stage") {
                    StagePicker(stage: info.stage) { stage in update { $0.stage = stage } }
                }
                labelled("Form") {
                    // A menu like Genre's below it: five forms don't fit side by side.
                    FormMenu(form: info.form) { form in update { $0.form = form } }
                }
                labelled("Genre") {
                    GenreMenu(genre: info.genre) { value in update { $0.genre = value } }
                }
                labelled("Show") {
                    HStack(spacing: 14) {
                        ForEach(StoryFact.allCases) { fact in
                            SquareCheckbox(title: fact.title, isOn: Binding(
                                get: { info.shows(fact) },
                                set: { on in update { $0.setShows(fact, on) } }))
                            .fixedSize()
                            .help(fact == .reading ? "Reading time, at 250 words a minute" : "Show \(fact.title.lowercased()) on this story’s page")
                        }
                    }
                    .help("What this story's page shows")
                }
                labelled("Target") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("", text: $target, prompt: .placeholder("0"))
                                .textFieldStyle(.plain)
                                .monospacedDigit()
                                .focused($editing, equals: .target)
                                .fieldBox(focused: editing == .target)
                                .frame(width: 100)
                                .onChange(of: editing) { _, now in
                                    // Grouped like other counts ("80 000") except while typing.
                                    let goal = info.target
                                    target = now == .target ? goal.map(String.init) ?? "" : goal?.formatted() ?? ""
                                }
                                .onChange(of: target) { _, value in
                                    guard editing == .target else { return }
                                    let digits = value.filter(\.isNumber)
                                    if digits != value { target = digits; return }
                                    update { $0.target = Int(digits).flatMap { $0 > 0 ? $0 : nil } }
                                }
                            Text(progress.unit)
                                .foregroundStyle(Color(PaperTheme.secondary))
                            if let percent {
                                Chip(text: "\(percent)%", strong: true)
                                    .help("\(progress.done.formatted()) of \(info.target?.formatted() ?? "") \(progress.unit)")
                            }
                        }
                        if let goal = info.target, goal > 0 {
                            ProgressRule(fraction: Double(progress.done) / Double(goal))
                                .frame(width: 260, height: 3)
                        }
                    }
                }
            }
        }
    }

    private var words: Int { store.wordCount(of: book) }

    /// What the target counts: pages for a screenplay, words for anything else.
    private var progress: (done: Int, unit: String) { store.targetProgress(of: book) }

    private var percent: Int? {
        guard let goal = info.target, goal > 0 else { return nil }
        return Int((Double(progress.done) / Double(goal) * 100).rounded())
    }

    /// The cover in the Kindle shape (1:1.6). Click to choose an image, or drop one on it.
    private var cover: some View {
        let _ = margin.coverVersion
        return Button(action: chooseCover) {
            BookCover(title: book.title, image: margin.cover(of: book.url), width: Self.coverWidth)
                .overlay {
                    if dropping { rounded(Layout.radius).strokeBorder(Color(PaperTheme.accent), lineWidth: 2) }
                }
                .overlay(alignment: .bottom) {
                    if margin.cover(of: book.url) == nil, coverHover {
                        Text("Add Cover")
                            .font(.system(size: Layout.detailSize, weight: .medium))
                            .foregroundStyle(Color(PaperTheme.secondary))
                            .padding(.bottom, 14)
                    }
                }
                .contentShape(Rectangle())
                .onHover { coverHover = $0 }
        }
        .buttonStyle(.plain)
        .help("Click to choose an image, or drop one here. 1600 × 2560 works best.")
        .contextMenu {
            Button("Choose Cover…", action: chooseCover)
            if margin.cover(of: book.url) != nil {
                Button("Crop Cover…") { croppingCover = true }
                Button("Remove Cover", role: .destructive) { margin.removeCover(of: book.url) }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if margin.setCover(of: book.url, from: url) { croppingCover = true }
                }
            }
            return true
        }
        .sheet(isPresented: $croppingCover) {
            if let picture = margin.coverSource(of: book.url) {
                CoverCropSheet(picture: picture) { unit in margin.cropCover(of: book.url, to: unit) }
            }
        }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Cover"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if margin.setCover(of: book.url, from: url) { croppingCover = true }
    }

    // MARK: Chapters

    private var chapters: some View {
        let hide = info.hideChapterNumbers == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Contents")
                Spacer()
                if isEditing {
                SquareCheckbox(title: "Numbers", isOn: Binding(get: { !hide }, set: { on in update { $0.hideChapterNumbers = on ? nil : true } }))
                    .font(.system(size: Layout.detailSize))
                    .help("Show \(store.names(of: book.url).chapter.lowercased()) numbers here and in the contents")
                }
            }
            // Set like a printed book's contents (owner, 2026-11-13): no box or rules, the
            // title in the book’s face, a dotted leader to the page it starts on.
            let starts = Estimate.startPages(book.chapters.map { store.wordCount(of: $0) })
            VStack(spacing: 2) {
                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                    ChapterLine(number: hide ? nil : index + 1, title: chapter.title, page: starts[index],
                                words: store.wordCount(of: chapter), status: margin.info(for: chapter.url).status) {
                        store.selection = .chapter(chapter.url)
                    }
                }
                if book.chapters.isEmpty {
                    Text("No \(store.names(of: book.url).chapters.lowercased()) yet")
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, -8)
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Color(PaperTheme.ink))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            content()
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            FieldLabel(label).frame(width: 52, alignment: .leading)
            content()
        }
    }

    private func field(_ text: Binding<String>, _ which: Field, hint: String,
                       save: @escaping (inout SceneInfo, String?) -> Void) -> some View {
        TextField("", text: text, prompt: .placeholder(hint))
            .textFieldStyle(.plain)
            .focused($editing, equals: which)
            .fieldBox(focused: editing == which)
            .onChange(of: text.wrappedValue) { _, value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                update { save(&$0, trimmed.isEmpty ? nil : value) }
            }
    }

    private func update(_ change: (inout SceneInfo) -> Void) {
        var next = margin.info(for: book.url)
        change(&next)
        margin.setInfo(next, for: book.url)
    }

    private func load() {
        store.adoptExportAuthor()
        let info = self.info
        synopsis = info.synopsis
        target = info.target?.formatted() ?? ""
        title = book.title
        settleAuthor()
    }

    /// Keeps the story's author details the same as its profile's (Settings › Authors).
    private func settleAuthor() {
        let settled = authors.settle(info)
        if settled != info { margin.setInfo(settled, for: book.url) }
    }

    private func renameStory() {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, wanted != book.title else { title = book.title; return }
        store.rename(ManuscriptItem(url: book.url, title: book.title, order: book.order, kind: .book), to: wanted)
    }

    /// The author: chosen from the profiles in Settings (where their details and previous works
    /// are kept). Only the name shows here.
    private var author: some View {
        let info = self.info
        let chosen = authors.profile(info.authorProfile)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(authors.all) { profile in
                        Toggle(profile.title, isOn: Binding(get: { profile.id == chosen?.id },
                                                            set: { if $0 { update { $0.setAuthor(profile) } } }))
                    }
                    if !authors.all.isEmpty { Divider() }
                    Button("None") { update { $0.setAuthor(nil) } }
                } label: {
                    HStack(spacing: 6) {
                        // An author no longer in Settings still shows by name.
                        Text(chosen?.title ?? (info.hasNoAuthor ? "None" : info.authorName ?? info.authorPenName ?? "None"))
                            .foregroundStyle(Color(chosen == nil && info.hasNoAuthor ? PaperTheme.secondary : PaperTheme.ink))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(PaperTheme.secondary))
                    }
                    .padding(.horizontal, 8)
                    .frame(width: 240, height: Layout.controlHeight)
                    .background(Color(PaperTheme.card), in: rounded())
                    .roundedFrame(Color(PaperTheme.controlBorder))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Button("Edit Authors…") { SettingsView.open(pane: "authors") }
                    .buttonStyle(FramedButtonStyle())
                    .help("Authors are set up in Settings")
            }
        }
        .onChange(of: authors.all) { settleAuthor() }
    }
}

/// Idea, Sketch, Writing, Finished: badges in their colours; the chosen one filled. Click it
/// again to clear it.
struct StagePicker: View {
    let stage: BookStage?
    let choose: (BookStage?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(BookStage.allCases) { option in
                Button { choose(option == stage ? nil : option) } label: {
                    StageBadge(stage: option, filled: option == stage, size: 13)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A book's stage as a small rounded badge in its colour, in Semibold.
struct StageBadge: View {
    let stage: BookStage
    var filled = true
    var size: CGFloat = 10

    var body: some View {
        TintBadge(title: stage.title, colour: stage.colour, filled: filled, size: size)
    }
}

/// A scene's or chapter's status (Draft, Revised, Done) as a badge in its colour.
struct StatusBadge: View {
    let status: SceneInfo.Status
    var body: some View {
        TintBadge(title: status.title, colour: status.colour)
            .help("Status: \(status.title)")
    }
}

/// A word in a rounded badge of its colour (stages and statuses).
struct TintBadge: View {
    let title: String
    let colour: BookLook.Colour
    var filled = true
    var size: CGFloat = 10

    var body: some View {
        let colour = Color(self.colour.color)
        // In its own capitalisation and on the Mac's scale: never tracked capitals (DESIGN.md),
        // never under 12pt.
        Text(title)
            .font(.system(size: size >= Layout.chromeSize ? Layout.chromeSize : Layout.detailSize, weight: .semibold))
            .foregroundStyle(filled ? colour : Color(PaperTheme.secondary))
            .padding(.horizontal, size * 0.55)
            .padding(.vertical, size * 0.15)
            .background(filled ? colour.opacity(0.16) : .clear, in: rounded(Layout.smallRadius + 1))
            .overlay(rounded(Layout.smallRadius + 1).strokeBorder(filled ? colour.opacity(0.55) : Color(PaperTheme.controlBorder), lineWidth: 1))
    }
}

/// Choosing which part of a picture is the cover: the picture behind a window in the cover's
/// shape; drag to move it, the slider to zoom. The whole picture is kept, so this can be
/// done again.
struct CoverCropSheet: View {
    let picture: NSImage
    let use: (CGRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?

    private let window = CGSize(width: 220, height: 220 * MarginStore.coverRatio)

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: picture)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .offset(clamped(offset))
                .frame(width: window.width, height: window.height)
                .clipShape(rounded(Layout.radius))
                .roundedFrame(Color(PaperTheme.frame), lineWidth: 1)
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { value in
                        let start = dragStart ?? clamped(offset)
                        dragStart = start
                        offset = clamped(CGSize(width: start.width + value.translation.width,
                                                height: start.height + value.translation.height))
                    }
                    .onEnded { _ in dragStart = nil })
                .help("Drag to move the picture")

            HStack(spacing: 10) {
                Text("Zoom")
                    .foregroundStyle(Color(PaperTheme.secondary))
                Slider(value: $zoom, in: 1...3)
                    .controlSize(.small)
                    .tint(Color(PaperTheme.ink))
            }
            .frame(width: window.width)

            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Use Cover") {
                    use(Self.unit(window: window, shown: shown, offset: clamped(offset)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SquareButtonStyle(primary: true))
            }
        }
        .font(.system(size: Layout.chromeSize))
        .padding(24)
        .background(Color(PaperTheme.paper))
    }

    /// The picture's size on screen: filling the window at zoom 1.
    private var shown: CGSize {
        let size = picture.size
        guard size.width > 0, size.height > 0 else { return window }
        let fill = max(window.width / size.width, window.height / size.height) * zoom
        return CGSize(width: size.width * fill, height: size.height * fill)
    }

    /// Keeps the window covered: the picture's centre can move only as far as its edges allow.
    private func clamped(_ value: CGSize) -> CGSize {
        let x = max(0, (shown.width - window.width) / 2), y = max(0, (shown.height - window.height) / 2)
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }

    /// The part of the picture showing in the window, as fractions of the picture (origin
    /// top left). `offset` is how far the picture's centre sits from the window's.
    static func unit(window: CGSize, shown: CGSize, offset: CGSize) -> CGRect {
        guard shown.width > 0, shown.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let left = (shown.width - window.width) / 2 - offset.width
        let top = (shown.height - window.height) / 2 - offset.height
        return CGRect(x: left / shown.width, y: top / shown.height,
                      width: window.width / shown.width, height: window.height / shown.height)
    }
}

/// A chapter on the story's page, as a book's contents sets it: number (unless hidden),
/// title, a dotted leader, its status and the page it starts on (owner, 2026-11-13).
private struct ChapterLine: View {
    let number: Int?
    let title: String
    /// The page it starts on, estimated (each chapter on a fresh page).
    let page: Int
    let words: Int
    let status: SceneInfo.Status?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: Layout.blurbSize, design: .serif).monospacedDigit())
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .frame(width: 24, alignment: .trailing)
                }
                Text(title)
                    .font(.system(size: Layout.blurbSize, design: .serif))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1)
                    .layoutPriority(1)
                Leader()
                if let status { StatusBadge(status: status) }
                Text("\(page)")
                    .font(.system(size: Layout.blurbSize, design: .serif).monospacedDigit())
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .help("Starts on about page \(page) · \(Estimate.words(words))")
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hovering ? Color(PaperTheme.hover) : .clear, in: rounded())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(title)")
    }
}

/// A contents page's dotted leader, filling the space between a title and its figure.
private struct Leader: View {
    var body: some View {
        Line()
            .stroke(Color(PaperTheme.tertiary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 5]))
            .frame(height: 1.2)
            .frame(minWidth: 12)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

/// A meter for a target: a 6pt bar, its track framed, corners slightly rounded (never a
/// capsule).
struct MeterBar: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                rounded(2).fill(Color(PaperTheme.controlFill))
                rounded(2).fill(Color(PaperTheme.ink))
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
            .overlay(rounded(2).strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
        }
        .frame(height: height)
    }
}

/// A small rounded chip for a figure: "25,531 words", "~102 pages", "1 h 42 min".
struct Chip: View {
    let text: String
    var strong = false

    var body: some View {
        Text(text)
            .font(.system(size: Layout.detailSize, weight: strong ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(Color(strong ? PaperTheme.ink : PaperTheme.secondary))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(PaperTheme.controlFill), in: rounded(Layout.radius))
            .overlay(rounded(Layout.radius).strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
    }
}

/// Estimates from a word count: pages at 250 words a page (a manuscript page) and reading time
/// at 250 words a minute.
enum Estimate {
    static let wordsPerPage = 250.0
    static let wordsPerMinute = 250.0

    /// "1 word", "1,204 words".
    static func words(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count.formatted()) words"
    }

    static func pages(_ words: Int) -> String {
        let pages = max(words > 0 ? 1 : 0, Int((Double(words) / wordsPerPage).rounded()))
        return pages == 1 ? "1 page" : "\(pages.formatted()) pages"
    }

    /// The page each chapter starts on, as a printed book would set them: page 1 first,
    /// each chapter on a fresh page, a page per 250 words (at least one).
    static func startPages(_ words: [Int]) -> [Int] {
        var page = 1
        return words.map { count in
            defer { page += max(1, Int((Double(count) / wordsPerPage).rounded(.up))) }
            return page
        }
    }

    static func reading(_ words: Int) -> String {
        let minutes = max(words > 0 ? 1 : 0, Int((Double(words) / wordsPerMinute).rounded()))
        if minutes < 60 { return "\(minutes) min read" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h read" : "\(hours) h \(rest) min read"
    }
}

/// The genre, from BISAC's fiction headings (Book Industry Study Group, the book trade's
/// standard: bisg.org/fiction, 2025): its 70 headings plus the 18 that it uses only as
/// parents of sub-headings (Fantasy, Romance, Thrillers …).
enum Genres {
    static let all: [String] = [
        "Absurdist", "Action & Adventure", "Adaptations & Pastiche", "African American & Black",
        "Alternative History", "Amish & Mennonite", "Animals", "Anthologies (multiple authors)",
        "Asian American & Pacific Islander", "Biographical & Autofiction", "Books, Bookstores & Libraries",
        "Buddhist", "Christian", "Classics", "Coming of Age", "Cozy", "Crime", "Cultural Heritage",
        "Death, Grief, Bereavement", "Disability", "Disaster", "Diversity & Multicultural", "Dystopian",
        "Epistolary (Letters, Diaries, etc.)", "Erotica", "Fairy Tales, Folk Tales, Legends & Mythology",
        "Family Life", "Fantasy", "Feminist", "Friendship", "Ghost", "Gothic", "Hispanic & Latino",
        "Historical", "Holidays", "Horror", "Humorous", "Immigration & Emigration", "Indigenous",
        "Indigenous Peoples of Turtle Island", "Jewish", "Legal", "LGBTQ+", "Literary",
        "LitRPG (Literary Role-Playing Game)", "Magical Realism", "Mashups", "Media Tie-In", "Medical",
        "Middle Eastern & Arab American", "Multiple Timelines", "Muslim", "Mystery & Detective",
        "Native American", "Nature & the Environment", "Neurodiversity", "Noir", "Occult & Supernatural",
        "Own Voices", "Performing Arts", "Places", "Political", "Prejudice, Racism & Colorism", "Psychological",
        "Religious", "Romance", "Sagas", "Satire", "School & Education", "Science Fiction", "Sea Stories",
        "Short Stories (single author)", "Small Town & Rural", "Southern", "Speculative", "Sports",
        "Suburban", "Superheroes", "Surrealism", "Thrillers", "Time Travel", "Travel & Vacation",
        "Urban & Street Lit", "Visionary & Metaphysical", "War & Military", "Westerns", "Women",
        "World Literature",
    ]
}

/// The genre as a menu (a framed button like a pop-up); None clears it.
/// The story's form (Novel, Novella, Short Story, Essay, Notebook) as a menu.
struct FormMenu: View {
    let form: BookForm?
    let choose: (BookForm?) -> Void

    var body: some View {
        Menu {
            Button("None") { choose(nil) }
            Divider()
            ForEach(BookForm.allCases) { option in
                Toggle(option.title, isOn: Binding(get: { option == form }, set: { if $0 { choose(option) } }))
            }
        } label: {
            HStack(spacing: 6) {
                Text(form?.title ?? "None")
                    .foregroundStyle(Color(form == nil ? PaperTheme.secondary : PaperTheme.ink))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(PaperTheme.secondary))
            }
            .padding(.horizontal, 8)
            .frame(width: 160, height: 26)
            .background(Color(PaperTheme.paper), in: rounded())
            .overlay(rounded().strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct GenreMenu: View {
    let genre: String?
    let choose: (String?) -> Void

    var body: some View {
        Menu {
            Button("None") { choose(nil) }
            Divider()
            ForEach(Genres.all, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { name == genre }, set: { if $0 { choose(name) } }))
            }
        } label: {
            HStack(spacing: 6) {
                Text(genre ?? "None")
                    .foregroundStyle(Color(genre == nil ? PaperTheme.secondary : PaperTheme.ink))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(PaperTheme.secondary))
            }
            .padding(.horizontal, 8)
            .frame(width: 240, height: 26)
            .background(Color(PaperTheme.paper), in: rounded())
            .overlay(rounded().strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The book trade’s standard fiction genres")
    }
}
