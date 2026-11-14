import AppKit
import Foundation

/// A comment on a passage of one scene. Only the owner writes comments, so there are no
/// authors, replies or threads: a comment is its text, when it was made, and where it points.
///
/// Where it points is kept two ways, so it survives edits made in Longhand and outside it
/// (another editor, say): the position in the scene's text, and the passage itself with a little of
/// the text either side. On loading, the position is checked against the passage; if the text
/// has moved, the passage is looked for, nearest the old position first.
struct SceneComment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var created: Date = Date()
    var text: String = ""
    var resolved: Bool = false
    /// UTF-16 offset and length of the passage in the scene's text.
    var location: Int
    var length: Int
    /// The passage, and up to `contextLength` characters either side, as last saved.
    var quote: String
    var prefix: String = ""
    var suffix: String = ""
    /// The scene the comment belongs to (kept in memory only: the file it is saved in says so).
    var scene: URL?

    static let contextLength = 32

    enum CodingKeys: String, CodingKey {
        case id, created, text, resolved, location, length, quote, prefix, suffix
    }

    var range: NSRange { NSRange(location: location, length: length) }

    /// True when the passage could not be found in the scene any more.
    var isDetached: Bool { length == 0 }
}

/// What a scene is for and how far along it is: shown on its card and in the margin.
struct SceneInfo: Codable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case draft, revised, done
        var title: String { rawValue.capitalized }
        var colour: BookLook.Colour {
            switch self {
            case .draft: return .grey
            case .revised: return .blue
            case .done: return .green
            }
        }
    }

    var synopsis: String = ""
    var status: Status?
    /// A word target, if the scene has one.
    var target: Int?
    // A book's details (the Book Info page). Scenes leave them empty.
    /// Where the book stands: Idea, Sketch, Writing, Finished (a badge in the contents too).
    var stage: BookStage?
    var form: BookForm?
    var genre: String?
    /// The author, as a manuscript's title page gives them: legal name, pen name (the
    /// byline, if different), address, email and phone. The one place they are kept.
    var authorName: String?
    /// The author profile (Settings › Authors) these details were filled in from.
    var authorProfile: String?
    var authorPenName: String?
    var authorAddress: String?
    var authorEmail: String?
    var authorPhone: String?
    var previousWorks: String?
    /// Chapters listed by title only, without their numbers (Book Info and the contents).
    var hideChapterNumbers: Bool?
    /// The figures the story's page leaves out (owner, 2026-11-13: chosen per story).
    var hiddenFacts: [StoryFact]?
    /// How the story is divided (chapters and scenes, chapters, scenes, one document).
    var shape: BookShape?

    func shows(_ fact: StoryFact) -> Bool { !(hiddenFacts ?? []).contains(fact) }

    mutating func setShows(_ fact: StoryFact, _ on: Bool) {
        var hidden = Set(hiddenFacts ?? [])
        if on { hidden.remove(fact) } else { hidden.insert(fact) }
        hiddenFacts = hidden.isEmpty ? nil : StoryFact.allCases.filter(hidden.contains)
    }

    /// No author detail filled in.
    var hasNoAuthor: Bool {
        [authorName, authorPenName, authorAddress, authorEmail, authorPhone]
            .allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isEmpty: Bool {
        synopsis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status == nil && target == nil
            && stage == nil && form == nil
            && [genre, authorName, authorPenName, authorAddress, authorEmail, authorPhone, previousWorks].allSatisfy { ($0 ?? "").isEmpty }
            && hideChapterNumbers != true && (hiddenFacts ?? []).isEmpty && shape == nil
    }

    init(synopsis: String = "", status: Status? = nil, target: Int? = nil) {
        self.synopsis = synopsis
        self.status = status
        self.target = target
    }

    /// Every field is optional on disk, so a file written by hand (or by an older Longhand)
    /// still reads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        synopsis = try container.decodeIfPresent(String.self, forKey: .synopsis) ?? ""
        status = try? container.decodeIfPresent(Status.self, forKey: .status)
        target = try? container.decodeIfPresent(Int.self, forKey: .target)
        stage = try? container.decodeIfPresent(BookStage.self, forKey: .stage)
        form = try? container.decodeIfPresent(BookForm.self, forKey: .form)
        genre = try? container.decodeIfPresent(String.self, forKey: .genre)
        authorName = try? container.decodeIfPresent(String.self, forKey: .authorName)
        authorProfile = try? container.decodeIfPresent(String.self, forKey: .authorProfile)
        authorPenName = try? container.decodeIfPresent(String.self, forKey: .authorPenName)
        authorAddress = try? container.decodeIfPresent(String.self, forKey: .authorAddress)
        authorEmail = try? container.decodeIfPresent(String.self, forKey: .authorEmail)
        authorPhone = try? container.decodeIfPresent(String.self, forKey: .authorPhone)
        previousWorks = try? container.decodeIfPresent(String.self, forKey: .previousWorks)
        hideChapterNumbers = try? container.decodeIfPresent(Bool.self, forKey: .hideChapterNumbers)
        hiddenFacts = try? container.decodeIfPresent([StoryFact].self, forKey: .hiddenFacts)
        shape = try? container.decodeIfPresent(BookShape.self, forKey: .shape)
    }
}

