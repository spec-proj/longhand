import AppKit
import SwiftUI

/// When the last drag began (an `onDrag` closure ran), for the live script's `path` step to say
/// how long picking an item up took. Costs one timestamp.
@MainActor
enum DragProbe {
    static var began = 0.0
    /// When a drop's handler ran (`dropped`), for the live script to say how long after the button
    /// went up.
    static var dropped = 0.0
    static func mark() { began = ProcessInfo.processInfo.systemUptime }
    static func markDrop() { dropped = ProcessInfo.processInfo.systemUptime }
}

/// Dev aids for checking the interface without screen-recording permission.
///
///     Longhand --snapshot /tmp/shot.png          render the window, then quit
///     Longhand --selftest /tmp/report.txt        exercise the folder model, then quit
///
/// Switches are environment variables, because AppKit parses `-flag value` pairs out of the
/// command line itself: two flags in a row makes it treat the leftover path as a file to open,
/// and the window never appears.
///
///     LONGHAND_CHAPTER=1   select the first chapter on launch
///     LONGHAND_LIGHT=1     force light appearance
///     LONGHAND_DARK=1      force dark appearance
///     LONGHAND_LIBRARY=…   open this folder as the library, without remembering it
///     LONGHAND_DUMP=1      also write the view hierarchy to `<path>.txt`
///     LONGHAND_NOTES=1     open the margin on Notes (otherwise Comments)
///     LONGHAND_FOCUS=1     put the first comment in focus
///     LONGHAND_CARDS=1     show chapters and books as cards
///     LONGHAND_CARDSIZE=small|medium|large    the cards' size
///     LONGHAND_CARDPICK=1 / LONGHAND_CARDEDIT=1   choose the first card / edit it on the board
///     LONGHAND_EXPORT=1    open the export sheet and picture it
///     LONGHAND_TAB=changes open the margin on a tab (comments, notes, changes)
///     LONGHAND_PREVIEW=1   show the scene's newest earlier version
///     LONGHAND_FACE=newYork  set the prose in New York
///     LONGHAND_FOCUSMODE=sentence|paragraph   focus on
///     LONGHAND_TYPEWRITER=1                   typewriter scrolling on
///     LONGHAND_CHANGES=1|focus                edit the demo so there are changes to show
///     LONGHAND_THEME=dracula                  a theme (paper, catppuccin, dracula, nord, …)
///     LONGHAND_CHEATSHEET=1 / LONGHAND_SETTINGS=1   the cheat sheet / the Settings window
///     LONGHAND_CLEARDESK=1                    Clear Desk: only the page
///     LONGHAND_STORYPAGE=1                    a story's Page (with LONGHAND_BOOK=1)
///     LONGHAND_BOOKEDIT=1                     a story's page in Edit (with LONGHAND_LIBRARYVIEW=1)
///     LONGHAND_SCREENPLAY=1|read              the first screenplay, to write or as pages
enum Snapshot {
    static var wantsChapter: Bool {
        ProcessInfo.processInfo.environment["LONGHAND_CHAPTER"] == "1"
    }

    /// The first card on the board, chosen (`pick`) or edited on the card (`edit`), once.
    @MainActor static var cardPicture: String? = {
        let environment = ProcessInfo.processInfo.environment
        return environment["LONGHAND_CARDEDIT"] == "1" ? "edit" : environment["LONGHAND_CARDPICK"] == "1" ? "pick" : nil
    }()

