import Foundation
import AppKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var library: Library?
    @Published var selection: Selection? {
        didSet {
            guard oldValue != selection else { return }
            if case .scene(let url) = selection {
                recentScenes.removeAll { $0 == url }
                recentScenes.insert(url, at: 0)
                if recentScenes.count > 16 { recentScenes.removeLast() }
            }
            selectionChanged(from: oldValue)
            places.opened(selection)
            enterBook(of: selection)
            // The contents column shows the tab that holds what's open.
            switch selection {
            case .scene(let url):
                let tab: ContentsTab = isCut(url) ? .boneyard : .contents
                if contentsTab != tab { contentsTab = tab }
            case .chapter:
                if contentsTab != .contents { contentsTab = .contents }
            default:
                break
            }
        }
    }

    /// A chapter or scene chosen anywhere (the palette, a card, the path) puts the contents
    /// inside its story. Done here, not by the contents column, so it holds while that
    /// column is hidden: New Scene and New Chapter depend on it.
    private func enterBook(of selection: Selection?) {
        guard let library else { return }
        let book: Book?
        switch selection {
        case .chapter(let url): book = library.books.first { $0.chapters.contains { $0.url == url } }
        case .scene(let url): book = location(ofScene: url)?.book
        default: return
        }
        if let book, book.url != openBook { openBook = book.url }
    }
    /// The open scene's text. Not published: typing must not redraw the whole window. Views
    /// that show it watch `textVersion` (which moves only when the text is replaced from
    /// disk) or `live` (the counts under the page).
    private(set) var text: String = ""
    @Published private(set) var textVersion = 0
    /// Word and character counts of the open scene, updated on every keystroke for the count
    /// under the page only.
    let live = LiveCount()
    @Published private(set) var wordCounts: [URL: Int] = [:]
    /// A screenplay's length in pages (its own measure), brought up to date at each save.
    @Published private(set) var pageCounts: [URL: Int] = [:]
    private(set) var saveState: SaveState = .idle
    @Published private(set) var libraryURL: URL?
    @Published var errorMessage: String?
    @Published var pendingLibraryURL: URL?
    /// True from the first keystroke until the mouse moves: the top bar fades meanwhile.
    @Published var isTyping = false
    /// When the writer last typed (the pull from GitHub waits for a pause).
    private var lastEdit = Date.distantPast
    private var pullTask: Task<Void, Never>?
    /// Seconds without typing before a pull may replace files (the self-test shortens it).
    var pullPause: TimeInterval = 3
    private var revertingSelection = false
    /// Goes up each time the library is re-read from disk, so open views can refresh.
    @Published private(set) var reloadCount = 0

    /// Notes and comments, shown in the right-hand margin.
    let margin = MarginStore()
    /// Earlier versions of each scene.
    let history = HistoryStore()
    /// Save points for the whole library (Git), and its backup on GitHub.
    let versions = VersionStore()
    /// Where you were in each scene and chapter, and what you had open last.
    let places = Places()
    /// A version being looked at instead of the scene (from a scene's history in the Versions tab).
    @Published var historyPreview: HistoryStore.Version?

    private let defaults = UserDefaults.standard
    private let lastLibraryKey = "lastLibraryPath"
    private var activeSceneURL: URL?
    /// Scene edits made on the chapter page, waiting to be written.
    private var pendingWrites: [URL: String] = [:]
    private var saveTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        registerObservers()
        versions.pullRequested = { [weak self] in self?.pullRemote() }
        margin.onFilesChanged = { [weak self] in self?.versions.filesChanged() }
        // Dev switch: open a demo library for screenshots without changing the remembered one.
        if let path = ProcessInfo.processInfo.environment["LONGHAND_LIBRARY"] {
            let url = URL(fileURLWithPath: path)
            if isDirectory(url) { adoptLibrary(at: url.canonical, remember: false) }
        } else if let path = defaults.string(forKey: lastLibraryKey) {
            let url = URL(fileURLWithPath: path)
            if isDirectory(url) { adoptLibrary(at: url.canonical) }
        }
    }

    // MARK: - Opening

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose or create a folder for your library."
        if panel.runModal() == .OK, let url = panel.url {
            openLibrary(at: url)
        }
    }

    func openLibrary(at rawURL: URL) {
        let url = rawURL.canonical
        guard isDirectory(url) else {
            errorMessage = "That folder can’t be found."
            return
        }

        // Adopting an arbitrary folder treats each folder inside it as a book, which would be
        // alarming if someone picked Documents by mistake. Ask first.
        let hasMetadata = FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".longhand").path
        )
        let visibleContents = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }

        if !hasMetadata && !visibleContents.isEmpty {
            pendingLibraryURL = url
            return
        }

        adoptLibrary(at: url)
    }

    func confirmPendingLibrary() {
        guard let url = pendingLibraryURL else { return }
        pendingLibraryURL = nil
        adoptLibrary(at: url)
    }

    private func adoptLibrary(at url: URL, remember: Bool = true) {
        saveNow()
        if libraryURL != nil { endSession() }
        ensureMetadata(at: url)
        margin.open(root: url)
        history.open(root: url)
        versions.open(root: url)
        places.open(root: url)
        libraryURL = url
        if remember { defaults.set(url.path, forKey: lastLibraryKey) }

        activeSceneURL = nil
        setText("")
        selection = nil
        // Hidden test runs and pictures start on the first scene, as they always have.
        guard !Snapshot.isBackgroundRun else {
            reload(select: .firstScene)
            if let last = places.lastOpened, contains(last) { selection = last }
            return
        }
        reload(select: .none)
        openOnLibrary()
    }

    /// Opening a library shows the Library (owner, 2026-11-14: "opening the app should take you
    /// to the library"), with the story you were last in chosen, its page beside the list.
    /// Going in finds your place in each scene as before.
    func openOnLibrary() {
        let last = places.lastOpened.flatMap { opened -> Book? in
            switch opened {
            case .book(let url): return book(for: url)
            case .chapter(let url): return library?.books.first { $0.chapters.contains { $0.url == url } }
            case .scene(let url): return location(ofScene: url)?.book
            }
        }
        openBook = nil
        if let story = last ?? library?.books.first { selection = .book(story.url) }
    }

    private func contains(_ selection: Selection) -> Bool {
        switch selection {
        case .scene(let url): return scene(for: url) != nil
        case .chapter(let url): return chapter(for: url) != nil
        case .book(let url): return book(for: url) != nil
        }
    }

    func closeLibrary() {
        saveNow()
        places.save()
        places.open(root: nil)
        endSession()
        selection = nil
        openBook = nil
        activeSceneURL = nil
        setText("")
        library = nil
        libraryURL = nil
        margin.open(root: nil)
        history.open(root: nil)
        versions.open(root: nil)
        defaults.removeObject(forKey: lastLibraryKey)
    }

    /// File › Compare Versions…: what changed since the last draft, word by word.
    func compareVersions() {
        saveNow()
        historyPreview = nil
        versions.startComparing()
    }

    /// Puts one scene back as it was in the comparison's older version. The present text is
    /// kept in the scene's History first. A removed scene comes back at its old place.
    func restoreScene(_ change: Comparison.SceneChange) {
        guard let root = libraryURL, let older = versions.olderText(of: change) else { return }
        saveNow()
        let url = root.appendingPathComponent(change.status == .removed ? (change.oldPath ?? change.path) : change.path).canonical
        let fm = FileManager.default
        if let current = String.prose(at: url) {
            history.keep(current, of: url)
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try older.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn’t restore the scene."
            return
        }
        if activeSceneURL == url {
            setText(older)
            saveState = .idle
        }
        reload(select: .keep)
        versions.recompare()
    }

    /// Puts the whole library back as it was in the comparison's older version.
    func restoreLibrary(done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let root = libraryURL else { return done(false) }
        _ = root
        saveNow()
        versions.restoreAll { [weak self] ok in
            guard let self else { return done(ok) }
            if ok {
                self.filesReplaced()
                self.versions.recompare()
            } else {
                self.errorMessage = "Couldn’t restore that commit. Nothing was changed."
            }
            done(ok)
        }
    }

    /// After Git replaced the files (a restore, or moving to or from a rewrite): reads the
    /// library again, and the open scene, notes and comments with it.
    private func filesReplaced() {
        CanonicalPaths.shared.forget()
        guard let root = libraryURL else { return }
        margin.open(root: root)
        saveState = .idle
        pendingWrites = [:]
        reload(select: .keep)
        if let url = activeSceneURL {
            if FileManager.default.fileExists(atPath: url.path) {
                // Only when the file really changed: replacing the text clears Undo and
                // interrupts whatever is being composed.
                let fresh = read(url)
                if !(fresh as NSString).isEqual(to: text) { setText(fresh) }
                wordCounts[url] = live.words
            } else {
                activeSceneURL = nil
                setText("")
            }
        }
        syncMargin()
        if selection == nil, let first = library?.books.first?.chapters.first?.scenes.first {
            selection = .scene(first.url)
        }
    }

    // MARK: - Rewrites

    /// Starts a rewrite from the manuscript as it is now and moves onto it. The files don't
    /// change: the rewrite starts identical.
    func startRewrite(title: String) {
        guard saveEverything() else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !versions.startRewrite(title: name.isEmpty ? "Rewrite" : name) {
            errorMessage = "Couldn’t create the branch. Nothing was changed."
        }
    }

    /// Moves to a rewrite, or back to the manuscript (nil).
    func switchTo(_ rewrite: Rewrite?) {
        guard saveEverything() else { return }
        historyPreview = nil
        if versions.switchTo(rewrite) {
            filesReplaced()
        } else {
            errorMessage = "Couldn’t switch branch. Nothing was changed."
        }
    }

    /// Keeps the open rewrite: straight away if the manuscript hasn't changed where the
    /// rewrite did, otherwise by showing the passages to choose between.
    func keepRewrite() {
        guard saveEverything() else { return }
        guard let plan = versions.planKeep() else {
            errorMessage = "Couldn’t prepare the merge. Nothing was changed."
            return
        }
        if plan.hasConflicts {
            historyPreview = nil
            versions.mergePlan = plan
        } else {
            finishKeep(plan)
        }
    }

    func finishKeep(_ plan: MergePlan) {
        guard saveEverything() else { return }
        if versions.finishKeep(plan) {
            filesReplaced()
        } else {
            errorMessage = "Couldn’t merge the branch. Nothing was changed."
        }
    }

    func discardRewrite() {
        guard saveEverything() else { return }
        if versions.discardRewrite() {
            filesReplaced()
        } else {
            errorMessage = "Couldn’t delete the branch. Nothing was changed."
        }
    }

    /// The remote has commits this Mac lacks (pushed from another Mac, or edited on GitHub):
    /// saves, brings them in and re-reads the files. If both sides changed the same lines
    /// nothing is touched; the status bar says so and Git Activity offers Keep Both.
    ///
    /// Waits for a pause: the pull replaces files under the editor and holds the window for
    /// a moment, so it never runs mid-sentence or while a merge is being chosen.
    func pullRemote() {
        pullTask?.cancel()
        let busy = Date().timeIntervalSince(lastEdit) < pullPause || saveState == .edited || saveState == .saving
            || versions.mergePlan != nil
        guard !busy else {
            pullTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0.2, self?.pullPause ?? 3)))
                guard !Task.isCancelled else { return }
                self?.pullRemote()
            }
            return
        }
        guard saveEverything() else { return }
        historyPreview = nil
        if versions.pull() == .updated { filesReplaced() }
    }

    /// Writes unsaved prose, comments and notes before Git replaces files. False (with the
    /// error shown) if a scene couldn't be written: nothing may then replace what's open.
    private func saveEverything() -> Bool {
        saveNow()
        margin.saveNow()
        return saveState != .edited
    }

    /// Quitting: saves, then commits and pushes in the background, reporting each stage, and
    /// calls `done` when it may exit.
    func finishForQuit(stage: @escaping @MainActor (Bool) -> Void, done: @escaping @MainActor () -> Void) {
        saveNow()
        places.save()
        let words = library?.books.reduce(0) { $0 + wordCount(of: $1) } ?? 0
        versions.endSessionInBackground(words: words, stage: stage, done: done)
    }

    /// Records a version of the library if anything changed since the last one.
    private func endSession() {
        let words = library?.books.reduce(0) { $0 + wordCount(of: $1) } ?? 0
        versions.endSession(words: words)
    }

    // MARK: - Reading the folder

    private enum ReloadSelection {
        case keep, firstScene, none
    }

    private func reload(select: ReloadSelection) {
        CanonicalPaths.shared.forget()
        guard let root = libraryURL else { return }
        let previous = selection
        let scanned = scanLibrary(at: root)
        library = scanned.library
        // The story the contents was inside may be gone (trashed, or removed outside
        // Longhand): back to the Library, so New Story works and New Scene isn't offered.
        if let open = openBook, !scanned.library.books.contains(where: { $0.url == open }) { openBook = nil }
        wordCounts = scanned.counts
        countScreenplayPages()
        reloadCount += 1
        versions.scheduleChanges()
        versions.filesChanged()
        margin.refreshCounts(
            scenes: scanned.library.books.flatMap { $0.chapters + ($0.boneyard.map { [$0] } ?? []) }.flatMap(\.scenes).map(\.url),
            books: scanned.library.books.map(\.url) + scanned.library.books.flatMap(\.chapters).map(\.url)
        )

        switch select {
        case .firstScene:
            if let first = scanned.library.books.first?.chapters.first?.scenes.first {
                selection = .scene(first.url)
            }
        case .keep:
            if let previous, FileManager.default.fileExists(atPath: previous.url.path) {
                if selection != previous { selection = previous }
                if case .scene(let url) = previous, activeSceneURL == url {
                    let disk = read(url)
                    if !(disk as NSString).isEqual(to: text) {
                        setText(disk)
                        wordCounts[url] = Self.wordCount(disk)
                    }
                }
            } else {
                selection = nil
            }
        case .none:
            break
        }
    }

    private struct ScanResult {
        var library: Library
        var counts: [URL: Int]
    }

    private func scanLibrary(at root: URL) -> ScanResult {
        let fm = FileManager.default
        let bookURLs = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var books: [Book] = []
        var folders: [Folder] = []
        var counts: [URL: Int] = [:]
        let groups = LibraryFolders.groups(in: root)

        func scanBook(_ rawBookURL: URL, folder: URL?) -> Book {
            let bookURL = rawBookURL.canonical
            let bookName = FileNaming.decode(bookURL.lastPathComponent)

            let chapterURLs = (try? fm.contentsOfDirectory(
                at: bookURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var chapters: [Chapter] = []
            // `Notes` holds the book's notes, not a chapter.
            for rawChapterURL in chapterURLs
            where isDirectory(rawChapterURL) && rawChapterURL.lastPathComponent != "Notes"
                && rawChapterURL.lastPathComponent != Self.boneyardFolder {
                let chapterURL = rawChapterURL.canonical
                let chapterName = FileNaming.decode(chapterURL.lastPathComponent)

                let sceneURLs = (try? fm.contentsOfDirectory(
                    at: chapterURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []

                var scenes: [Scene] = []
                // In a chapter, Markdown only: a screenplay is a story of its own (one file).
                for rawSceneURL in sceneURLs where rawSceneURL.pathExtension.lowercased() == ProseFile.markdown {
                    let sceneURL = rawSceneURL.canonical
                    let sceneName = FileNaming.decode(sceneURL.deletingPathExtension().lastPathComponent)
                    let content = read(sceneURL)
                    counts[sceneURL] = Self.wordCount(content)
                    scenes.append(Scene(url: sceneURL, title: sceneName.title, order: sceneName.order))
                }

                scenes.sort(by: ordered)
                chapters.append(Chapter(
                    url: chapterURL,
                    title: chapterName.title,
                    order: chapterName.order,
                    scenes: scenes
                ))
            }

            chapters.sort(by: ordered)

            // The shape the story was given; the files on disk have the last word.
            let stored = Self.storedShape(of: bookURL, root: root)
            var shape: BookShape
            if chapters.isEmpty {
                // Scenes only, or one document: Markdown files straight in the story's folder,
                // read as the scenes of an implicit chapter that is the story's folder itself.
                var scenes: [Scene] = []
                // A Fountain file counts only as the story's one document (a screenplay), never
                // beside other files: every other view treats a story's files as Markdown.
                let loose = chapterURLs.filter { ProseFile.isProse($0) && !isDirectory($0) }
                let usable = loose.count == 1 ? loose : loose.filter { $0.pathExtension.lowercased() == ProseFile.markdown }
                for rawSceneURL in usable {
                    let sceneURL = rawSceneURL.canonical
                    let sceneName = FileNaming.decode(sceneURL.deletingPathExtension().lastPathComponent)
                    counts[sceneURL] = Self.wordCount(read(sceneURL))
                    scenes.append(Scene(url: sceneURL, title: sceneName.title, order: sceneName.order))
                }
                scenes.sort(by: ordered)
                if scenes.isEmpty && !(stored == .scenes || stored == .document) {
                    shape = stored ?? .chaptersAndScenes
                } else {
                    chapters = [Chapter(url: bookURL, title: bookName.title, order: 0, scenes: scenes, implicit: true)]
                    shape = stored == .scenes || scenes.count > 1 ? .scenes : .document
                }
            } else {
                shape = stored == .chapters ? .chapters : .chaptersAndScenes
            }
            // The Boneyard: cut scenes and passages, kept apart from the chapters.
            var boneyard: Chapter?
            let boneyardURL = bookURL.appendingPathComponent(Self.boneyardFolder, isDirectory: true)
            if isDirectory(boneyardURL) {
                var cut: [Scene] = []
                for raw in (try? fm.contentsOfDirectory(at: boneyardURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                where ProseFile.isProse(raw) && !isDirectory(raw) {
                    let url = raw.canonical
                    let name = FileNaming.decode(url.deletingPathExtension().lastPathComponent)
                    counts[url] = Self.wordCount(read(url))
                    cut.append(Scene(url: url, title: name.title, order: name.order))
                }
                if !cut.isEmpty {
                    cut.sort(by: ordered)
                    boneyard = Chapter(url: boneyardURL.canonical, title: "Boneyard", order: 0, scenes: cut, boneyard: true)
                }
            }
            return Book(url: bookURL, title: bookName.title, order: bookName.order, chapters: chapters, folder: folder, shape: shape,
                        boneyard: boneyard)
        }

        for rawURL in bookURLs where isDirectory(rawURL) {
            if groups.contains(rawURL.lastPathComponent) {
                // A folder of books: its own name, whole, is its title.
                let folderURL = rawURL.canonical
                folders.append(Folder(url: folderURL, title: folderURL.lastPathComponent))
                let inside = (try? fm.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                var grouped = inside.filter { isDirectory($0) }.map { scanBook($0, folder: folderURL) }
                grouped.sort(by: ordered)
                books += grouped
            }
        }
        var loose = bookURLs.filter { isDirectory($0) && !groups.contains($0.lastPathComponent) }.map { scanBook($0, folder: nil) }
        loose.sort(by: ordered)
        folders.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        // Folders first, in name order, each with its books; then the books at the top.
        books = folders.flatMap { folder in books.filter { $0.folder == folder.url } } + loose
        return ScanResult(
            library: Library(url: root, name: root.lastPathComponent, books: books, folders: folders),
            counts: counts
        )
    }

    /// The shape kept with a story's details (`.longhand/scenes/<Story>.json`), read while
    /// scanning, before the margin has loaded them.
    static func storedShape(of book: URL, root: URL) -> BookShape? {
        let base = root.canonical.path + "/"
        let path = book.canonical.path
        guard path.hasPrefix(base) else { return nil }
        let url = root.appendingPathComponent(".longhand/scenes/\(path.dropFirst(base.count)).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(SceneInfo.self, from: data))?.shape
    }

    private func ordered<T>(_ a: T, _ b: T, order: (T) -> Int, title: (T) -> String) -> Bool {
        if order(a) != order(b) { return order(a) < order(b) }
        return title(a).localizedStandardCompare(title(b)) == .orderedAscending
    }

    private func ordered(_ a: Book, _ b: Book) -> Bool {
        ordered(a, b, order: { $0.order }, title: { $0.title })
    }

    private func ordered(_ a: Chapter, _ b: Chapter) -> Bool {
        ordered(a, b, order: { $0.order }, title: { $0.title })
    }

    private func ordered(_ a: Scene, _ b: Scene) -> Bool {
        ordered(a, b, order: { $0.order }, title: { $0.title })
    }

    private func read(_ url: URL) -> String {
        String.prose(at: url) ?? ""
    }

    /// Setting a long script on pages takes tens of milliseconds: never on the main thread.
    private static let pageQueue = DispatchQueue(label: "longhand.screenplay-pages", qos: .utility)

    /// Pages of every screenplay in the library, read from disk.
    private func countScreenplayPages() {
        let scripts = (library?.books ?? []).compactMap { $0.isScreenplay ? $0.document?.url : nil }
        guard !scripts.isEmpty || !pageCounts.isEmpty else { return }
        // The open one as it is on screen; the rest read from disk, off the main thread.
        let open = activeSceneURL.map { ($0, text) }
        Self.pageQueue.async {
            var pages: [URL: Int] = [:]
            for url in scripts {
                let text = open?.0 == url ? open!.1 : (String.prose(at: url) ?? "")
                pages[url] = ScreenplayLayout.pageCount(text)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if pages != self.pageCounts { self.pageCounts = pages }
            }
        }
    }

    private func countPages(_ url: URL, text: String) {
        guard url.pathExtension.lowercased() == ProseFile.fountain else { return }
        Self.pageQueue.async {
            let pages = ScreenplayLayout.pageCount(text)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pageCounts[url] != pages { self.pageCounts[url] = pages }
            }
        }
    }

    /// A screenplay's pages ("14 pages").
    func pages(of scene: Scene) -> Int { pageCounts[scene.url] ?? 0 }

    /// What a story's target counts (owner, 2026-11-14): pages for a screenplay, words for
    /// anything else. The target itself is one number either way (`SceneInfo.target`).
    func targetProgress(of book: Book) -> (done: Int, unit: String) {
        if book.isScreenplay, let script = book.document { return (pages(of: script), "pages") }
        return (wordCount(of: book), "words")
    }

    // MARK: - Editing and autosave

    /// The open scene's text changed. `fromEditor` is true when the editor itself reports
    /// typing; anything else (a test, a script) also puts the new text on screen.
    /// `version` is the `textVersion` the editor last loaded. A report from an editor still
    /// holding older text (the scene was switched, or a pull replaced the file, and the key
    /// arrived before the editor reloaded) is dropped: saving it would write the old text
    /// over the new file.
    func updateText(_ newText: String, fromEditor: Bool = false, version: Int? = nil) {
        if let version, version != textVersion { return }
        lastEdit = Date()
        if !isTyping { isTyping = true }
        text = newText
        live.update(newText)
        if !fromEditor { textVersion += 1 }
        if saveState != .edited { saveState = .edited }
        scheduleSave()
    }

    /// Replaces the open scene's text from disk (or clears it), so the editor reloads.
    private func setText(_ newText: String) {
        text = newText
        textVersion += 1
        // Lines are counted only for poems and songs (it costs a pass over the text per key).
        live.countsLines = activeSceneURL.flatMap { location(ofScene: $0) }
            .map { margin.info(for: $0.book.url).form?.isVerse == true } ?? false
        live.update(newText)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// An edit to one scene made on the chapter page. Saved like the scene editor's: after a
    /// short pause, and at once on switching, leaving the app or quitting.
    func updateChapterScene(_ url: URL, text newText: String) {
        pendingWrites[url] = newText
        lastEdit = Date()
        if !isTyping { isTyping = true }
        if saveState != .edited { saveState = .edited }
        scheduleSave()
    }

    /// Writes whatever has unsaved edits: the open scene, and any scenes edited on the chapter
    /// page. Never rewrites an unchanged file, so a scene edited in another app is
    /// not overwritten with stale text.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard saveState == .edited else { return }
        saveState = .saving
        var failed = false

        // Word counts are brought up to date here, once per save, not on every keystroke: they
        // redraw the contents column.
        var counts = wordCounts
        if let url = activeSceneURL {
            do {
                history.keepBeforeWriting(url, newText: text)
                try text.write(to: url, atomically: true, encoding: .utf8)
                counts[url] = live.words
                countPages(url, text: text)
            } catch {
                failed = true
            }
        }
        for (url, sceneText) in pendingWrites {
            counts[url] = Self.wordCount(sceneText)
            do {
                history.keepBeforeWriting(url, newText: sceneText)
                try sceneText.write(to: url, atomically: true, encoding: .utf8)
                pendingWrites[url] = nil
            } catch {
                failed = true
            }
        }

        if counts != wordCounts { wordCounts = counts }
        margin.saveNow()

        if failed {
            saveState = .edited
            errorMessage = "Couldn’t save this scene. Your text is still here; check the disk and the library folder."
        } else {
            saveState = .saved
        }
        versions.scheduleChanges()
        versions.filesChanged()
    }

    private func loadScene(at url: URL) {
        activeSceneURL = url
        let contents = read(url)
        setText(contents)
        wordCounts[url] = live.words
        countPages(url, text: contents)
        saveState = .idle
    }

    /// Puts an earlier version back, keeping the current text as a version first, so the
    /// restore itself can be undone from the scene's history.
    func restore(_ version: HistoryStore.Version) {
        guard let url = activeSceneURL else { return }
        saveNow()
        history.keep(text, of: url)
        updateText(history.text(of: version))
        saveNow()
        historyPreview = nil
    }

    private func selectionChanged(from old: Selection?) {
        guard !revertingSelection else { return }
        if historyPreview != nil { historyPreview = nil }
        if versions.comparing { versions.comparing = false }
        saveNow()
        // The open scene couldn't be written (disk full, folder gone): stay on it. Leaving
        // would load another scene over the only copy of that text.
        if saveState == .edited {
            revertingSelection = true
            selection = old
            revertingSelection = false
            return
        }
        _ = old
        activeSceneURL = nil
        saveState = .idle

        syncMargin()
        if case .scene(let url) = selection {
            loadScene(at: url)
        } else {
            setText("")
        }
    }

    /// Points the margin at the selected scene, its chapter and its book.
    private func syncMargin() {
        switch selection {
        case .scene(let url):
            let place = location(ofScene: url)
            margin.show(scene: url, chapter: place?.chapter.url, book: place?.book.url)
        case .chapter(let url):
            let book = library?.books.first { $0.chapters.contains { $0.url == url } }
            margin.show(scene: nil, chapter: url, book: book?.url)
        case .book(let url):
            margin.show(scene: nil, chapter: nil, book: url)
        case nil:
            margin.show(scene: nil, chapter: nil, book: nil)
        }
    }

    func refreshFromDisk() {
        guard libraryURL != nil else { return }
        guard saveState != .edited && saveState != .saving else { return }
        reload(select: .keep)
    }

    // MARK: - Creating

    /// File › New Document (owner, 2026-11-14): shows the sheet of forms (`NewDocumentSheet`).
    @Published var newDocumentShown = false

    /// A new story of the chosen form, divided as chosen, opened at its first page of text.
    func createBook(title rawTitle: String = "", form: BookForm? = nil, shape: BookShape = .chaptersAndScenes,
                    collection: Bool? = nil, author: AuthorProfile? = nil) {
        guard let root = libraryURL else { return }
        let books = library?.books ?? []
        let order = (books.map(\.order).max() ?? 0) + 1
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? NewDocumentSheet.untitled(form, collection: collection) : trimmed
        let bookURL = FileNaming.unique(root.appendingPathComponent(
            FileNaming.name(order: order, title: title)
        )).canonical

        do {
            try FileManager.default.createDirectory(at: bookURL, withIntermediateDirectories: true)
            let sceneURL: URL
            let names = PartNames.of(form, collection: collection)
            let firstChapter = "\(names.chapter) One"
            switch shape {
            case .chaptersAndScenes:
                let chapterURL = try createChapterFolder(in: bookURL, title: firstChapter, order: 1)
                sceneURL = try createSceneFile(in: chapterURL, title: "Untitled \(names.scene)", order: 1)
            case .chapters:
                let chapterURL = try createChapterFolder(in: bookURL, title: firstChapter, order: 1)
                sceneURL = try createSceneFile(in: chapterURL, title: firstChapter, order: nil)
            case .scenes:
                sceneURL = try createSceneFile(in: bookURL, title: "Untitled \(names.scene)", order: 1)
            case .document:
                sceneURL = try createSceneFile(in: bookURL, title: FileNaming.decode(bookURL.lastPathComponent).title, order: nil,
                                               extension: form == .screenplay ? ProseFile.fountain : ProseFile.markdown)
            }
            var info = margin.info(for: bookURL)
            info.form = form
            info.shape = shape == .chaptersAndScenes ? nil : shape
            // Stored only when it differs from the form's own default.
            if let form, form.collects, let collection, collection != form.collectionByDefault { info.collection = collection }
            if let author { info.setAuthor(author) }
            margin.setInfo(info, for: bookURL)
            reload(select: .none)
            openBook = bookURL
            selection = .scene(sceneURL)
        } catch {
            errorMessage = "Couldn’t create a story."
        }
    }

    /// A new screenplay story holding `text` (Fountain), opened. Returns its script's file.
    @discardableResult
    func createScreenplay(title: String, text: String) -> URL? {
        createBook(title: title, form: .screenplay, shape: .document)
        guard case .scene(let url) = selection, url.pathExtension.lowercased() == ProseFile.fountain else { return nil }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn’t write the screenplay."
            return nil
        }
        reload(select: .keep)
        if activeSceneURL == url { setText(text) }
        countPages(url, text: text)
        versions.filesChanged()
        return url
    }

    // MARK: - Folders

    /// Library › New Folder: a plain folder at the top of the library, to put stories in.
    @discardableResult
    func createFolder(named name: String = "Untitled Folder") -> URL? {
        guard let root = libraryURL else { return nil }
        saveNow()
        let url = FileNaming.unique(root.appendingPathComponent(FileNaming.sanitized(name), isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn’t create a folder."
            return nil
        }
        LibraryFolders.setListed(LibraryFolders.listed(root) + [url.lastPathComponent], in: root)
        reload(select: .keep)
        return url.canonical
    }

    func renameFolder(_ folder: URL, to newName: String) {
        guard let root = libraryURL else { return }
        let name = FileNaming.sanitized(newName)
        guard name != folder.lastPathComponent else { return }
        saveNow()
        let destination = FileNaming.unique(root.appendingPathComponent(name, isDirectory: true))
        do {
            try FileManager.default.moveItem(at: folder, to: destination)
        } catch {
            errorMessage = "Couldn’t rename the folder."
            return
        }
        let names = LibraryFolders.listed(root).filter { $0 != folder.lastPathComponent } + [destination.lastPathComponent]
        LibraryFolders.setListed(names, in: root)
        follow([(folder, destination.canonical)])
    }

    /// Moves a story into a folder, or out to the top of the library (nil). Its notes,
    /// comments, history and cover go with it, and its versions follow the move.
    func moveBook(_ book: URL, toFolder folder: URL?) {
        guard let root = libraryURL, let current = self.book(for: book), current.folder != folder else { return }
        saveNow()
        let parent = folder ?? root
        let destination = FileNaming.unique(parent.appendingPathComponent(book.lastPathComponent, isDirectory: true))
        do {
            try FileManager.default.moveItem(at: book, to: destination)
        } catch {
            errorMessage = "Couldn’t move it."
            return
        }
        // A folder that shape alone made a group stays one when its last story leaves, and a
        // folder a story goes into is listed by name: a single document (a file straight in its
        // story's folder) would otherwise make it look like a story itself.
        let named = [current.folder, folder].compactMap { $0?.lastPathComponent }
        LibraryFolders.setListed(Array(Set(LibraryFolders.listed(root) + named)), in: root)
        follow([(book, destination.canonical)])
    }

    /// Removes a folder that has no stories in it (to the Trash). A folder with stories is
    /// left alone: move them out first.
    func deleteFolder(_ folder: URL) {
        guard let root = libraryURL, library?.books(in: folder).isEmpty == true else {
            errorMessage = "Move the stories out of this folder first."
            return
        }
        saveNow()
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            errorMessage = "Couldn’t move it to the Trash."
            return
        }
        LibraryFolders.setListed(LibraryFolders.listed(root).filter { $0 != folder.lastPathComponent }, in: root)
        reload(select: .keep)
    }

    /// What a story calls its parts (a notebook: folders and notes).
    func names(of bookURL: URL?) -> PartNames {
        bookURL.map { let info = margin.info(for: $0); return PartNames.of(info.form, collection: info.collection) } ?? .story
    }

    /// The names in the story in hand (the menus' New Scene and New Chapter).
    var contextNames: PartNames { names(of: contextBook?.url) }

    /// The names in the story an item belongs to.
    func names(for item: ManuscriptItem) -> PartNames {
        switch item.kind {
        case .book: return names(of: item.url)
        case .chapter: return names(of: library?.books.first { $0.chapters.contains { $0.url == item.url } }?.url)
        case .scene: return names(of: location(ofScene: item.url)?.book.url)
        }
    }

    /// Whether the story in hand can take a new chapter, or a new scene: a single document
    /// takes neither, a scenes-only story no chapters, a chapters-only story no scenes.
    var canAddChapter: Bool { contextBook?.shape.hasChapters ?? false }
    var canAddScene: Bool { contextBook?.shape.hasScenes ?? false }

    func createChapterInContext() {
        // Chapters are made inside a story; a new story is made in the Library.
        guard let book = contextBook else { return }
        createChapter(in: book.url)
    }

    /// A new chapter at the end of a story. Opened unless `open` is false (the cards: the new
    /// card is edited in place). Returns its first file.
    @discardableResult
    func createChapter(in bookURL: URL, open: Bool = true) -> URL? {
        guard let book = book(for: bookURL), book.shape.hasChapters else { return nil }
        do {
            let order = (book.chapters.map(\.order).max() ?? 0) + 1
            let names = self.names(of: book.url)
            let chapterURL = try createChapterFolder(in: book.url, title: "Untitled \(names.chapter)", order: order)
            // Chapters only: the chapter's one file carries the chapter's name.
            let sceneURL = book.shape == .chapters
                ? try createSceneFile(in: chapterURL, title: "Untitled \(names.chapter)", order: nil)
                : try createSceneFile(in: chapterURL, title: "Untitled \(names.scene)", order: 1)
            reload(select: .none)
            if open { selection = .scene(sceneURL) }
            return sceneURL
        } catch {
            errorMessage = "Couldn’t create a chapter."
            return nil
        }
    }

    func createSceneInContext() {
        guard contextBook?.shape.hasScenes ?? true else { return }
        if let chapter = contextChapter {
            createScene(in: chapter)
        } else if let book = contextBook {
            do {
                let order = (book.chapters.map(\.order).max() ?? 0) + 1
                let names = self.names(of: book.url)
                let chapterURL = try createChapterFolder(in: book.url, title: "Untitled \(names.chapter)", order: order)
                let sceneURL = try createSceneFile(in: chapterURL, title: "Untitled \(names.scene)", order: 1)
                reload(select: .none)
                selection = .scene(sceneURL)
            } catch {
                errorMessage = "Couldn’t create a scene."
            }
        }
    }

    /// A new scene at the end of a chapter (the cards' New Scene). Opened unless `open` is
    /// false. Returns its file.
    @discardableResult
    func createScene(inChapter chapterURL: URL, open: Bool = true) -> URL? {
        guard let chapter = chapter(for: chapterURL) else { return nil }
        return createScene(in: chapter, open: open)
    }

    @discardableResult
    private func createScene(in chapter: Chapter, open: Bool = true) -> URL? {
        do {
            let order = (chapter.scenes.map(\.order).max() ?? 0) + 1
            // In the story's words: a chapter's folder is the story's, or (loose scenes) the story itself.
            let story = chapter.implicit ? chapter.url : chapter.url.deletingLastPathComponent().canonical
            let url = try createSceneFile(in: chapter.url, title: "Untitled \(names(of: story).scene)", order: order)
            reload(select: .none)
            if open { selection = .scene(url) }
            return url
        } catch {
            errorMessage = "Couldn’t create a scene."
            return nil
        }
    }

    private func createChapterFolder(in bookURL: URL, title: String, order: Int) throws -> URL {
        let url = FileNaming.unique(bookURL.appendingPathComponent(FileNaming.name(order: order, title: title)))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.canonical
    }

    /// A new Markdown file. Without an order its name is just the title (a single document's
    /// file, or a chapters-only chapter's).
    private func createSceneFile(in chapterURL: URL, title: String, order: Int?, extension ext: String = ProseFile.markdown) throws -> URL {
        let name = order.map { FileNaming.name(order: $0, title: title) } ?? FileNaming.sanitized(title)
        let url = FileNaming.unique(chapterURL.appendingPathComponent(name + "." + ext))
        try "".write(to: url, atomically: true, encoding: .utf8)
        return url.canonical
    }

    // MARK: - Renaming, moving, deleting

    func rename(_ item: ManuscriptItem, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveNow()

        do {
            // A chapters-only chapter's file, or a single document, carries the name too.
            let inner: URL? = {
                switch item.kind {
                case .chapter:
                    guard let found = library?.books.first(where: { $0.chapters.contains { $0.url == item.url } }),
                          found.shape == .chapters else { return nil }
                    return found.chapters.first { $0.url == item.url }?.scenes.first?.url
                case .book: return book(for: item.url)?.document?.url
                case .scene: return nil
                }
            }()
            let newURL = try renameFile(item.url, kind: item.kind, order: item.order, title: trimmed)
            var moves: [(from: URL, to: URL)] = []
            if let inner, let carried = Self.relocated(inner, from: item.url, to: newURL) {
                let named = FileNaming.unique(carried.deletingLastPathComponent().appendingPathComponent(FileNaming.sanitized(trimmed) + "." + carried.pathExtension))
                if named.lastPathComponent != carried.lastPathComponent, (try? FileManager.default.moveItem(at: carried, to: named)) != nil {
                    // First, so the file's own move wins over its folder's.
                    moves.append((inner, named.canonical))
                }
            }
            moves.append((item.url, newURL))
            follow(moves)
        } catch {
            errorMessage = "Couldn’t rename \(item.kind == .book ? "the story" : item.kind == .chapter ? "the chapter" : "the scene")."
        }
    }

    func move(_ item: ManuscriptItem, by offset: Int) {
        let siblings = siblings(of: item)
        guard let index = siblings.firstIndex(where: { $0.url == item.url }) else { return }
        let otherIndex = index + offset
        guard siblings.indices.contains(otherIndex) else { return }
        let other = siblings[otherIndex]

        saveNow()

        // Park the first item under a hidden name while the two swap, so two items with the
        // same title keep that title instead of one becoming "… 2".
        // A scene's parked name keeps its extension (.md or .fountain): renaming reads it.
        let parked = item.url.deletingLastPathComponent()
            .appendingPathComponent(".longhand-moving-\(UUID().uuidString)" + (item.kind == .scene ? "." + item.url.pathExtension : ""))
        var moves: [(from: URL, to: URL)] = []
        do {
            try FileManager.default.moveItem(at: item.url, to: parked)
            let movedB = try renameFile(other.url, kind: other.kind, order: item.order, title: other.title)
            moves.append((other.url, movedB))
            let movedA = try renameFile(parked, kind: item.kind, order: other.order, title: item.title)
            moves.append((item.url, movedA))
            follow(moves)
        } catch {
            if FileManager.default.fileExists(atPath: parked.path) {
                try? FileManager.default.moveItem(at: parked, to: FileNaming.unique(item.url))
            }
            follow(moves)
            errorMessage = "Couldn’t move it."
        }
    }

    /// Puts a chapter at `index` among its story's chapters (dragging it in the contents).
    /// One step at a time through `move`, which keeps titles, notes and places with it.
    func placeChapter(_ chapterURL: URL, at index: Int) {
        guard let book = library?.books.first(where: { $0.chapters.contains { $0.url == chapterURL } }),
              var position = book.chapters.firstIndex(where: { $0.url == chapterURL }) else { return }
        let target = max(0, min(index, book.chapters.count - 1))
        while position != target {
            guard let chapters = self.book(for: book.url)?.chapters, chapters.indices.contains(position) else { return }
            let chapter = chapters[position]
            let step = target > position ? 1 : -1
            move(ManuscriptItem(url: chapter.url, title: chapter.title, order: chapter.order, kind: .chapter), by: step)
            // Stop if the move didn't happen (an error was shown).
            guard self.book(for: book.url)?.chapters.indices.contains(position + step) == true,
                  self.book(for: book.url)?.chapters[position + step].title == chapter.title else { return }
            position += step
        }
    }

    /// Puts a scene at `index` among the scenes of `chapterURL` (counting without the scene
    /// itself), moving it between chapters if need be, and renumbers both chapters so the
    /// filename prefixes stay 01, 02, 03… Used by dragging cards.
    func placeScene(_ sceneURL: URL, inChapter chapterURL: URL, at index: Int) {
        // From a chapter, or (Restore) from the Boneyard, which has no numbers to keep.
        let source = library?.books.flatMap(\.chapters).first(where: { $0.scenes.contains { $0.url == sceneURL } })
        guard let target = chapter(for: chapterURL), let moving = scene(for: sceneURL) else { return }
        saveNow()

        var targetScenes = target.scenes.filter { $0.url != sceneURL }
        targetScenes.insert(moving, at: max(0, min(index, targetScenes.count)))
        var plans: [(scene: Scene, folder: URL, order: Int)] = targetScenes.enumerated().map {
            ($0.element, target.url, $0.offset + 1)
        }
        if let source, source.url != target.url {
            plans += source.scenes.filter { $0.url != sceneURL }.enumerated().map {
                ($0.element, source.url, $0.offset + 1)
            }
        }
        // Only scenes whose folder or number changes are touched.
        plans = plans.filter { plan in
            plan.folder != plan.scene.url.deletingLastPathComponent().canonical || plan.order != plan.scene.order
        }
        guard !plans.isEmpty else { return }

        // Two steps, so two scenes trading numbers (or names) never collide: first every
        // scene to a hidden name in its new folder, then to its final name.
        let fm = FileManager.default
        var parked: [(scene: Scene, temp: URL, folder: URL, order: Int)] = []
        var moves: [(from: URL, to: URL)] = []
        do {
            for plan in plans {
                let temp = plan.folder.appendingPathComponent(".longhand-moving-\(UUID().uuidString).\(plan.scene.url.pathExtension)")
                try fm.moveItem(at: plan.scene.url, to: temp)
                parked.append((plan.scene, temp, plan.folder, plan.order))
            }
            for item in parked {
                let name = FileNaming.name(order: item.order, title: item.scene.title) + "." + item.scene.url.pathExtension
                let destination = FileNaming.unique(item.folder.appendingPathComponent(name))
                try fm.moveItem(at: item.temp, to: destination)
                moves.append((item.scene.url, destination.canonical))
            }
            follow(moves)
        } catch {
            // Put anything still parked back under a visible name, so nothing is hidden.
            for item in parked where fm.fileExists(atPath: item.temp.path) {
                let name = FileNaming.name(order: item.order, title: item.scene.title) + "." + item.scene.url.pathExtension
                let destination = FileNaming.unique(item.folder.appendingPathComponent(name))
                if (try? fm.moveItem(at: item.temp, to: destination)) != nil {
                    moves.append((item.scene.url, destination.canonical))
                }
            }
            follow(moves)
            errorMessage = "Couldn’t move that scene."
        }
    }

    // MARK: - The Boneyard

    /// The contents column's two tabs inside a story (owner, 2026-11-14: "Boneyard should
    /// just be a tab in the left sidebar").
    enum ContentsTab { case contents, boneyard }
    @Published var contentsTab: ContentsTab = .contents

    /// Each story's folder of cut scenes and passages (owner, 2026-11-14; mock-up
    /// https://claude.ai/artifact/B1xNrBZmLp5y8DGpmCkwCD). Plain files, like its Notes.
    static let boneyardFolder = StoryFolders.boneyard

    /// A scene that can be cut: one in a chapter of a story with scenes.
    func canMoveToBoneyard(_ url: URL) -> Bool {
        guard let (book, chapter) = location(ofScene: url) else { return false }
        return !chapter.boneyard && book.shape.hasScenes
    }

    /// Moves a scene into its story's Boneyard: out of the manuscript, counts and export, its
    /// comments, notes and details with it, and where it was remembered for Restore. If it
    /// was open, the scene beside it opens instead.
    func moveToBoneyard(_ sceneURL: URL) {
        guard canMoveToBoneyard(sceneURL), let (book, chapter) = location(ofScene: sceneURL),
              let index = chapter.scenes.firstIndex(where: { $0.url == sceneURL }) else { return }
        saveNow()
        let scene = chapter.scenes[index]
        let number = self.number(ofScene: sceneURL)
        let neighbour = chapter.scenes[safe: index + 1] ?? (index > 0 ? chapter.scenes[index - 1] : nil)
        let wasOpen = selection == .scene(sceneURL)
        let folder = book.url.appendingPathComponent(Self.boneyardFolder, isDirectory: true)
        let destination: URL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            destination = FileNaming.unique(folder.appendingPathComponent(FileNaming.sanitized(scene.title) + "." + sceneURL.pathExtension)).canonical
            try FileManager.default.moveItem(at: sceneURL, to: destination)
        } catch {
            errorMessage = "Couldn’t move that scene to the Boneyard."
            return
        }
        follow([(sceneURL, destination)])
        var info = margin.info(for: destination)
        info.cut = SceneInfo.Cut(from: chapter.implicit ? book.title : chapter.title, number: number,
                                 chapter: chapter.implicit ? nil : chapter.url.lastPathComponent,
                                 index: index, date: Date(), before: nil)
        margin.setInfo(info, for: destination)
        if wasOpen { selection = neighbour.map { .scene($0.url) } ?? (chapter.implicit ? .book(book.url) : .chapter(chapter.url)) }
    }

    /// A passage cut from a single document (or screenplay) into its Boneyard, named by its
    /// first words. `before` is the text just before it, to find its place again. The caller
    /// takes it out of the page (so Undo puts it back).
    @discardableResult
    func addToBoneyard(_ text: String, from book: Book, before: String) -> URL? {
        guard let document = book.document else { return nil }
        saveNow()
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let name = FileNaming.sanitized(words.isEmpty ? "Passage" : String(words.prefix(60)))
        let folder = book.url.appendingPathComponent(Self.boneyardFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = FileNaming.unique(folder.appendingPathComponent(name + "." + document.url.pathExtension)).canonical
            try text.write(to: url, atomically: true, encoding: .utf8)
            var info = margin.info(for: url)
            info.cut = SceneInfo.Cut(from: book.title, number: nil, chapter: nil, index: nil, date: Date(), before: before)
            reload(select: .keep)
            margin.setInfo(info, for: url)
            return url
        } catch {
            errorMessage = "Couldn’t move that passage to the Boneyard."
            return nil
        }
    }

    /// Restore: a cut scene goes back where it was (its chapter, by folder or title, at its
    /// place), or into `chapterURL` at its end; a cut passage goes back into its document after
    /// the text it followed (else at the end) and leaves the Boneyard.
    func restore(_ sceneURL: URL, into chapterURL: URL? = nil) {
        guard let (book, chapter) = location(ofScene: sceneURL), chapter.boneyard else { return }
        saveNow()
        let cut = margin.info(for: sceneURL).cut

        if let document = book.document {
            let piece = fileText(at: sceneURL).trimmingCharacters(in: .newlines)
            var text = fileText(at: document.url)
            let string = text as NSString
            var at = string.length
            if let before = cut?.before, !before.isEmpty {
                let found = string.range(of: before, options: .backwards)
                if found.location != NSNotFound { at = NSMaxRange(found) }
            }
            // As its own paragraph: a blank line either side, never three line breaks.
            let head = (string.substring(to: at) as String).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let tail = (string.substring(from: at) as String).replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
            text = [head, piece, tail].filter { !$0.isEmpty }.joined(separator: "\n\n") + (tail.isEmpty ? "\n" : "")
            do {
                try text.write(to: document.url, atomically: true, encoding: .utf8)
                try FileManager.default.trashItem(at: sceneURL, resultingItemURL: nil)
            } catch {
                errorMessage = "Couldn’t restore that passage."
                return
            }
            margin.trash(sceneURL)
            if activeSceneURL == sceneURL { activeSceneURL = nil }
            reload(select: .none)
            selection = .scene(document.url)
            if activeSceneURL == document.url { setText(text) }
            return
        }

        let target: Chapter? = chapterURL.flatMap { self.chapter(for: $0) }
            ?? cut?.chapter.flatMap { name in book.chapters.first { $0.url.lastPathComponent == name } }
            ?? cut.flatMap { cut in book.chapters.first { !$0.implicit && $0.title == cut.from } }
            ?? book.chapters.first { $0.implicit }
            ?? book.chapters.last
        guard let target else {
            errorMessage = "This story has no chapter to restore the scene to."
            return
        }
        let index = chapterURL == nil ? min(cut?.index ?? target.scenes.count, target.scenes.count) : target.scenes.count
        placeScene(sceneURL, inChapter: target.url, at: index)
        // Back in its chapter: no longer a cut, and open.
        if let back = self.chapter(for: target.url)?.scenes[safe: index] {
            var info = margin.info(for: back.url)
            info.cut = nil
            margin.setInfo(info, for: back.url)
            selection = .scene(back.url)
        }
    }

    // MARK: - Changing a story's shape

    /// Join into One Document: every chapter and scene, in order, into one file in the story's
    /// folder. Chapter titles become `#` headings and `* * *` marks each break between scenes.
    /// Comments move with their passages; notes gather into the document's note. The old files
    /// go to the Trash (and stay in the story's history).
    func joinIntoOneDocument(_ bookURL: URL) {
        guard let book = book(for: bookURL), book.shape != .document else { return }
        saveNow()
        var text = ""
        var sources: [(scene: URL, offset: Int)] = []
        var notes: [(title: String, item: URL)] = []
        for chapter in book.chapters {
            if !chapter.implicit {
                if !text.isEmpty { text += "\n\n" }
                text += "# \(chapter.title)\n\n"
                notes.append((chapter.title, chapter.url))
            }
            for (index, scene) in chapter.scenes.enumerated() {
                if index > 0 { text += "\n\n* * *\n\n" }
                // Only the end is trimmed: comments count from the start of the scene's text.
                var body = read(scene.url)
                while let last = body.last, last.isWhitespace { body.removeLast() }
                sources.append((scene.url, (text as NSString).length))
                text += body
                notes.append((scene.title, scene.url))
            }
        }
        text += "\n"
        let documentURL = FileNaming.unique(book.url.appendingPathComponent(FileNaming.sanitized(book.title) + ".md")).canonical
        do {
            try text.write(to: documentURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn’t join the story."
            return
        }
        margin.mergeComments(sources, into: documentURL)
        margin.mergeNotes(notes, into: documentURL)
        // The old files, to the Trash: chapter folders whole, or a scenes-only story's files.
        let old = book.chapters.flatMap { $0.implicit ? $0.scenes.map(\.url) : [$0.url] }
        if let active = activeSceneURL, old.contains(where: { Self.relocated(active, from: $0, to: $0) != nil }) { activeSceneURL = nil }
        for url in old {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            margin.trash(url)
        }
        setShape(.document, of: book.url)
        reload(select: .none)
        openBook = book.url
        selection = .scene(documentURL)
    }

    /// Split into Chapters: a single document is cut at its headings (`#`, or `##` if it has
    /// no `#`), each becoming a chapter with one scene; text before the first heading becomes
    /// "Opening", and a document without headings becomes Chapter One. A scenes-only story's
    /// scenes go into Chapter One. Comments move with their passages.
    func splitIntoChapters(_ bookURL: URL) {
        guard let book = book(for: bookURL), book.shape == .document || book.shape == .scenes else { return }
        saveNow()
        do {
            if book.shape == .scenes {
                let chapterURL = try createChapterFolder(in: book.url, title: "\(names(of: book.url).chapter) One", order: 1)
                var moves: [(from: URL, to: URL)] = []
                for scene in book.looseScenes {
                    let destination = chapterURL.appendingPathComponent(scene.url.lastPathComponent)
                    try FileManager.default.moveItem(at: scene.url, to: destination)
                    moves.append((scene.url, destination.canonical))
                }
                setShape(.chaptersAndScenes, of: book.url)
                follow(moves)
                openBook = book.url
                return
            }
            guard let document = book.document else { return }
            let text = read(document.url) as NSString
            let parts = Self.chapterParts(of: text as String)
            var made: [(scene: URL, start: Int, length: Int)] = []
            for (index, part) in parts.enumerated() {
                let chapterURL = try createChapterFolder(in: book.url, title: part.title, order: index + 1)
                let sceneURL = try createSceneFile(in: chapterURL, title: part.title, order: 1)
                let body = text.substring(with: NSRange(location: part.start, length: part.length))
                try (body + "\n").write(to: sceneURL, atomically: true, encoding: .utf8)
                made.append((sceneURL, part.start, part.length))
            }
            margin.splitComments(of: document.url, into: made)
            if let first = made.first?.scene { margin.mergeNotes([(book.title, document.url)], into: first) }
            if activeSceneURL == document.url { activeSceneURL = nil }
            try? FileManager.default.trashItem(at: document.url, resultingItemURL: nil)
            margin.trash(document.url)
            setShape(.chaptersAndScenes, of: book.url)
            reload(select: .none)
            openBook = book.url
            if let first = made.first?.scene { selection = .scene(first) }
        } catch {
            errorMessage = "Couldn’t split the story."
            reload(select: .keep)
        }
    }

    /// Where a document's chapters start and end (UTF-16), and their titles. The heading lines
    /// themselves are left out: the chapter's folder carries the title.
    static func chapterParts(of text: String) -> [(title: String, start: Int, length: Int)] {
        let ns = text as NSString
        func headings(_ marks: String) -> [(title: String, line: NSRange)] {
            var found: [(String, NSRange)] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
                let content = ns.substring(with: line)
                guard content.hasPrefix(marks + " ") else { return }
                let title = content.dropFirst(marks.count + 1).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { found.append((title, enclosing)) }
            }
            return found
        }
        var marks = headings("#")
        if marks.isEmpty { marks = headings("##") }
        func trimmed(_ start: Int, _ end: Int) -> (Int, Int) {
            var a = start, b = end
            let space = CharacterSet.whitespacesAndNewlines
            while a < b, let scalar = UnicodeScalar(ns.character(at: a)), space.contains(scalar) { a += 1 }
            while b > a, let scalar = UnicodeScalar(ns.character(at: b - 1)), space.contains(scalar) { b -= 1 }
            return (a, b - a)
        }
        guard !marks.isEmpty else {
            let (start, length) = trimmed(0, ns.length)
            return [("Chapter One", start, length)]
        }
        var parts: [(title: String, start: Int, length: Int)] = []
        let (openingStart, openingLength) = trimmed(0, marks[0].line.location)
        if openingLength > 0 { parts.append(("Opening", openingStart, openingLength)) }
        for (index, mark) in marks.enumerated() {
            let end = index + 1 < marks.count ? marks[index + 1].line.location : ns.length
            let (start, length) = trimmed(NSMaxRange(mark.line), end)
            parts.append((mark.title, start, length))
        }
        return parts
    }

    /// Keeps a story's shape with its details (nothing is written for chapters and scenes).
    private func setShape(_ shape: BookShape, of bookURL: URL) {
        var info = margin.info(for: bookURL)
        info.shape = shape == .chaptersAndScenes ? nil : shape
        margin.setInfo(info, for: bookURL)
    }

    func delete(_ item: ManuscriptItem) {
        saveNow()

        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            margin.trash(item.url)
            if let active = activeSceneURL, Self.relocated(active, from: item.url, to: item.url) != nil {
                activeSceneURL = nil
            }
            if let selected = selection?.url, Self.relocated(selected, from: item.url, to: item.url) != nil {
                selection = nil
            }
            reload(select: .none)
        } catch {
            errorMessage = "Couldn’t move it to the Trash."
        }
    }

    @discardableResult
    private func renameFile(_ url: URL, kind: ItemKind, order: Int, title: String) throws -> URL {
        let base = FileNaming.name(order: order, title: title)
        let name = kind == .scene ? base + "." + url.pathExtension : base
        let proposed = url.deletingLastPathComponent().appendingPathComponent(name)

        if proposed.standardizedFileURL == url.standardizedFileURL { return url }

        // Only the capitals change ("arrival" → "Arrival"): on the Mac's disk that is the
        // same file, so "is the name taken?" says yes and the scene became "Arrival 2". Go
        // by way of a hidden name instead.
        if proposed.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame {
            let parked = url.deletingLastPathComponent().appendingPathComponent(".longhand-moving-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: parked)
            do {
                try FileManager.default.moveItem(at: parked, to: proposed)
            } catch {
                try? FileManager.default.moveItem(at: parked, to: url)
                throw error
            }
            CanonicalPaths.shared.forget()
            return proposed.canonical
        }

        let destination = FileNaming.unique(proposed)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination.canonical
    }

    /// After items move on disk, re-read the library and keep the open scene and the
    /// selection pointing at the same things in their new places.
    private func follow(_ moves: [(from: URL, to: URL)]) {
        func relocate(_ url: URL) -> URL {
            for move in moves {
                if let moved = Self.relocated(url, from: move.from, to: move.to) { return moved }
            }
            return url
        }

        if let active = activeSceneURL { activeSceneURL = relocate(active) }
        if let open = openBook { openBook = relocate(open) }
        margin.relocate(moves)
        places.relocate(moves)
        let previous = selection
        reload(select: .none)

        guard let previous else { return }
        let target = relocate(previous.url)
        guard target != previous.url else { return }
        switch previous {
        case .book: selection = .book(target)
        case .chapter: selection = .chapter(target)
        case .scene: selection = .scene(target)
        }
    }

    /// Where `url` ends up when `old` is moved to `new`: itself if it is `old`, the same place
    /// inside `new` if it lies inside `old`, or nil if the move does not affect it.
    static func relocated(_ url: URL, from old: URL, to new: URL) -> URL? {
        if url == old { return new }
        let prefix = old.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return URL(fileURLWithPath: new.path + "/" + url.path.dropFirst(prefix.count)).canonical
    }

    private func siblings(of item: ManuscriptItem) -> [ManuscriptItem] {
        guard let library else { return [] }
        switch item.kind {
        case .book:
            let folder = library.books.first { $0.url == item.url }?.folder
            return library.books(in: folder).map {
                ManuscriptItem(url: $0.url, title: $0.title, order: $0.order, kind: .book)
            }
        case .chapter:
            let chapters = library.books.first { $0.chapters.contains { $0.url == item.url } }?.chapters ?? []
            return chapters.map {
                ManuscriptItem(url: $0.url, title: $0.title, order: $0.order, kind: .chapter)
            }
        case .scene:
            let scenes = library.books
                .flatMap(\.chapters)
                .first { $0.scenes.contains { $0.url == item.url } }?
                .scenes ?? []
            return scenes.map {
                ManuscriptItem(url: $0.url, title: $0.title, order: $0.order, kind: .scene)
            }
        }
    }

    // MARK: - Context

    private var contextBook: Book? {
        guard let library else { return nil }
        switch selection {
        case .book(let url):
            return library.books.first { $0.url == url }
        case .chapter(let url):
            return library.books.first { $0.chapters.contains { $0.url == url } }
        case .scene(let url):
            return library.books.first { $0.chapters.contains { $0.scenes.contains { $0.url == url } } }
        case nil:
            // Nothing chosen: the story the contents is inside, if any.
            return library.books.first { $0.url == openBook }
        }
    }

    private var contextChapter: Chapter? {
        guard let library else { return nil }
        switch selection {
        case .chapter(let url):
            return library.books.flatMap(\.chapters).first { $0.url == url }
        case .scene(let url):
            return library.books.flatMap(\.chapters).first { $0.scenes.contains { $0.url == url } }
        case .book(let url):
            return library.books.first { $0.url == url }?.chapters.last
        case nil:
            return library.books.first { $0.url == openBook }?.chapters.last
        }
    }

    // MARK: - Lookups

    func fileText(at url: URL) -> String {
        read(url)
    }

    /// A scene anywhere: in a chapter, or in a story's Boneyard.
    func scene(for url: URL) -> Scene? {
        library?.books.flatMap { $0.chapters + ($0.boneyard.map { [$0] } ?? []) }.flatMap(\.scenes).first { $0.url == url }
    }

    func chapter(for url: URL) -> Chapter? {
        library?.books.flatMap(\.chapters).first { $0.url == url }
    }

    func book(for url: URL) -> Book? {
        library?.books.first { $0.url == url }
    }

    /// A chapter's position in its book, counting from 1.
    func number(ofChapter url: URL) -> Int? {
        guard let library else { return nil }
        for book in library.books {
            if let index = book.chapters.firstIndex(where: { $0.url == url }) { return index + 1 }
        }
        return nil
    }

    /// A scene's number, from where it sits now: "2.1" is the first scene of chapter 2.
    /// Worked out each time, never stored, so moving a scene renumbers it.
    /// Nil when the story's numbers are switched off (its page › Numbers).
    func number(ofScene url: URL) -> String? {
        guard let library else { return nil }
        for book in library.books {
            for (chapterIndex, chapter) in book.chapters.enumerated() {
                if let index = chapter.scenes.firstIndex(where: { $0.url == url }) {
                    guard margin.info(for: book.url).hideChapterNumbers != true, book.shape != .document else { return nil }
                    // Scenes only: 1, 2, 3. Chapters only: the chapter's number.
                    if chapter.implicit { return "\(index + 1)" }
                    if book.shape == .chapters { return "\(chapterIndex + 1)" }
                    return "\(chapterIndex + 1).\(index + 1)"
                }
            }
        }
        return nil
    }

    /// The chapter's number for numbering what is inside it ("2" for 2.1, 2.2), or nil when
    /// the story's numbers are switched off. Looked up once per chapter, not per scene.
    func shownNumber(ofChapter url: URL) -> Int? {
        guard let library else { return nil }
        for book in library.books {
            if let index = book.chapters.firstIndex(where: { $0.url == url }) {
                return margin.info(for: book.url).hideChapterNumbers == true || book.chapters[index].implicit ? nil : index + 1
            }
        }
        return nil
    }

    /// Where a scene is: its story and chapter (for a cut scene, the story's Boneyard, whose
    /// `boneyard` is true).
    func location(ofScene url: URL) -> (book: Book, chapter: Chapter)? {
        guard let library else { return nil }
        for book in library.books {
            for chapter in book.chapters + (book.boneyard.map { [$0] } ?? []) where chapter.scenes.contains(where: { $0.url == url }) {
                return (book, chapter)
            }
        }
        return nil
    }

    /// Whether a scene is in a story's Boneyard.
    func isCut(_ url: URL) -> Bool { location(ofScene: url)?.chapter.boneyard == true }

    // MARK: - Counts

    func wordCount(of scene: Scene) -> Int { wordCounts[scene.url] ?? 0 }

    func wordCount(of chapter: Chapter) -> Int {
        chapter.scenes.reduce(0) { $0 + wordCount(of: $1) }
    }

    func wordCount(of book: Book) -> Int {
        book.chapters.reduce(0) { $0 + wordCount(of: $1) }
    }

    var totalWordCount: Int {
        (library?.books ?? []).reduce(0) { $0 + wordCount(of: $1) }
    }

    static func wordCount(_ text: String) -> Int {
        LiveCount.words(in: text as NSString)
    }

    // MARK: - Export

    /// Set by File › Export… to open the export sheet.
    @Published var exportRequested = false
    /// ⌘P and ⇧⌘F.
    @Published var quickOpenShown = false {
        didSet {
            guard oldValue, !quickOpenShown else { return }
            palette.finish()
            // A previewed theme drew the window again, so the page the palette took the
            // keyboard from is gone: give it to the new page if nothing has it. The new window
            // contents can take a moment on a busy Mac (the keyboard once went to the old page
            // as it was taken away), so look again for up to a second and a half.
            refocusPage(tries: 25)
        }
    }
    private func refocusPage(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            guard let self else { return }
            let window = NSApp.mainWindow ?? NSApp.windows.first { $0.frame.width > 400 }
            guard let window else { return }
            // Act only when nothing on screen has the keyboard: nothing, the window, a page
            // taken away, or the closing palette's own field (it can hold the keyboard for a
            // moment, then leaves with nothing holding it). Something else on screen (the
            // page, a field, the contents column) keeps it.
            let held = window.firstResponder
            let palette = (held as? NSTextView)?.isFieldEditor == true && (held as? NSTextView)?.delegate is KeyField.Field
            let onScreen = (held as? NSView).map { $0 !== window.contentView && $0.window === window && !$0.isHiddenOrHasHiddenAncestor } ?? false
            if palette || !onScreen, let page = window.contentView.flatMap(Self.editablePage) {
                window.makeFirstResponder(page)
            }
            // Keep looking for the whole time, even after handing it over: the page given it
            // may be the old one, about to be taken away by the redraw (that left the
            // keyboard with nothing, now and then, on a busy Mac).
            if tries > 1 { self.refocusPage(tries: tries - 1) }
        }
    }
    /// The first page that takes typing in a view tree.
    private static func editablePage(in view: NSView) -> NSTextView? {
        if let page = view as? HighlightTextView, page.isEditable, !page.isHiddenOrHasHiddenAncestor { return page }
        for child in view.subviews { if let page = editablePage(in: child) { return page } }
        return nil
    }

    /// What the palette holds (its group, query, choice), kept here so a theme previewed from
    /// it, which draws the window again, doesn't close or empty it.
    let palette = PaletteState()
    /// Help › Cheat Sheet (⌘/), a card over the page.
    @Published var cheatSheetShown = false
    /// The short introduction to Git (commit, push, branch, merge): shown once, the first time
    /// a library is open; Help › Git in Four Steps shows it again.
    @Published var gitIntroShown = false
    /// View › Clear Desk (⌘.): only the page. The contents, margin, toolbar, status bar and
    /// the page's header fade where they stand (so the text never moves); the same keys or Escape bring them back. Not kept
    /// between launches, so Longhand never opens looking empty.
    @Published var deskCleared = false {
        didSet { PageMarks.deskCleared = deskCleared }
    }
    /// The book the contents column is inside; nil for the Library (every book). A book
    /// selected in the Library shows its Book Info page; inside it, the whole book as cards.
    @Published var openBook: URL?
    /// ⌘L, the scene switcher (`SceneSwitcher`).
    @Published var switcherShown = false
    /// Scenes opened, most recent first (the scene switcher's order).
    private(set) var recentScenes: [URL] = []
    /// ⇧⌘L, the document switcher (`SceneSwitcher(documents: true)`): every story.
    @Published var documentSwitcherShown = false

    /// Back to the Library (‹ Library, ⌘4, the path's first place): the story you were in is
    /// chosen there, its page shown, rather than its text staying open beside the list
    /// (owner, 2026-11-14).
    func showLibrary() {
        let story = openBook ?? contextBook?.url
        saveNow()
        openBook = nil
        if let story, library?.books.contains(where: { $0.url == story }) == true, selection != .book(story) {
            selection = .book(story)
        }
    }

    /// Goes into a story where you last were: the scene last open in it, else its single
    /// document or first scene, else its page.
    func openDocument(_ url: URL) {
        guard let book = library?.books.first(where: { $0.url == url }) else { return }
        let scenes = book.chapters.flatMap(\.scenes)
        if let recent = recentScenes.first(where: { scene in scenes.contains { $0.url == scene } }) {
            selection = .scene(recent)
        } else if let first = book.document ?? scenes.first {
            selection = .scene(first.url)
        } else {
            selection = .book(book.url)
        }
        openBook = book.url
    }

    // MARK: Moving between scenes and chapters (Go menu)

    /// The scene before or after the open one, across chapters, in the same book.
    func stepScene(by step: Int) {
        guard let library else { return }
        let url: URL
        switch selection {
        case .scene(let scene): url = scene
        case .chapter(let chapter):
            // From a chapter: its first scene (going on) or the last scene before it (going back).
            guard let book = library.books.first(where: { $0.chapters.contains { $0.url == chapter } }),
                  let index = book.chapters.firstIndex(where: { $0.url == chapter }) else { return }
            if step > 0, let first = book.chapters[index].scenes.first { selection = .scene(first.url); return }
            if step < 0, let last = book.chapters[..<index].last(where: { !$0.scenes.isEmpty })?.scenes.last { selection = .scene(last.url) }
            return
        case .book(let book):
            if step > 0, let first = library.books.first(where: { $0.url == book })?.chapters.first(where: { !$0.scenes.isEmpty })?.scenes.first {
                selection = .scene(first.url)
            }
            return
        case nil: return
        }
        guard let book = location(ofScene: url)?.book else { return }
        let order = book.chapters.flatMap(\.scenes)
        guard let index = order.firstIndex(where: { $0.url == url }) else { return }
        let next = index + step
        if order.indices.contains(next) { selection = .scene(order[next].url) } else { NSSound.beep() }
    }

    /// The chapter before or after: from a scene, the first scene of that chapter; from a
    /// chapter's page, that chapter's page.
    func stepChapter(by step: Int) {
        guard let library else { return }
        let chapterURL: URL
        var onScene = false
        switch selection {
        case .scene(let scene):
            guard let chapter = location(ofScene: scene)?.chapter.url else { return }
            chapterURL = chapter
            onScene = true
        case .chapter(let chapter): chapterURL = chapter
        case .book(let book):
            if step > 0, let first = library.books.first(where: { $0.url == book })?.chapters.first { selection = .chapter(first.url) }
            return
        case nil: return
        }
        guard let book = library.books.first(where: { $0.chapters.contains { $0.url == chapterURL } }),
              let index = book.chapters.firstIndex(where: { $0.url == chapterURL }) else { return }
        let next = index + step
        guard book.chapters.indices.contains(next) else { NSSound.beep(); return }
        let chapter = book.chapters[next]
        if onScene, let first = chapter.scenes.first {
            selection = .scene(first.url)
        } else {
            selection = .chapter(chapter.url)
        }
    }
    @Published var searchShown = false

    private var exportSettingsURL: URL? {
        libraryURL?.appendingPathComponent(".longhand/export.json")
    }

    /// The export sheet's choices for this library (name, contact, format…).
    func loadExportSettings() -> ExportSettings {
        guard let url = exportSettingsURL, let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return ExportSettings() }
        return settings
    }

    /// Older libraries kept the author in the export choices. Moves them to the Book Info of
    /// every book that has no author yet, then saves the choices without them. Runs whenever
    /// Book Info or Export opens; does nothing once they've moved.
    func adoptExportAuthor() {
        let old = loadExportSettings()
        let name = old.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pen = old.penName.trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = old.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(name.isEmpty && pen.isEmpty && contact.isEmpty), let books = library?.books else { return }
        for book in books {
            var info = margin.info(for: book.url)
            guard info.hasNoAuthor else { continue }
            info.authorName = name.isEmpty ? nil : name
            info.authorPenName = pen.isEmpty ? nil : pen
            info.authorAddress = contact.isEmpty ? nil : contact
            margin.setInfo(info, for: book.url)
        }
        saveExportSettings(old)
    }

    func saveExportSettings(_ settings: ExportSettings) {
        guard let url = exportSettingsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: - Finder

    func revealLibrary() {
        if let libraryURL {
            NSWorkspace.shared.activateFileViewerSelecting([libraryURL])
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Housekeeping

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    private func ensureMetadata(at root: URL) {
        let fm = FileManager.default
        let meta = root.appendingPathComponent(".longhand", isDirectory: true)
        if !fm.fileExists(atPath: meta.path) {
            try? fm.createDirectory(at: meta, withIntermediateDirectories: true)
        }
        let file = meta.appendingPathComponent("library.json")
        if !fm.fileExists(atPath: file.path) {
            let payload: [String: Any] = [
                "version": 1,
                "name": root.lastPathComponent,
                "created": ISO8601DateFormatter().string(from: Date())
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Must save before returning: once this notification is handled the app exits,
            // so a deferred save would never run.
            MainActor.assumeIsolated {
                self?.saveNow()
                self?.places.save()
                self?.endSession()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveNow()
                self?.places.save()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFromDisk()
                self?.versions.syncIfStale()
            }
        })
    }
}

/// The open scene's counts, for the line under the page. Its own object, so a keystroke only
/// redraws that line.
@MainActor
final class LiveCount: ObservableObject {
    @Published private(set) var words = 0
    @Published private(set) var characters = 0
    /// Lines of verse (`verseLines`), what a poem's status bar counts.
    @Published private(set) var lines = 0
    /// Whether `lines` is kept (the open scene is a poem or song).
    var countsLines = false
    /// In a screenplay: the element the caret is in ("Dialogue"); nil elsewhere.
    @Published private(set) var element: String?

    func setElement(_ name: String?) {
        if name != element { element = name }
    }

    func update(_ text: String) {
        let string = text as NSString
        let newWords = Self.words(in: string)
        if newWords != words { words = newWords }
        if string.length != characters { characters = string.length }
        let newLines = countsLines ? Self.verseLines(in: text) : 0
        if newLines != lines { lines = newLines }
    }

    /// A poem's lines: those with words on them, leaving out headings ("# Title"), a song's
    /// labels ("[Chorus]") and footnotes.
    nonisolated static func verseLines(in text: String) -> Int {
        var count = 0
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[^"),
                  ManuscriptBuilder.verseLabel(trimmed) == nil else { return }
            count += 1
        }
        return count
    }

    /// Counts runs of non-space characters that hold at least one letter or digit, reading the
    /// text in UTF-16 chunks (fast on a whole chapter). A lone Markdown symbol or dash
    /// ("#", ">", "—", "***") is not a word (owner, 2026-11-11); "**very" is one.
    nonisolated static func words(in string: NSString) -> Int {
        let length = string.length
        guard length > 0 else { return 0 }
        var count = 0
        var inWord = false   // in a run that has already been counted
        var buffer = [unichar](repeating: 0, count: 4096)
        var location = 0
        while location < length {
            let chunk = min(4096, length - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                string.getCharacters(pointer.baseAddress!, range: NSRange(location: location, length: chunk))
                for index in 0..<chunk {
                    let unit = pointer[index]
                    let space = unit == 0x20 || (unit >= 0x09 && unit <= 0x0D) || unit == 0xA0 || unit == 0x1680
                        || (unit >= 0x2000 && unit <= 0x200A) || unit == 0x2028 || unit == 0x2029
                        || unit == 0x202F || unit == 0x205F || unit == 0x3000 || unit == 0x85
                    if space {
                        inWord = false
                    } else if !inWord {
                        // A letter or digit: ASCII ones, or anything from À on that isn't
                        // punctuation (× ÷, the dashes and quotes at U+2000, CJK marks).
                        let wordy = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A)
                            || (unit >= 0x61 && unit <= 0x7A)
                            || (unit >= 0xC0 && unit != 0xD7 && unit != 0xF7
                                && !(unit >= 0x2000 && unit <= 0x206F) && !(unit >= 0x3000 && unit <= 0x303F))
                        if wordy {
                            inWord = true
                            count += 1
                        }
                    }
                }
            }
            location += chunk
        }
        return count
    }
}