/// A figure on a story's page that the writer may turn off for that story.
enum StoryFact: String, Codable, CaseIterable, Identifiable {
    case words, pages, reading, target
    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: return "Words"
        case .pages: return "Pages"
        case .reading: return "Reading"  // "Reading Time" wrapped onto two lines in Edit
        case .target: return "Target"
        }
    }
}

/// Where a book stands, set by the writer: a colour-coded badge. Named so as not to clash
/// with Mark as Draft or the manuscript (as against a rewrite); saved under the older names
/// ("draft", "manuscript") so books keep their stage.
enum BookStage: String, Codable, CaseIterable, Identifiable {
    case idea, sketch
    case writing = "draft"
    case finished = "manuscript"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .idea: return "Idea"
        case .sketch: return "Sketch"
        case .writing: return "Writing"
        case .finished: return "Finished"
        }
    }
    var colour: BookLook.Colour {
        switch self {
        case .idea: return .grey
        case .sketch: return .blue
        case .writing: return .yellow
        case .finished: return .green
        }
    }
}

/// What kind of writing a story is (owner, 2026-11-13): the fiction lengths, longest first, then
/// essays, screenplays (2026-11-14) and notebooks. Stored by name, so the order can change
/// without touching saved stories.
enum BookForm: String, Codable, CaseIterable, Identifiable {
    case novel, novella, shortStory, essay, screenplay, notebook
    var id: String { rawValue }
    var title: String {
        switch self {
        case .novel: return "Novel"
        case .novella: return "Novella"
        case .shortStory: return "Short Story"
        case .essay: return "Essay"
        case .screenplay: return "Screenplay"
        case .notebook: return "Notebook"
        }
    }
}

/// The editor on screen, as the margin sees it: a single scene, or a chapter's scenes on one
/// page. Comments are kept in each scene's own coordinates; the page maps them to its own.
@MainActor
protocol CommentPage: AnyObject {
    var pageTextView: NSTextView? { get }
    /// Where a scene's range sits on the page, if that scene is on it.
    func pageRange(scene: URL, local: NSRange) -> NSRange?
    /// The selected text, if it lies within one scene: that scene and the range in its text.
    func selectionInScene() -> (scene: URL, range: NSRange)?
    /// A scene's own text, as the page shows it.
    func text(of scene: URL) -> String?
}

/// A Markdown note belonging to a whole book: `<Book>/Notes/<Title>.md`, an ordinary file
/// that the Finder sees like any other.
struct BookNote: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let modified: Date
}

/// Notes and comments: the right-hand margin's data.
///
/// On disk, inside the library:
///
///     .longhand/comments/<Book>/<Chapter>/<Scene>.json    a scene's comments
///     .longhand/scenes/<Book>/<Chapter>/<Scene>.json      a scene's synopsis, status, target
///     .longhand/scenes/<Book>.json                        a book's word target
///     .longhand/notes/<Book>/<Chapter>/<Scene>.md         a scene's note
///     .longhand/notes/<Book>/<Chapter>.md                 a chapter's note
///     <Book>/Notes/<Title>.md                             book notes (visible, Markdown)
///
/// Comments and scene and chapter notes are kept out of the scene files, so they never show in
/// the text, in exports, or in word counts. Their paths mirror the manuscript, and move with it
/// when an item is renamed, reordered or trashed.
@MainActor
final class MarginStore: ObservableObject {
    enum Tab: String { case comments, notes, history, changes }

    // MARK: Published state

    /// Comments of the scenes on the open page (one scene, or a chapter's), in page order.
    ///
    /// Not `@Published`: comments shift with the text on every keystroke, and that must not
    /// redraw the margin. Changes the margin shows call `objectWillChange.send()` themselves.
    private(set) var comments: [SceneComment] = []
    /// The comment being worked on: its card is raised and its passage highlighted more.
    @Published var focused: UUID?

    /// Where you were as ⌘R switched between Write and Read (owner, 2026-11-14: "cmd-r should
    /// retain where the user is"): places in scenes' own text, the first character on show and
    /// the caret. The page that opens next goes there and forgets it.
    struct ReadingAnchor {
        var top: (scene: URL, location: Int)?
        var caret: (scene: URL, location: Int)?
    }
    var readingAnchor: ReadingAnchor?
    /// A passage chosen from its change bar on the page, shown in the Changes tab.
    @Published var changeFocus: ChangeBar?

    /// Set when a new comment is made, so its card can take the keyboard.
    @Published var editingRequest: UUID?
    @Published var showResolved = false
    /// Open comments per scene, for the contents column.
    @Published private(set) var openCounts: [URL: Int] = [:]

    /// Synopsis, status and target of every scene, for cards and the margin.
    @Published private(set) var infos: [URL: SceneInfo] = [:]

    @Published var sceneNote = ""
    @Published var chapterNote = ""
    @Published private(set) var bookNotes: [BookNote] = []
    /// A book note opened in the margin, and its text.
    @Published private(set) var openBookNote: BookNote?
    @Published var openBookNoteText = ""