    /// `LONGHAND_BOOK=n` selects the library's nth story (1, the first).
    static var bookNumber: Int? {
        ProcessInfo.processInfo.environment["LONGHAND_BOOK"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    /// `LONGHAND_SCREENPLAY=1` opens the library's first screenplay to write; `=read`, its pages.
    static var wantsScreenplay: Bool {
        ProcessInfo.processInfo.environment["LONGHAND_SCREENPLAY"] != nil
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// True for `--snapshot` and `--selftest`: the run happens out of sight, without taking
    /// focus, so it never disturbs someone using the Mac.
    static var isBackgroundRun: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--snapshot") || args.contains("--selftest") || args.contains("--perftest") || args.contains("--export-sample") || args.contains("--paritytest")
    }

    /// Called before any window exists. A background run never becomes the active app, and its
    /// settings live only in memory (the argument domain), so the copy of Longhand someone has
    /// open keeps its own layout.
    static func prepareBackgroundRun() {
        guard isBackgroundRun else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        // The view each document is shown in (the switch in the toolbar): the cards, a
        // chapter to write, a story's page.
        if environment["LONGHAND_CARDS"] == "1" {
            ViewModes.forcedChapter = .cards
            ViewModes.forcedStory = .cards
        } else {
            if environment["LONGHAND_STORYPAGE"] == "1" { ViewModes.forcedStory = .page }
            if environment["LONGHAND_SCREENPLAY"] == "read" {
                ViewModes.forcedChapter = .read
            } else if ProcessInfo.processInfo.arguments.contains("--selftest")
                        || ProcessInfo.processInfo.arguments.contains("--perftest")
                        || environment["LONGHAND_WRITE"] == "1" {
                // Tests type on the chapter page; pictures show it for writing unless
                // LONGHAND_WRITE=1.
                ViewModes.forcedChapter = .write
            }
        }
        UserDefaults.standard.setVolatileDomain([
            "marginTab": environment["LONGHAND_TAB"] ?? (environment["LONGHAND_NOTES"] == "1" ? "notes" : "comments"),
            "showMargin": true,
            "showSidebar": true,
            ProseFace.defaultsKey: environment["LONGHAND_FACE"] ?? ProseFace.sfPro.rawValue,
            ProseSize.defaultsKey: Int(environment["LONGHAND_PROSESIZE"] ?? "") ?? 0,
            AppTheme.defaultsKey: environment["LONGHAND_THEME"] ?? AppTheme.paper.rawValue,
            AppTheme.modeKey: "system",
            CardSize.key: environment["LONGHAND_CARDSIZE"] ?? CardSize.medium.rawValue,
            WritingModes.focusKey: environment["LONGHAND_FOCUSMODE"] != nil,
            WritingModes.unitKey: environment["LONGHAND_FOCUSMODE"] ?? WritingModes.Unit.sentence.rawValue,
            WritingModes.typewriterKey: environment["LONGHAND_TYPEWRITER"] == "1"
        ], forName: UserDefaults.argumentDomain)
    }

    /// Keeps a background run's window invisible and off every screen.
    static func hide(_ window: NSWindow) {
        guard isBackgroundRun else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrame(NSRect(x: -30000, y: -30000, width: 1320, height: 840), display: false)
    }

    /// Sets up the margin for a screenshot.
    @MainActor
    static func preparePreview(_ store: LibraryStore) {
        guard environment["LONGHAND_PREVIEW"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if case .scene(let url) = store.selection {
                store.historyPreview = store.history.versions(of: url).first
            }
        }
    }

    /// LONGHAND_SEARCH=word opens Find in Library with that query; LONGHAND_QUICK=text opens
    /// Open Quickly with that text.
    static var searchQuery: String? { environment["LONGHAND_SEARCH"] }
    static var quickQuery: String? { environment["LONGHAND_QUICK"] }

    @MainActor
    static func prepareFind(_ store: LibraryStore) {
        if searchQuery != nil { store.searchShown = true }
        if quickQuery != nil { store.quickOpenShown = true }
    }

    @MainActor
    static func prepareExport(_ store: LibraryStore) {
        guard environment["LONGHAND_EXPORT"] == "1",
              let book = (wantsScreenplay ? store.library?.books.first(where: \.isScreenplay) : nil) ?? Exporter.book(in: store) else { return }
        // A hidden run can't present a sheet, so the sheet's view gets a window of its own.
        let sheet = book.isScreenplay
            ? AnyView(ScreenplayExportSheet(book: book).environmentObject(store))
            : AnyView(ExportSheet(book: book).environmentObject(store).environmentObject(store.margin))
        let view = NSHostingView(rootView: sheet)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 560, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.alphaValue = 0
        window.setContentSize(view.fittingSize)
        window.orderFront(nil)
        exportWindow = window
    }

    @MainActor static var exportWindow: NSWindow?

    /// `LONGHAND_REWRITE=1`: on a rewrite (the strip at the foot of the contents).
    /// `LONGHAND_REWRITE=merge`: keeping a rewrite with a paragraph changed on both sides.
    @MainActor
    static func prepareRewrite(_ store: LibraryStore) {
        guard let mode = environment["LONGHAND_REWRITE"] else { return }
        func whenReady(_ go: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if store.versions.available { go() } else { whenReady(go) }
            }
        }
        whenReady {
            guard let scene = store.library?.books.first?.chapters.first?.scenes.first,
                  let text = try? String(contentsOf: scene.url, encoding: .utf8) else { return }
            let paragraphs = text.components(separatedBy: "\n\n")
            func edit(_ change: (String) -> String) {
                var parts = paragraphs
                if parts.count > 1 { parts[1] = change(parts[1]) }
                try? parts.joined(separator: "\n\n").write(to: scene.url, atomically: true, encoding: .utf8)
            }
            store.startRewrite(title: "First person")
            edit { $0.replacingOccurrences(of: "She walked", with: "I walked").replacingOccurrences(of: "her feet", with: "my feet") }
            guard mode == "merge" else { store.switchTo(store.versions.currentRewrite); return }
            store.switchTo(nil)
            edit { $0.replacingOccurrences(of: "weak tea", with: "cold tea") + " Nobody came." }
            store.switchTo(store.versions.rewrites.first)
            store.keepRewrite()
        }
    }

    /// `LONGHAND_COMPARE=1` (or `=scene`): edits the first scene of the (temporary) demo library on disk, then
    /// opens Compare Versions on it. `LONGHAND_COMPARE_ASIS=1` leaves the text alone, for a library
    /// that already has changes since its last commit (the website's pictures).
    @MainActor
    static func prepareCompare(_ store: LibraryStore) {
        guard let mode = environment["LONGHAND_COMPARE"] else { return }
        func whenReady(_ go: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if store.versions.available { go() } else { whenReady(go) }
            }
        }
        whenReady {
            if environment["LONGHAND_COMPARE_ASIS"] == nil,
               let scene = store.library?.books.first?.chapters.first?.scenes.first,
               var text = try? String(contentsOf: scene.url, encoding: .utf8) {
                let words = text.split(separator: " ")
                if words.count > 12 {
                    text = text.replacingOccurrences(of: " \(words[8]) ", with: " quietly ", options: [], range: text.range(of: " \(words[8]) "))
                    text = text.replacingOccurrences(of: " \(words[3]) ", with: " ", options: [], range: text.range(of: " \(words[3]) "))
                }
                text += "\n\nA last line, added for the comparison.\n"
                try? text.write(to: scene.url, atomically: true, encoding: .utf8)
            }
            store.compareVersions()
            // LONGHAND_COMPARE=scene: the first changed scene, whole.
            if mode == "scene" {
                func open() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let first = store.versions.comparison?.scenes.first { store.versions.detail = first } else { open() }
                    }
                }
                open()
            }
        }
    }

    /// `LONGHAND_CHANGES=1` (or `=focus`): edits the open scene through the page (a word
    /// changed, a paragraph added, the quote cut) and a second scene on disk, so the status
    /// bar, contents, Changes tab and page bars have something to show. `focus` also chooses
    /// the first bar, as a click would.
    @MainActor
    static func prepareChanges(_ store: LibraryStore) {
        guard let mode = environment["LONGHAND_CHANGES"] else { return }
        func whenReady(_ go: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if store.versions.available, store.versions.changes.loaded, store.margin.textView != nil { go() } else { whenReady(go) }
            }
        }
        whenReady {
            guard let page = store.margin.textView else { return }
            @MainActor func replace(_ find: String, with text: String) {
                let range = (page.string as NSString).range(of: find)
                guard range.location != NSNotFound, page.shouldChangeText(in: range, replacementString: text) else { return }
                page.textStorage?.replaceCharacters(in: range, with: text)
                page.didChangeText()
            }
            replace("the colour of weak tea", with: "the colour of tea left too long")
            replace("> Come when the water is out, he had said. Not before.\n\n", with: "")
            replace("— a piano.", with: "— a piano.\n\nShe did not call out. Whoever was playing knew she had come.")
            if let second = store.library?.books.first?.chapters.first?.scenes.dropFirst().first,
               let text = try? String(contentsOf: second.url, encoding: .utf8) {
                try? (text + "\nThe clock started again.\n").write(to: second.url, atomically: true, encoding: .utf8)
            }
            store.saveNow()
            if mode == "diff" {
                func open() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let change = store.versions.changes.scenes.first, let url = store.versions.changes.url(of: change) {
                            store.versions.showSceneChanges(url)
                        } else { open() }
                    }
                }
                open()
            }
            if mode == "focus" {
                func choose() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let bar = (page as? HighlightTextView)?.changeBars.first(where: { $0.kind == .changed }) {
                            store.margin.showChange(bar)
                        } else { choose() }
                    }
                }
                choose()
            }
        }
    }

    /// `LONGHAND_CHEATSHEET=1` opens the Markdown cheat sheet; `LONGHAND_SETTINGS=1` pictures the
    /// Settings window (in its own hidden window, as the sheets are).
    @MainActor
    static func prepareExtras(_ store: LibraryStore) {
        if environment["LONGHAND_CHEATSHEET"] == "1" { store.cheatSheetShown = true }
        // LONGHAND_BONEYARD=1: the first story's first cut scene, open.
        if environment["LONGHAND_BONEYARD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let scene = store.library?.books.compactMap(\.boneyard).first?.scenes.first { store.selection = .scene(scene.url) }
            }
        }
        // LONGHAND_UPDATE=0.9.9: the status bar as if a newer Longhand were out.
        if let version = environment["LONGHAND_UPDATE"] { Updates.shared.pretend(version) }
        if environment["LONGHAND_CLEARDESK"] == "1" { store.deskCleared = true }
        // LONGHAND_LIBRARYVIEW=1: the Library, with the first book (or LONGHAND_BOOK=n) chosen (its Book Info page).
        if environment["LONGHAND_LIBRARYVIEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let book = store.library?.books.dropFirst((bookNumber ?? 1) - 1).first { store.selection = .book(book.url) }
                store.openBook = nil
            }
        }
        // LONGHAND_SWITCHER=documents: the ⇧⌘L document switcher, from inside the first story.
        if environment["LONGHAND_SWITCHER"] == "documents" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let scene = store.library?.books.first?.chapters.flatMap(\.scenes).first { store.selection = .scene(scene.url) }
                store.documentSwitcherShown = true
            }
        }
        // LONGHAND_SWITCHER=1: the ⌘L scene switcher, after a few scenes were visited.
        if environment["LONGHAND_SWITCHER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let scenes = store.library?.books.first?.chapters.flatMap(\.scenes) ?? []
                for scene in scenes.prefix(4).reversed() { store.selection = .scene(scene.url) }
                store.switcherShown = true
            }
        }
        // LONGHAND_LOOKS=1: stages and Book Info details on the demo’s books.
        if environment["LONGHAND_LOOKS"] == "1", let books = store.library?.books {
            let stages: [BookStage] = [.writing, .sketch, .final]
            for (book, stage) in zip(books, stages) {
                var info = store.margin.info(for: book.url)
                info.stage = stage
                if book.url == books.first?.url {
                    info.form = .novel
                    info.genre = "Literary"
                    info.synopsis = "A woman walks out to a house on a tidal island that her brother said would be empty. It isn't."
                    info.authorName = "A. N. Author"
                    info.previousWorks = "The Long Field (2019)"
                } else if book.url == books.dropFirst().first?.url {
                    info.form = .poetry
                }
                store.margin.setInfo(info, for: book.url)
            }
            // LONGHAND_COVER=/path/to/image: a cover for the first book.
            if let path = environment["LONGHAND_COVER"], let first = books.first {
                store.margin.setCover(of: first.url, from: URL(fileURLWithPath: path))
            }
        }
        guard environment["LONGHAND_SETTINGS"] == "1" else { return }
        // LONGHAND_SETTINGS_PANE=authors: two made-up authors (hidden runs start with none).
        if environment["LONGHAND_SETTINGS_PANE"] == "authors" {
            AuthorProfiles.shared.add(AuthorProfile(name: "A. N. Author", penName: "Ann Other",
                                                    address: "12 Tide Lane\nSaltmarsh", email: "ann@example.com", phone: "01234 567890"))
            AuthorProfiles.shared.add(AuthorProfile(name: "Second Writer"))
            // LONGHAND_AUTHORS=n: that many more (the pane's pop-up from four on).
            for index in 0..<(Int(environment["LONGHAND_AUTHORS"] ?? "") ?? 0) {
                AuthorProfiles.shared.add(AuthorProfile(name: "Writer \(index + 3)"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let view = NSHostingView(rootView: AnyView(SettingsView(versions: store.versions)))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 560, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.alphaValue = 0
            window.setContentSize(view.fittingSize)
            window.orderFront(nil)
            exportWindow = window
        }
    }

    /// `LONGHAND_LIVE=/dir`: a visible run (only when the owner says the Mac is free), for what
    /// hidden runs can't show (the caret, what the screen really has after a caret move). With
    /// `LONGHAND_LIBRARY` on a copy. Settings stay in memory. Turns Focus on (unit from
    /// `LONGHAND_LIVE_UNIT`, typewriter with `LONGHAND_LIVE_TYPEWRITER=1`), moves the caret as
    /// the keys would, and photographs the window after each step with `screencapture`, then
    /// quits.
    @MainActor
    static func runLive(_ store: LibraryStore) {
        guard let dir = environment["LONGHAND_LIVE"] else { return }
        if environment["LONGHAND_LIVE_KEYS"] == "1" { return runLiveKeys(store, dir: dir) }
        if let script = environment["LONGHAND_LIVE_SCRIPT"] { return runLiveScript(store, dir: dir, script: script) }
        let defaults = UserDefaults.standard
        func setting(_ values: [String: Any]) {
            defaults.setVolatileDomain(defaults.volatileDomain(forName: UserDefaults.argumentDomain).merging(values) { $1 },
                                       forName: UserDefaults.argumentDomain)
            // As a real change of setting announces itself (View › Focus does).
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        setting([WritingModes.focusKey: false, WritingModes.unitKey: environment["LONGHAND_LIVE_UNIT"] ?? "line",
                 WritingModes.typewriterKey: environment["LONGHAND_LIVE_TYPEWRITER"] == "1"])
        var step = 0
        func shoot(_ name: String) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else { return }
            step += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(dir)/\(step)-\(name).png"]
            try? process.run()
            process.waitUntilExit()
        }
        let steps: [(Double, @MainActor () -> Void)] = [
            (1.2, {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.frame.width > 400 }?.makeKeyAndOrderFront(nil)
                if let scene = store.library?.books.first?.chapters.first?.scenes.first { store.selection = .scene(scene.url) }
            }),
            (1.0, {
                guard let page = store.margin.textView else { return }
                page.window?.makeFirstResponder(page)
                page.setSelectedRange(NSRange(location: 120, length: 0))
                setting([WritingModes.focusKey: true])
            }),
            (1.0, { shoot("focus-on") }),
            (0.1, { store.margin.textView?.moveDown(nil) }),
            (0.3, { store.margin.textView?.moveDown(nil) }),
            (0.3, { store.margin.textView?.moveDown(nil) }),
            (0.8, { shoot("three-lines-down") }),
            (0.1, {
                guard let page = store.margin.textView else { return }
                let string = page.string as NSString
                let second = string.range(of: "\n\n").location
                if second != NSNotFound { page.setSelectedRange(NSRange(location: second + 40, length: 0)) }
            }),
            (0.8, { shoot("next-paragraph") }),
            (0.1, {
                guard let page = store.margin.textView else { return }
                let string = page.string as NSString
                let blank = string.range(of: "\n\n").location
                if blank != NSNotFound { page.setSelectedRange(NSRange(location: blank + 1, length: 0)) }
            }),
            (0.8, {
                shoot("blank-line")
                guard let page = store.margin.textView else { return }
                var found: [String] = []
                @MainActor func walk(_ view: NSView, _ depth: Int) {
                    let name = String(describing: type(of: view))
                    if name.lowercased().contains("insertion") || name.lowercased().contains("caret") || name.lowercased().contains("cursor") {
                        found.append("\(name) frame=\(view.frame) hidden=\(view.isHidden)")
                    }
                    view.subviews.forEach { walk($0, depth + 1) }
                }
                walk(page.window?.contentView ?? page, 0)
                let note = "caretDraws=\(HighlightTextView.caretDraws) views=\(found)\n"
                try? note.write(toFile: "\(dir)/caret.txt", atomically: true, encoding: .utf8)
            }),
            (0.1, { setting([WritingModes.focusKey: false]) }),
            (0.8, { shoot("focus-off") }),
            (0.3, { NSApp.terminate(nil) }),
        ]
        var delay = 0.0
        for (wait, action) in steps {
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
        }
    }

    /// `LONGHAND_LIVE_SCRIPT=file`: a visible run driven by real mouse and key events posted to
    /// this app, one step per line:
    /// `scene N` · `chapter N` · `click X Y` / `double X Y` (window points from its top left;
    /// `wclick X Y` sends the click straight to the window, for a locked screen) ·
    /// `type TEXT` · `key CODE [cmd opt ctrl shift]` · `wait S` · `scroll X Y DY` · `shot NAME` · `state LABEL` ·
    /// `path X Y X Y …` (a drag along points, a move every 16ms, for `sample` to watch); `pathshot NAME …`
    /// also photographs the screen round the pointer before letting go (the drag's own picture).
    /// Photos and `state.txt` go to the `LONGHAND_LIVE` folder; the run quits at the end.
    @MainActor
    static func runLiveScript(_ store: LibraryStore, dir: String, script: String) {
        let lines = ((try? String(contentsOfFile: script, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let pid = ProcessInfo.processInfo.processIdentifier
        var log: [String] = []
        var shots = 0
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width > 400 } }
        func screenPoint(_ x: Double, _ y: Double) -> CGPoint {
            guard let window = window() else { return .zero }
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let content = window.contentLayoutRect
            // Window points from the window's top left → global display coordinates (top left).
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            _ = content
            return CGPoint(x: topLeft.x + x, y: screenHeight - topLeft.y + y)
        }
        func click(_ x: Double, _ y: Double, count: Int) {
            let point = screenPoint(x, y)
            for n in 1...count {
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                    event?.post(tap: .cghidEventTap)
                }
            }
        }
        func press(_ code: CGKeyCode, _ flags: CGEventFlags) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                event?.flags = flags
                event?.postToPid(pid)
            }
        }
        /// One mouse event at a point from the window's top left, posted as a real one.
        func mouse(_ type: CGEventType, _ x: Double, _ y: Double) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: screenPoint(x, y), mouseButton: .left)
            event?.post(tap: .cghidEventTap)
        }
        func type(_ text: String) {
            for character in text.utf16 {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    var unit = character
                    event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                    event?.postToPid(pid)
                }
            }
        }
        // A white square in the window's corner while the button is down, so a film of the run shows
        // exactly when it went down and up (`path`).
        var marked: NSWindow?
        func marker(_ on: Bool) {
            // Off unless asked (LONGHAND_MARKER=1): an extra window changes how a drag ends.
            guard environment["LONGHAND_MARKER"] == "1" else { return }
            if on, let main = window() {
                let square = NSWindow(contentRect: NSRect(x: main.frame.minX + 8, y: main.frame.minY + 8, width: 36, height: 36),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                square.backgroundColor = .white
                square.isOpaque = true
                square.ignoresMouseEvents = true
                square.level = .floating
                main.addChildWindow(square, ordered: .above)
                square.orderFront(nil)
                marked = square
            } else if let square = marked {
                square.parent?.removeChildWindow(square)
                square.orderOut(nil)
                marked = nil
            }
        }
        func state(_ label: String) {
            let margin = store.margin
            let page = margin.textView
            let responder = window()?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"
            let scroll = page?.enclosingScrollView?.contentView.bounds.origin.y ?? -1
            let comments = margin.comments.map { "[\($0.resolved ? "R" : "")\($0.id == margin.focused ? "*" : "") \($0.quote.prefix(20))→\($0.text.prefix(30))]" }
            log.append("\(label): frame=\(window()?.frame ?? .zero) responder=\(responder) selection=\(page.map { NSStringFromRange($0.selectedRange()) } ?? "-") scroll=\(Int(scroll)) sheet=\(store.cheatSheetShown) selected=\(String(describing: store.selection).components(separatedBy: "/").last ?? "") focused=\(margin.focused.map { _ in "yes" } ?? "no") comments=\(comments.joined(separator: " "))")
        }
        var steps: [(Double, @MainActor () -> Void)] = [(1.2, {
            NSApp.activate(ignoringOtherApps: true)
            if let window = window() {
                window.setFrame(NSRect(x: 80, y: (NSScreen.screens.first?.frame.height ?? 900) - 80 - 860, width: 1300, height: 860), display: true)
                window.makeKeyAndOrderFront(nil)
            }
        })]
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let command = parts[0], rest = parts.count > 1 ? parts[1] : ""
            let numbers = rest.split(separator: " ").compactMap { Double($0) }
            switch command {
            case "scene":
                steps.append((0.5, {
                    let scenes = store.library?.books.first?.chapters.flatMap(\.scenes) ?? []
                    let index = Int(numbers.first ?? 1) - 1
                    if scenes.indices.contains(index) { store.selection = .scene(scenes[index].url) }
                }))
            case "chapter":
                steps.append((0.5, {
                    let chapters = store.library?.books.first?.chapters ?? []
                    let index = Int(numbers.first ?? 1) - 1
                    if chapters.indices.contains(index) { store.selection = .chapter(chapters[index].url) }
                }))
            case "click", "double":
                steps.append((0.35, { click(numbers[0], numbers[1], count: command == "double" ? 2 : 1) }))
            case "drag":
                // `drag X1 Y1 X2 Y2`: a real drag, in small moves over half a second (a
                // hand holding the button), so SwiftUI's drag and drop takes part.
                guard numbers.count >= 4 else { break }
                steps.append((0.3, { mouse(.leftMouseDown, numbers[0], numbers[1]) }))
                for step in 1...14 {
                    let t = Double(step) / 14
                    let x = numbers[0] + (numbers[2] - numbers[0]) * t
                    let y = numbers[1] + (numbers[3] - numbers[1]) * t
                    steps.append((0.04, { mouse(.leftMouseDragged, x, y) }))
                }
                steps.append((0.5, { mouse(.leftMouseUp, numbers[2], numbers[3]) }))
            case "path", "pathshot":
                // `path X Y X Y …`: one drag along those points (window points), the button down
                // at the first and up at the last, a move every 16ms (a hand on a trackpad), for
                // `sample` to watch. How late the moves run is no measure of lag: timers wait
                // while a drag session is tracking.
                guard numbers.count >= 4 else { break }
                // `pathshot NAME X Y …`: the same, with a picture of the screen round the pointer
                // (the drag's own picture is not in the window) before the button goes up.
                let shotName = command == "pathshot" ? rest.split(separator: " ").first.map(String.init) : nil
                let points = stride(from: 0, to: numbers.count - 1, by: 2).map { (numbers[$0], numbers[$0 + 1]) }
                var path: [(Double, Double)] = [points[0]]
                for (from, to) in zip(points, points.dropFirst()) {
                    let count = max(1, Int(((to.0 - from.0) * (to.0 - from.0) + (to.1 - from.1) * (to.1 - from.1)).squareRoot() / 6))
                    for step in 1...count {
                        let t = Double(step) / Double(count)
                        path.append((from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t))
                    }
                }
                let route = path
                var pressed = 0.0
                var released = 0.0
                steps.append((0.3, {
                    DragProbe.began = 0
                    DragProbe.dropped = 0
                    pressed = ProcessInfo.processInfo.systemUptime
                    marker(true)
                    mouse(.leftMouseDown, route[0].0, route[0].1)
                }))
                for point in route.dropFirst() {
                    steps.append((0.016, { mouse(.leftMouseDragged, point.0, point.1) }))
                }
                steps.append((0.25, {
                    if let shotName {
                        shots += 1
                        let at = screenPoint(route[route.count - 1].0, route[route.count - 1].1)
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        process.arguments = ["-x", "-R", "\(Int(at.x) - 260),\(Int(at.y) - 110),520,220",
                                             "\(dir)/\(String(format: "%02d", shots))-\(shotName).png"]
                        try? process.run()
                        process.waitUntilExit()
                    }
                    log.append(DragProbe.began > 0
                               ? String(format: "path: drag began %.0f ms after the button went down", (DragProbe.began - pressed) * 1000)
                               : "path: no drag began")
                }))
                steps.append((0.3, {
                    released = ProcessInfo.processInfo.systemUptime
                    marker(false)
                    mouse(.leftMouseUp, route[route.count - 1].0, route[route.count - 1].1)
                }))
                steps.append((0.6, {
                    log.append(DragProbe.dropped > 0
                               ? String(format: "release: the drop's handler ran %.0f ms after the button went up", (DragProbe.dropped - released) * 1000)
                               : "release: the drop's handler never ran")
                }))
            case "wclick":
                // Straight into the window (works while the screen is locked or asleep).
                steps.append((0.35, {
                    guard let window = window() else { return }
                    let point = NSPoint(x: numbers[0], y: window.frame.height - numbers[1])
                    @MainActor func event(_ type: NSEvent.EventType, _ delay: Double) -> NSEvent? {
                        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + delay,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    }
                    // The up goes in the queue first: a view tracking the click waits there for it.
                    if let up = event(.leftMouseUp, 0.05) { NSApp.postEvent(up, atStart: false) }
                    if let down = event(.leftMouseDown, 0) { window.sendEvent(down) }
                }))
            case "scroll":
                // `scroll X Y DY [DX] [shift]`: a wheel scroll at a point (window points from
                // its top left), posted as a real event, as a trackpad would.
                steps.append((0.5, {
                    guard numbers.count >= 3 else { return }
                    let dx = numbers.count > 3 ? Int32(numbers[3]) : 0
                    guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                              wheelCount: dx == 0 ? 1 : 2,
                                              wheel1: Int32(numbers[2]), wheel2: dx, wheel3: 0) else { return }
                    if rest.contains("shift") { wheel.flags = .maskShift }
                    wheel.location = screenPoint(numbers[0], numbers[1])
                    wheel.post(tap: .cghidEventTap)
                }))
            case "cards":
                steps.append((0.5, { store.setViewMode(.cards) }))
            case "page":
                steps.append((0.5, { store.setViewMode(.page) }))
            case "library":
                steps.append((0.5, { store.showLibrary() }))
            case "type":
                steps.append((0.3, { type(rest) }))
            case "key":
                let words = rest.split(separator: " ")
                var flags: CGEventFlags = []
                if words.contains("cmd") { flags.insert(.maskCommand) }
                if words.contains("opt") { flags.insert(.maskAlternate) }
                if words.contains("ctrl") { flags.insert(.maskControl) }
                if words.contains("shift") { flags.insert(.maskShift) }
                let code = CGKeyCode(Int(words.first ?? "0") ?? 0)
                steps.append((0.3, { press(code, flags) }))
            case "wait":
                steps.append((numbers.first ?? 0.5, {}))
            case "shot":
                steps.append((0.25, {
                    guard let window = window() else { return }
                    shots += 1
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(dir)/\(String(format: "%02d", shots))-\(rest).png"]
                    try? process.run()
                    process.waitUntilExit()
                }))
            case "state":
                steps.append((0.2, { state(rest) }))
            default:
                log.append("unknown step: \(line)")
            }
        }
        steps.append((0.4, {
            try? log.joined(separator: "\n").write(toFile: "\(dir)/state.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }))
        var delay = 0.0
        for (wait, action) in steps {
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
        }
    }

    /// `LONGHAND_LIVE_KEYS=1`: presses the navigation keys for real (posted to this app) and
    /// writes where each one went to `keys.txt`.
    @MainActor
    static func runLiveKeys(_ store: LibraryStore, dir: String) {
        var log: [String] = []
        func now() -> String {
            guard case .scene(let url) = store.selection, let scene = store.scene(for: url),
                  let chapter = store.location(ofScene: url)?.chapter else { return "\(String(describing: store.selection))" }
            return "\(chapter.title) › \(scene.title)"
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        func press(_ key: CGKeyCode, _ flags: CGEventFlags, up: Bool = true) {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
            down?.flags = flags
            down?.postToPid(pid)
            if up {
                let release = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
                release?.flags = flags
                release?.postToPid(pid)
            }
        }
        func modifiers(_ flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: !flags.isEmpty)
            event?.type = .flagsChanged
            event?.flags = flags
            event?.postToPid(pid)
        }
        let steps: [(Double, @MainActor () -> Void)] = [
            (1.2, {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.frame.width > 400 }?.makeKeyAndOrderFront(nil)
                let scenes = store.library?.books.first?.chapters.flatMap(\.scenes) ?? []
                if scenes.count > 2 { store.selection = .scene(scenes[2].url) }
            }),
            (0.6, { if let page = store.margin.textView { page.window?.makeFirstResponder(page) }; log.append("start: \(now())") }),
            (0.2, { press(125, [.maskControl, .maskCommand]) }),                 // ⌃⌘↓
            (0.4, { log.append("⌃⌘↓ next scene: \(now())") }),
            (0.2, { press(126, [.maskControl, .maskCommand]) }),                 // ⌃⌘↑
            (0.4, { log.append("⌃⌘↑ previous scene: \(now())") }),
            (0.2, { press(125, [.maskAlternate, .maskCommand]) }),               // ⌥⌘↓
            (0.4, { log.append("⌥⌘↓ next chapter: \(now())") }),
            (0.2, { press(126, [.maskAlternate, .maskCommand]) }),               // ⌥⌘↑
            (0.4, { log.append("⌥⌘↑ previous chapter: \(now())") }),
            // ⌘L tapped once and ⌘ let go: back to the scene before.
            (0.2, { modifiers(.maskCommand); press(37, .maskCommand) }),
            (0.3, { modifiers([]) }),
            (0.5, { log.append("quick ⌘L: \(now()) (switcher shown: \(store.switcherShown))") }),
            // ⌘ held, L twice, then let go: two back.
            (0.2, { modifiers(.maskCommand); press(37, .maskCommand) }),
            (0.4, { press(37, .maskCommand) }),
            (0.4, { log.append("⌘ held, L twice: switcher shown \(store.switcherShown)") }),
            (0.1, { modifiers([]) }),
            (0.5, { log.append("⌘ let go: \(now()) (switcher shown: \(store.switcherShown))") }),
            (0.2, {
                try? log.joined(separator: "\n").write(toFile: "\(dir)/keys.txt", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }),
        ]
        var delay = 0.0
        for (wait, action) in steps {
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
        }
    }

    /// `LONGHAND_VERSIONS=save|draft|backup` pictures that sheet (in its own window, as above).
    @MainActor
    static func prepareVersions(_ store: LibraryStore) {
        guard let raw = environment["LONGHAND_VERSIONS"], let kind = VersionStore.Sheet(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let view = NSHostingView(rootView: VersionSheet(kind: kind).environmentObject(store.versions))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 520, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.alphaValue = 0
            window.setContentSize(view.fittingSize)
            window.orderFront(nil)
            exportWindow = window
        }
    }

    /// `LONGHAND_SHEET=crop|getlibrary|gitintro1…4` pictures the cover-cropping sheet (on a made-up
    /// picture) or Get Library from GitHub (with made-up names; GitHub is never asked).
    @MainActor
    static func prepareSheets(_ store: LibraryStore) {
        guard let kind = environment["LONGHAND_SHEET"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let content: AnyView
            switch kind {
            case "crop":
                let picture = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { rect in
                    NSColor(srgbRed: 0.44, green: 0.49, blue: 0.42, alpha: 1).setFill(); rect.fill()
                    NSColor(srgbRed: 0.79, green: 0.71, blue: 0.54, alpha: 1).setFill()
                    NSRect(x: 0, y: 0, width: 600, height: 160).fill()
                    NSColor(srgbRed: 0.91, green: 0.87, blue: 0.75, alpha: 1).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 120, y: 200, width: 130, height: 130)).fill()
                    return true
                }
                content = AnyView(CoverCropSheet(picture: picture) { _ in })
            case "gitintro1", "gitintro2", "gitintro3", "gitintro4":
                content = AnyView(GitIntro(step: Int(kind.suffix(1))! - 1))
            case "quit", "quitslow":
                let progress = QuitProgress.shared
                progress.pushing = true
                progress.offerQuitNow = kind == "quitslow"
                content = AnyView(QuitCard(progress: progress).padding(30))
            case "newdocument":
                // LONGHAND_NEWDOC_FORM=poetry chooses a form; LONGHAND_NEWDOC_AUTHOR=name sets up an
                // author (in memory: hidden runs never write profiles).
                if let name = environment["LONGHAND_NEWDOC_AUTHOR"] { AuthorProfiles.shared.add(AuthorProfile(name: name)) }
                let form = environment["LONGHAND_NEWDOC_FORM"].flatMap(BookForm.init(rawValue:)) ?? .novel
                content = AnyView(NewDocumentSheet(form: form).environmentObject(store))
            case "ghosts":
                // What hangs under the pointer in a drag: the card's old ghost, then the chips.
                let info = SceneInfo(synopsis: "She walks the sands at low tide.", status: .revised)
                content = AnyView(VStack(alignment: .leading, spacing: 18) {
                    SceneCard(title: "Scene 2", number: "1.2", info: info, words: 744, comments: 2, selected: true,
                              size: .medium, compact: true).frame(width: CardSize.medium.columnWidth)
                    HStack(alignment: .top, spacing: 0) {
                        DragChip(number: "1.2", title: "Scene 2")
                        DragChip(number: "2", title: "Chapter 2")
                        DragChip(number: nil, title: "The Salt Road")
                    }
                    DragChip(number: "12.4", title: "A scene with a very long name that runs on and on")
                }
                .padding(20).background(Color(PaperTheme.paper)))
            case "getlibrary":
                content = AnyView(GetLibrarySheet(preview: ["writing", "short-fiction", "the-salt-road", "notebooks"])
                    .environmentObject(store).environmentObject(store.versions))
            default: return
            }
            let view = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 520, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.alphaValue = 0
            window.setContentSize(view.fittingSize)
            window.orderFront(nil)
            exportWindow = window
        }
    }

    @MainActor
    static func prepareMargin(_ margin: MarginStore) {
        guard environment["LONGHAND_FOCUS"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            margin.focused = margin.comments.first { !$0.resolved }?.id
        }
    }

    static func applyAppearance() {
        if environment["LONGHAND_LIGHT"] == "1" { NSApp.appearance = NSAppearance(named: .aqua) }
        if environment["LONGHAND_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
    }

    static func takeIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 else { return }
        let path = args[index + 1]

        if environment["LONGHAND_LIGHT"] == "1" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        // Changes need a save and a look at Git first.
        let delay = environment["LONGHAND_CHANGES"] != nil ? 4.0 : 2.0
        // LONGHAND_PREVIEWTHEME=nord: preview a theme a moment before the picture.
        if let name = environment["LONGHAND_PREVIEWTHEME"], let theme = AppTheme(rawValue: name) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.8) { AppTheme.preview(theme) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            defer { NSApp.terminate(nil) }
            // With LONGHAND_EXPORT=1, picture the export sheet instead of the window.
            let sheet = environment["LONGHAND_EXPORT"] == "1" || environment["LONGHAND_VERSIONS"] != nil || environment["LONGHAND_SHEET"] != nil
                || environment["LONGHAND_SETTINGS"] == "1" ? exportWindow : nil
            guard let window = sheet ?? NSApp.windows.first(where: { ($0.isVisible || isBackgroundRun) && $0.contentView != nil && $0.frame.width > 400 }),
                  let view = window.contentView else { return }

            // LONGHAND_SCROLL=x,y,dy: a wheel scroll (points from the window's top left) before
            // the picture, for checking what a board or list does when scrolled.
            scrollIfRequested(in: window)

            if environment["LONGHAND_DUMP"] == "1" {
                var lines: [String] = [
                    "window.title=\"\(window.title)\" titleVisibility=\(window.titleVisibility.rawValue)"
                ]
                if let scrolled { lines.append("scroll: \(scrolled)") }
                if let toolbar = window.toolbar {
                    lines.append("toolbar items=\(toolbar.items.count)")
                    for item in toolbar.items {
                        let viewType = item.view.map { "\(type(of: $0)) frame=\($0.frame)" } ?? "custom"
                        lines.append("  item id=\(item.itemIdentifier.rawValue) label=\(item.label) image=\(item.image?.name() ?? "nil") view=\(viewType)")
                    }
                } else {
                    lines.append("toolbar = nil")
                }
                if let superview = view.superview {
                    lines.append("--- frame view (includes toolbar) ---")
                    dump(superview, depth: 0, into: &lines)
                }
                try? lines.joined(separator: "\n").write(
                    to: URL(fileURLWithPath: path + ".txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            // The frame view includes the toolbar; fall back to the content alone.
            let target = sheet == nil ? (view.superview ?? view) : view
            let bounds = target.bounds
            guard let rep = target.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            target.cacheDisplay(in: bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Sends a wheel event where the writer would scroll, through the window (so the view under
    /// the pointer gets it, as with a real trackpad).
    @MainActor private(set) static var scrolled: String?

    @MainActor
    private static func scrollIfRequested(in window: NSWindow) {
        guard let spec = environment["LONGHAND_SCROLL"] else { return }
        let numbers = spec.split(separator: ",").compactMap { Double($0) }
        guard numbers.count >= 3,
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(numbers[2]), wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg), let content = window.contentView else { return }
        let point = NSPoint(x: numbers[0], y: window.frame.height - numbers[1])
        guard var hit = content.hitTest(point) else { scrolled = "nothing at \(point)"; return }
        let hitType = String(describing: type(of: hit))
        var chain = [hitType]
        while !(hit is NSScrollView), let next = hit.superview { chain.append(String(describing: type(of: next))); hit = next }
        guard let scroll = hit as? NSScrollView else { scrolled = "no scroll view at \(point): \(chain.joined(separator: " < "))"; return }
        let before = scroll.contentView.bounds.origin
        scroll.scrollWheel(with: event)
        window.displayIfNeeded()
        var note = "wheel \(before) → \(scroll.contentView.bounds.origin) (deltaY \(event.scrollingDeltaY), fixed \(event.hasPreciseScrollingDeltas))"
        let limit = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        if scroll.contentView.bounds.origin == before, limit > 0 {
            scroll.contentView.scroll(to: NSPoint(x: before.x, y: min(limit, before.y + 200)))
            scroll.reflectScrolledClipView(scroll.contentView)
            note += "; forced → \(scroll.contentView.bounds.origin) (limit \(limit))"
        }
        scrolled = "\(chain.joined(separator: " < ")) \(note)"
    }

    private static func dump(_ view: NSView, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)\(type(of: view)) frame=\(view.frame)"

        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            line += " text=\"\(field.stringValue)\""
        }
        if let textView = view as? NSTextView, !textView.string.isEmpty {
            line += " textView(length=\(textView.string.count))"
        }
        if let scroll = view as? NSScrollView {
            line += " document=\(scroll.documentView?.frame.size ?? .zero) at=\(scroll.contentView.bounds.origin)"
        }
        if view.isHidden { line += " hidden" }
        lines.append(line)

        for subview in view.subviews {
            dump(subview, depth: depth + 1, into: &lines)
        }
    }
}