    /// What the margin is about.
    @Published private(set) var sceneURL: URL?
    @Published private(set) var chapterURL: URL?
    @Published private(set) var bookURL: URL?

    /// The editor on screen (scene or chapter page), if any.
    weak var page: CommentPage? {
        didSet { if page !== oldValue, changeFocus != nil { changeFocus = nil } }
    }
    /// Its text view: used to read the selection, show a passage, and open the find bar.
    var textView: NSTextView? { page?.pageTextView }

    /// The scenes whose comments are loaded, in page order.
    private(set) var pageScenes: [URL] = []

    private var root: URL?
    private var dirtyScenes: Set<URL> = []
    private var notesDirty: Set<NoteScope> = []
    private var saveTask: Task<Void, Never>?

    private enum NoteScope: Hashable { case scene, chapter, book }

    // MARK: Paths

    private var meta: URL? { root?.appendingPathComponent(".longhand", isDirectory: true) }

    /// The manuscript-relative key of an item: `Book/Chapter/Scene` (no `.md`).
    private func key(_ url: URL) -> String? {
        guard let root else { return nil }
        let base = root.path + "/"
        guard url.path.hasPrefix(base) else { return nil }
        var relative = String(url.path.dropFirst(base.count))
        relative = ProseFile.base(relative)
        return relative
    }

    private func commentsURL(for scene: URL) -> URL? {
        guard let meta, let key = key(scene) else { return nil }
        return meta.appendingPathComponent("comments/\(key).json")
    }

    private func infoURL(for scene: URL) -> URL? {
        guard let meta, let key = key(scene) else { return nil }
        return meta.appendingPathComponent("scenes/\(key).json")
    }

    private func noteURL(for item: URL) -> URL? {
        guard let meta, let key = key(item) else { return nil }
        return meta.appendingPathComponent("notes/\(key).md")
    }

    static func notesFolder(of book: URL) -> URL {
        book.appendingPathComponent("Notes", isDirectory: true)
    }

    // MARK: Library

    func open(root: URL?) {
        saveNow()
        objectWillChange.send()
        self.root = root
        comments = []
        focused = nil
        openCounts = [:]
        infos = [:]
        coverCache = [:]
        pageScenes = []
        sceneURL = nil
        chapterURL = nil
        bookURL = nil
        bookNotes = []
        openBookNote = nil
    }

    /// Counts open comments and reads the details of every scene (called whenever the
    /// library is re-read).
    func refreshCounts(scenes: [URL], books: [URL] = []) {
        var details: [URL: SceneInfo] = [:]
        // A book's and a chapter's details are kept the same way as a scene's.
        for scene in scenes + books {
            if let url = infoURL(for: scene), let data = try? Data(contentsOf: url) {
                if let info = try? JSONDecoder().decode(SceneInfo.self, from: data) {
                    details[scene] = info
                } else {
                    setAside(url)
                }
            }
        }
        infos = details
        coverCache = [:]
        // Covers may have arrived with a pull: rows showing them draw again.
        coverVersion += 1

        var counts: [URL: Int] = [:]
        for scene in scenes {
            let open = readComments(for: scene).filter { !$0.resolved }.count
            if open > 0 { counts[scene] = open }
        }
        for scene in pageScenes {
            counts[scene] = comments.filter { $0.scene == scene && !$0.resolved }.count
        }
        openCounts = counts.filter { $0.value > 0 }
    }

    /// Points the margin at a new place in the manuscript.
    func show(scene: URL?, chapter: URL?, book: URL?) {
        guard scene != sceneURL || chapter != chapterURL || book != bookURL else { return }
        saveNow()
        if book != bookURL { openBookNote = nil }
        sceneURL = scene
        chapterURL = chapter
        bookURL = book
        load(scenes: scene.map { [$0] } ?? [])
        sceneNote = scene.flatMap(noteURL(for:)).map(readText) ?? ""
        chapterNote = chapter.flatMap(noteURL(for:)).map(readText) ?? ""
        reloadBookNotes()
    }

    // MARK: Comments

    func readComments(for scene: URL) -> [SceneComment] {
        guard let url = commentsURL(for: scene),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var comments = (try? decoder.decode(CommentFile.self, from: data))?.comments else {
            setAside(url)
            return []
        }
        for index in comments.indices { comments[index].scene = scene }
        return comments
    }

    /// A comments or details file that is there but can't be read (damaged, or cut short by
    /// a sync): moved to "<name>.unreadable-<time>.json" beside itself, so the next save
    /// starts a fresh file instead of writing over the only copy.
    private func setAside(_ url: URL) {
        let kept = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension("json")
        try? FileManager.default.moveItem(at: url, to: FileNaming.unique(kept))
    }

    private func load(scenes: [URL]) {
        objectWillChange.send()
        pageScenes = scenes
        comments = scenes.flatMap(readComments(for:))
        focused = nil
        sortComments()
        if let id = revealOnLoad, comments.contains(where: { $0.id == id }) {
            // After the page has its new text (it loads in the same pass).
            DispatchQueue.main.async { [weak self] in self?.reveal(id) }
        }
    }

    /// The chapter page opened: load the comments of every scene on it.
    func openChapterPage(scenes: [URL]) {
        guard scenes != pageScenes else { return }
        saveNow()
        load(scenes: scenes)
    }

    /// Matches each of a scene's comments to its current text (see `SceneComment`). Called when
    /// a scene's text is put on the page.
    func anchor(scene: URL, text: String) {
        let string = text as NSString
        var changed = false
        for index in comments.indices where comments[index].scene == scene {
            let comment = comments[index]
            let found = Self.locate(comment, in: string)
            if found != comment.range {
                comments[index].location = found.location
                comments[index].length = found.length
                changed = true
            }
        }
        sortComments()
        if changed {
            refreshQuotes(scene: scene, in: string)
            dirtyScenes.insert(scene)
            scheduleSave()
        }
        // A comment chosen from a list before its scene was open: its page is here now.
        if let id = revealOnLoad, comments.contains(where: { $0.id == id && $0.scene == scene }) {
            DispatchQueue.main.async { [weak self] in self?.reveal(id) }
        }
    }

    static func locate(_ comment: SceneComment, in string: NSString) -> NSRange {
        let quote = comment.quote as NSString
        guard quote.length > 0 else { return NSRange(location: min(comment.location, string.length), length: 0) }
        if NSMaxRange(comment.range) <= string.length, comment.length == quote.length,
           string.substring(with: comment.range) == comment.quote {
            return comment.range
        }
        // Every place the passage occurs, scored by its context and nearness to where it was.
        var best: (range: NSRange, score: Int)?
        var search = NSRange(location: 0, length: string.length)
        while search.length > 0 {
            let found = string.range(of: comment.quote, options: [], range: search)
            guard found.location != NSNotFound else { break }
            var score = 0
            let before = string.substring(with: NSRange(
                location: max(0, found.location - comment.prefix.utf16.count),
                length: min(found.location, comment.prefix.utf16.count)
            ))
            let after = string.substring(with: NSRange(
                location: NSMaxRange(found),
                length: min(string.length - NSMaxRange(found), comment.suffix.utf16.count)
            ))
            if !comment.prefix.isEmpty, before == comment.prefix { score += 2 }
            if !comment.suffix.isEmpty, after == comment.suffix { score += 2 }
            score -= min(abs(found.location - comment.location) / 2000, 1)
            if best == nil || score > best!.score { best = (found, score) }
            search = NSRange(location: found.location + 1, length: string.length - found.location - 1)
        }
        return best?.range ?? NSRange(location: min(comment.location, string.length), length: 0)
    }

    /// Keeps a scene's comments on their passages while it is edited: `range` is the edited
    /// text after the edit, in the scene's own coordinates, and `delta` the change in length.
    /// `text` gives the scene's text after the edit, read only when a passage looks touched.
    func textDidEdit(scene: URL, range edited: NSRange, delta: Int, text: () -> NSString) {
        let start = edited.location
        let oldEnd = start + edited.length - delta
        let newEnd = NSMaxRange(edited)
        var touched = false
        var after: NSString?
        for index in comments.indices where comments[index].scene == scene {
            touched = true
            var lower = comments[index].location
            var upper = lower + comments[index].length
            guard comments[index].length > 0 else {
                if lower >= oldEnd { comments[index].location += delta }
                continue
            }
            if oldEnd <= lower {
                lower += delta
                upper += delta
            } else if start >= upper {
                continue
            } else {
                if start <= lower && oldEnd >= upper {
                    lower = newEnd
                    upper = newEnd
                } else if start < lower {
                    lower = newEnd
                    upper += delta
                } else if oldEnd <= upper {
                    upper += delta
                } else {
                    upper = newEnd
                }
                // The edit overlapped the passage. AppKit often reports a wider edited range
                // than the keys typed (restyling a paragraph, say), so the passage may be
                // untouched: if its words are still there, near where they were, keep them.
                let string = after ?? text()
                after = string
                let quote = comments[index].quote as NSString
                if quote.length > 0 {
                    let near = NSRange(location: max(0, min(lower, start) - quote.length), length: 0)
                    let span = NSRange(location: near.location,
                                       length: min(string.length, max(upper, newEnd) + quote.length) - near.location)
                    let same = NSRange(location: lower, length: upper - lower)
                    let unchanged = NSMaxRange(same) <= string.length && string.substring(with: same) == comments[index].quote
                    if !unchanged, span.length > 0 {
                        let found = string.range(of: comments[index].quote, options: [], range: span)
                        if found.location != NSNotFound {
                            lower = found.location
                            upper = NSMaxRange(found)
                        }
                    }
                }
            }
            comments[index].location = max(0, lower)
            comments[index].length = max(0, upper - lower)
        }
        if touched { dirtyScenes.insert(scene) }
    }

    /// After an edit to a scene: refresh its passages' quoted text and save soon.
    func textDidSettle(scene: URL, text: String) {
        guard dirtyScenes.contains(scene) else { return }
        refreshQuotes(scene: scene, in: text as NSString)
        refreshOpenCounts()
        scheduleSave()
    }

    /// Comments on the selected text, if it lies within one scene. Returns the new comment.
    @discardableResult
    func addCommentOnSelection() -> SceneComment? {
        guard let page, let (scene, range) = page.selectionInScene(), range.length > 0,
              let text = page.text(of: scene) else {
            NSSound.beep()
            return nil
        }
        let string = text as NSString
        guard NSMaxRange(range) <= string.length else { NSSound.beep(); return nil }
        objectWillChange.send()
        var comment = SceneComment(location: range.location, length: range.length, quote: string.substring(with: range))
        comment.scene = scene
        Self.fillContext(&comment, in: string)
        comments.append(comment)
        // The passage is highlighted now; leave it unselected, the caret after it, so a key
        // pressed back on the page can't replace it.
        caretAfterSelection()
        sortComments()
        focused = comment.id
        editingRequest = comment.id
        refreshOpenCounts()
        dirtyScenes.insert(scene)
        scheduleSave()
        return comment
    }

    private func markDirty(_ id: UUID) {
        if let scene = comments.first(where: { $0.id == id })?.scene { dirtyScenes.insert(scene) }
    }

    func setText(_ text: String, of id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }), comments[index].text != text else { return }
        comments[index].text = text
        markDirty(id)
        scheduleSave()
    }

    func setResolved(_ resolved: Bool, _ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        comments[index].resolved = resolved
        if resolved, focused == id { focused = nil }
        markDirty(id)
        refreshOpenCounts()
        saveNow()
        if resolved { returnKeyboardToPage() }
    }

    /// After a comment leaves the list, the keyboard goes back to the page (its field is gone,
    /// which left the keys with nowhere to go).
    private func returnKeyboardToPage() {
        DispatchQueue.main.async { [weak self] in
            guard let page = self?.textView, let window = page.window else { return }
            if window.firstResponder === window || !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(page)
            }
        }
    }

    func delete(_ id: UUID) {
        objectWillChange.send()
        markDirty(id)
        comments.removeAll { $0.id == id }
        if focused == id { focused = nil }
        refreshOpenCounts()
        saveNow()
        returnKeyboardToPage()
    }

    /// A new comment left empty disappears when it loses focus.
    /// Return in a comment: it's done. An empty one goes; the keyboard goes back to the page
    /// with the caret where it was (after the passage), without moving the page.
    func finishEditing(_ id: UUID) {
        dropIfEmpty(id)
        if focused == id { focused = nil }
        caretAfterSelection()
        // After SwiftUI has let go of the comment's field (it hands the keys to the window).
        DispatchQueue.main.async { [weak self] in
            guard let textView = self?.textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// Collapses the page's selection to its end, leaving the page where it is.
    private func caretAfterSelection() {
        guard let textView, textView.selectedRange().length > 0 else { return }
        let page = textView as? HighlightTextView
        page?.holdsScroll = true
        textView.setSelectedRange(NSRange(location: NSMaxRange(textView.selectedRange()), length: 0))
        page?.holdsScroll = false
    }

    func dropIfEmpty(_ id: UUID) {
        guard let comment = comments.first(where: { $0.id == id }),
              comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        delete(id)
    }

    /// Where a comment's passage is on the page on screen.
    func pageRange(of comment: SceneComment) -> NSRange? {
        guard let scene = comment.scene else { return nil }
        return page?.pageRange(scene: scene, local: comment.range)
    }

    /// Puts the caret at the start of a comment's passage and scrolls to it. Never selects
    /// the passage: a selection would be replaced by the next key pressed.
    func reveal(_ id: UUID) {
        focused = id
        guard let comment = comments.first(where: { $0.id == id }), let textView,
              let range = pageRange(of: comment), NSMaxRange(range) <= (textView.string as NSString).length else {
            // The scene's page isn't loaded yet: done once it is.
            revealOnLoad = id
            return
        }
        revealOnLoad = nil
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.jump(to: range)
    }

    /// A comment to show once its scene's page has loaded (chosen from a chapter's or book's list).
    var revealOnLoad: UUID?

    private var lastJump: (id: UUID, at: Date)?

    /// Focuses a comment and brings its passage into view, leaving the keyboard where it is.
    func scrollTo(_ id: UUID) {
        // One click can arrive twice (the card, and its field taking the keyboard).
        if lastJump?.id == id, Date().timeIntervalSince(lastJump!.at) < 0.4 { return }
        lastJump = (id, Date())
        if focused != id { focused = id }
        guard let comment = comments.first(where: { $0.id == id }), let textView,
              let range = pageRange(of: comment), NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.jump(to: range)
    }

    /// Focuses the comment whose passage holds the caret, if any.
    func caretMoved(scene: URL, location: Int) {
        let hit = comments.first {
            $0.scene == scene && !$0.resolved && $0.length > 0
                && location >= $0.location && location <= NSMaxRange($0.range)
        }
        if hit?.id != focused { focused = hit?.id }
    }

    private func sortComments() {
        let order = Dictionary(pageScenes.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        comments.sort {
            (order[$0.scene ?? $0.id.uuidURL] ?? 0, $0.location, $0.created)
                < (order[$1.scene ?? $1.id.uuidURL] ?? 0, $1.location, $1.created)
        }
    }

    private func refreshOpenCounts() {
        for scene in pageScenes {
            let open = comments.filter { $0.scene == scene && !$0.resolved }.count
            let value = open > 0 ? open : nil
            if openCounts[scene] != value { openCounts[scene] = value }
        }
    }

    private func refreshQuotes(scene: URL, in string: NSString) {
        for index in comments.indices where comments[index].scene == scene && comments[index].length > 0 {
            guard NSMaxRange(comments[index].range) <= string.length else {
                comments[index].length = 0
                continue
            }
            comments[index].quote = string.substring(with: comments[index].range)
            Self.fillContext(&comments[index], in: string)
        }
    }

    private static func fillContext(_ comment: inout SceneComment, in string: NSString) {
        let n = SceneComment.contextLength
        let start = max(0, comment.location - n)
        comment.prefix = string.substring(with: NSRange(location: start, length: comment.location - start))
        let end = NSMaxRange(comment.range)
        comment.suffix = string.substring(with: NSRange(location: end, length: min(n, string.length - end)))
    }

    // MARK: Scene details

    func info(for scene: URL) -> SceneInfo { infos[scene] ?? SceneInfo() }

    /// Changes a scene's details and saves them at once (they are small and change rarely).
    func setInfo(_ info: SceneInfo, for scene: URL) {
        guard infos[scene] ?? SceneInfo() != info, let url = infoURL(for: scene) else { return }
        infos[scene] = info.isEmpty ? nil : info
        if info.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(info) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The scene the margin is about, chosen on the cards without opening it.
    func focusScene(_ scene: URL, chapter: URL?, book: URL?) {
        show(scene: scene, chapter: chapter, book: book)
    }

    // MARK: Notes

    func setSceneNote(_ text: String) {
        guard text != sceneNote else { return }
        sceneNote = text
        notesDirty.insert(.scene)
        scheduleSave()
    }

    func setChapterNote(_ text: String) {
        guard text != chapterNote else { return }
        chapterNote = text
        notesDirty.insert(.chapter)
        scheduleSave()
    }

    func setOpenBookNoteText(_ text: String) {
        guard text != openBookNoteText else { return }
        openBookNoteText = text
        notesDirty.insert(.book)
        scheduleSave()
    }

    func reloadBookNotes() {
        guard let bookURL else { bookNotes = []; return }
        let folder = Self.notesFolder(of: bookURL)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        bookNotes = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return BookNote(url: url.canonical, title: url.deletingPathExtension().lastPathComponent, modified: date)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func openNote(_ note: BookNote?) {
        saveNow()
        openBookNote = note
        openBookNoteText = note.map { readText($0.url) } ?? ""
    }

    func createBookNote() {
        guard let bookURL else { return }
        saveNow()
        let folder = Self.notesFolder(of: bookURL)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = FileNaming.unique(folder.appendingPathComponent("Untitled Note.md"))
        guard (try? "".write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        reloadBookNotes()
        openNote(bookNotes.first { $0.url == url.canonical })
    }

    func renameBookNote(_ note: BookNote, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty, trimmed != note.title else { return }
        saveNow()
        let destination = FileNaming.unique(note.url.deletingLastPathComponent().appendingPathComponent(trimmed + ".md"))
        guard (try? FileManager.default.moveItem(at: note.url, to: destination)) != nil else { return }
        let wasOpen = openBookNote?.url == note.url
        reloadBookNotes()
        if wasOpen { openBookNote = bookNotes.first { $0.url == destination.canonical } }
    }

    func trashBookNote(_ note: BookNote) {
        saveNow()
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        if openBookNote?.url == note.url { openBookNote = nil }
        reloadBookNotes()
    }

    // MARK: Following the manuscript

    /// Moves comments and notes along with manuscript items that moved on disk. Two passes, so
    /// two items swapping places (and names) never overwrite each other's notes.
    func relocate(_ moves: [(from: URL, to: URL)]) {
        saveNow()
        coverCache = [:]
        guard let meta else { return }
        let fm = FileManager.default
        var staged: [(temp: URL, destination: URL)] = []
        for move in moves {
            guard let fromKey = key(move.from), let toKey = key(move.to), fromKey != toKey else { continue }
            for (folder, ext) in Self.sidecars {
                for (from, to) in [(fromKey + ext, toKey + ext), (fromKey, toKey)] {
                    let source = meta.appendingPathComponent("\(folder)/\(from)")
                    guard fm.fileExists(atPath: source.path) else { continue }
                    let temp = meta.appendingPathComponent("\(folder)/.moving-\(UUID().uuidString)")
                    if (try? fm.moveItem(at: source, to: temp)) != nil {
                        staged.append((temp, meta.appendingPathComponent("\(folder)/\(to)")))
                    }
                }
            }
        }
        for item in staged {
            try? fm.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: item.destination.path) {
                try? fm.trashItem(at: item.destination, resultingItemURL: nil)
            }
            try? fm.moveItem(at: item.temp, to: item.destination)
        }

        func moved(_ url: URL?) -> URL? {
            guard let url else { return nil }
            for move in moves {
                if let new = LibraryStore.relocated(url, from: move.from, to: move.to) { return new }
            }
            return url
        }
        sceneURL = moved(sceneURL)
        chapterURL = moved(chapterURL)
        bookURL = moved(bookURL)
        objectWillChange.send()
        pageScenes = pageScenes.compactMap { moved($0) }
        for index in comments.indices { comments[index].scene = moved(comments[index].scene) }
        if openBookNote != nil, bookURL != nil {
            let title = openBookNote!.title
            reloadBookNotes()
            openBookNote = bookNotes.first { $0.title == title }
        }
    }

    /// Sends an item's comments and notes to the Trash with it.
    func trash(_ item: URL) {
        saveNow()
        coverCache = [:]
        guard let meta, let key = key(item) else { return }
        let fm = FileManager.default
        for (folder, ext) in Self.sidecars {
            for path in [key + ext, key] {
                let url = meta.appendingPathComponent("\(folder)/\(path)")
                if fm.fileExists(atPath: url.path) { try? fm.trashItem(at: url, resultingItemURL: nil) }
            }
        }
        objectWillChange.send()
        let gone: (URL?) -> Bool = { url in url.map { LibraryStore.relocated($0, from: item, to: item) != nil } ?? false }
        comments.removeAll { gone($0.scene) }
        pageScenes.removeAll { gone($0) }
        if gone(sceneURL) { sceneURL = nil }
    }

    // MARK: Joining and splitting stories

    /// Writes a scene's comments file (or removes it when there are none).
    private func writeComments(_ list: [SceneComment], for scene: URL) {
        guard let url = commentsURL(for: scene) else { return }
        guard !list.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(CommentFile(comments: list)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Join into One Document: each scene's comments move to the document, shifted by where
    /// that scene's text now starts in it (UTF-16).
    func mergeComments(_ sources: [(scene: URL, offset: Int)], into target: URL) {
        saveNow()
        var merged = readComments(for: target)
        for source in sources {
            merged += readComments(for: source.scene).map { comment in
                var moved = comment
                moved.location += source.offset
                moved.scene = target
                return moved
            }
        }
        writeComments(merged, for: target)
    }

    /// Split into Chapters: the document's comments go to the part their passage starts in,
    /// shifted to that part's own text.
    func splitComments(of source: URL, into parts: [(scene: URL, start: Int, length: Int)]) {
        saveNow()
        var lists: [URL: [SceneComment]] = [:]
        for comment in readComments(for: source) {
            guard let part = parts.last(where: { comment.location >= $0.start }) ?? parts.first else { continue }
            var moved = comment
            moved.location = max(0, min(comment.location - part.start, part.length))
            moved.length = max(0, min(comment.length, part.length - moved.location))
            moved.scene = part.scene
            lists[part.scene, default: []].append(moved)
        }
        for (scene, list) in lists { writeComments(list, for: scene) }
    }

    /// Notes of the items joined, gathered into the target's note, each under its title.
    func mergeNotes(_ items: [(title: String, item: URL)], into target: URL) {
        saveNow()
        let parts = items.compactMap { entry -> String? in
            let text = noteURL(for: entry.item).map(readText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : "## \(entry.title)\n\n\(text)"
        }
        guard !parts.isEmpty else { return }
        let existing = noteURL(for: target).map(readText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        write(([existing].filter { !$0.isEmpty } + parts).joined(separator: "\n\n") + "\n", to: noteURL(for: target))
    }

    /// Everything kept beside the manuscript in `.longhand/`, by folder and file extension.
    private static let sidecars = [("comments", ".json"), ("notes", ".md"), ("scenes", ".json"), ("history", ""), ("covers", ".jpg"), ("covers", ".original.jpg")]

    // MARK: Book covers

    /// Moves when a cover is set or removed, so views showing covers look again.
    @Published private(set) var coverVersion = 0
    /// Called when a cover is set, cropped or removed, so it is committed and pushed like a
    /// save (covers sync through Git with everything else).
    var onFilesChanged: () -> Void = {}
    /// Each book's cover, or `.some(nil)` for a book known to have none. Emptied whenever
    /// files move, go to the Trash or are re-read, so a cover never sticks to an old path.
    private var coverCache: [URL: NSImage?] = [:]

    /// `.longhand/covers/<Book>.jpg`: kept beside the book's other details, moved with it.
    func coverURL(for book: URL) -> URL? {
        guard let meta, let key = key(book) else { return nil }
        return meta.appendingPathComponent("covers/\(key).jpg")
    }

    func cover(of book: URL) -> NSImage? {
        if let cached = coverCache[book] { return cached }
        let image = coverURL(for: book).flatMap { NSImage(contentsOf: $0) }
        coverCache[book] = .some(image)
        return image
    }

    /// The picture a cover was made from, kept whole so it can be cropped again.
    func coverOriginalURL(for book: URL) -> URL? {
        guard let meta, let key = key(book) else { return nil }
        return meta.appendingPathComponent("covers/\(key).original.jpg")
    }

    /// What Crop Cover works from: the original picture, or the cover itself for one set
    /// before originals were kept.
    func coverSource(of book: URL) -> NSImage? {
        coverOriginalURL(for: book).flatMap { NSImage(contentsOf: $0) } ?? cover(of: book)
    }

    static let coverRatio = 1.6

    /// Sets a book's cover from an image file: the picture is kept whole (as a JPEG, at most
    /// 4000 pixels on its longer side), and the cover is its middle in the Kindle shape
    /// (1:1.6) until `cropCover` chooses another part.
    @discardableResult
    func setCover(of book: URL, from file: URL) -> Bool {
        guard let source = NSImage(contentsOf: file), let original = coverOriginalURL(for: book),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let longest = max(cg.width, cg.height)
        let scale = min(1, 4000 / Double(longest))
        guard let whole = Self.jpeg(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
                                    width: Int(Double(cg.width) * scale), height: Int(Double(cg.height) * scale)) else { return false }
        try? FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? whole.write(to: original, options: .atomic)) != nil else { return false }
        return cropCover(of: book, to: nil)
    }

    /// Makes the cover from part of its picture. `unit` is that part as fractions of the
    /// picture (origin at the top left); nil is the largest 1:1.6 rectangle in the middle.
    @discardableResult
    func cropCover(of book: URL, to unit: CGRect?) -> Bool {
        guard let destination = coverURL(for: book), let source = coverSource(of: book),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let ratio = Self.coverRatio
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        var crop: CGRect
        if let unit {
            crop = CGRect(x: unit.minX * width, y: unit.minY * height, width: unit.width * width, height: unit.height * height)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            crop = height / width > ratio
                ? CGRect(x: 0, y: (height - width * ratio) / 2, width: width, height: width * ratio)
                : CGRect(x: (width - height / ratio) / 2, y: 0, width: height / ratio, height: height)
        }
        crop = crop.integral
        guard crop.width >= 1, crop.height >= 1 else { return false }
        let outWidth = min(1600, Int(crop.width)), outHeight = Int((Double(outWidth) * ratio).rounded())
        guard let data = Self.jpeg(cg, in: crop, width: outWidth, height: outHeight) else { return false }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return false }
        coverCache[book] = nil
        coverVersion += 1
        onFilesChanged()
        return true
    }

    /// Part of a picture, scaled to a size, as JPEG data.
    private static func jpeg(_ image: CGImage, in crop: CGRect, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, let cropped = image.cropping(to: crop),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    func removeCover(of book: URL) {
        guard let url = coverURL(for: book) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if let original = coverOriginalURL(for: book), FileManager.default.fileExists(atPath: original.path) {
            try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
        }
        coverCache[book] = nil
        coverVersion += 1
        onFilesChanged()
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes whatever changed. Empty notes and comment lists remove their files.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        for scene in dirtyScenes {
            guard let url = commentsURL(for: scene) else { continue }
            let kept = comments.filter {
                $0.scene == scene
                    && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.id == focused)
            }
            if kept.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(CommentFile(comments: kept)) {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        dirtyScenes = []
        for scope in notesDirty {
            switch scope {
            case .scene: write(sceneNote, to: sceneURL.flatMap(noteURL(for:)))
            case .chapter: write(chapterNote, to: chapterURL.flatMap(noteURL(for:)))
            case .book:
                if let note = openBookNote {
                    try? openBookNoteText.write(to: note.url, atomically: true, encoding: .utf8)
                }
            }
        }
        notesDirty = []
    }

    private func write(_ text: String, to url: URL?) {
        guard let url else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Notes are read like scenes, whatever they were saved as: a book's notes are ordinary
    /// files that another app may have written.
    private func readText(_ url: URL) -> String {
        String.prose(at: url) ?? ""
    }
}

private struct CommentFile: Codable {
    var version = 1
    var comments: [SceneComment]
}

private extension UUID {
    /// A stand-in URL for sorting a comment that has no scene (it sorts first).
    var uuidURL: URL { URL(fileURLWithPath: "/" + uuidString) }
}


// MARK: - Changes since the last version

extension MarginStore {
    /// A change bar on the page was clicked: the Changes tab shows that passage as it was.
    func showChange(_ bar: ChangeBar) {
        Commands.showChanges()
        changeFocus = bar
    }

    /// Puts a passage back as it was at the last version, through the text view so Undo
    /// reverses it and it saves like typing. Refused if the page moved on since the bar was
    /// drawn (the bars are worked out again after a pause).
    func putBack(_ bar: ChangeBar) {
        defer { changeFocus = nil }
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        guard NSMaxRange(bar.range) <= string.length,
              string.substring(with: bar.range) as NSString == bar.newText as NSString else {
            NSSound.beep()
            return
        }
        textView.window?.makeFirstResponder(textView)
        // As if typed: Undo records it, and the page restyles and saves it like any edit.
        textView.breakUndoCoalescing()
        textView.insertText(bar.oldText, replacementRange: bar.range)
        textView.breakUndoCoalescing()
        let restored = NSRange(location: bar.range.location, length: (bar.oldText as NSString).length)
        textView.setSelectedRange(NSRange(location: NSMaxRange(restored), length: 0))
        textView.scrollRangeToVisible(restored)
    }
}
