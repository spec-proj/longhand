import AppKit
import PDFKit

/// Dev aid: `Longhand --selftest /path/report.txt` exercises the folder model and quits.
///
/// It runs against a temporary library and puts the owner's remembered library back
/// afterwards, so running it never changes what the app opens next time.
@MainActor
enum SelfTest {
    private static let lastLibraryKey = "lastLibraryPath"

    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--selftest"), args.count > index + 1 else { return }
        let reportPath = args[index + 1]

        Task { @MainActor in
            await run(store: store, reportPath: reportPath)
        }
    }

    private static func run(store: LibraryStore, reportPath: String) async {
        var lines: [String] = []
        var failures = 0

        func check(_ condition: Bool, _ label: String) {
            lines.append("\(condition ? "PASS" : "FAIL")  \(label)")
            if !condition { failures += 1 }
        }

        let fm = FileManager.default
        let defaults = UserDefaults.standard
        let rememberedLibrary = defaults.string(forKey: lastLibraryKey)
        let root = fm.temporaryDirectory.appendingPathComponent("LonghandSelfTest-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        func finish() {
            store.closeLibrary()
            try? fm.removeItem(at: root)
            if let rememberedLibrary {
                defaults.set(rememberedLibrary, forKey: lastLibraryKey)
            } else {
                defaults.removeObject(forKey: lastLibraryKey)
            }
            write(lines, failures: failures, to: reportPath)
            NSApp.terminate(nil)
        }

        func disk(_ url: URL?) -> String {
            guard let url else { return "<missing>" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
        }

        func item(_ scene: Scene) -> ManuscriptItem {
            ManuscriptItem(url: scene.url, title: scene.title, order: scene.order, kind: .scene)
        }

        func item(_ chapter: Chapter) -> ManuscriptItem {
            ManuscriptItem(url: chapter.url, title: chapter.title, order: chapter.order, kind: .chapter)
        }

        func chapters() -> [Chapter] { store.library?.books.first?.chapters ?? [] }

        var selectedSceneURL: URL? {
            if case .scene(let url) = store.selection { return url }
            return nil
        }

        // MARK: Basics

        store.openLibrary(at: root)
        check(store.library != nil, "library opens")

        store.createBook()
        let book = store.library?.books.first
        check(book != nil, "book is created")
        check(book?.chapters.count == 1, "book gets a first chapter")
        check(book?.chapters.first?.scenes.count == 1, "chapter gets a first scene")

        guard let firstScene = book?.chapters.first?.scenes.first else {
            failures += 1
            finish()
            return
        }

        check(store.selection == .scene(firstScene.url), "new scene is selected")
        check(fm.fileExists(atPath: firstScene.url.path), "scene file exists on disk")

        let prose = "# Opening\n\nShe walked out at low tide and counted the ribs of a wreck."
        store.updateText(prose)
        store.saveNow()
        check(disk(firstScene.url) == prose, "text is saved to the Markdown file")
        check(store.wordCount(of: firstScene) == 14, "word count is correct (the # is not a word)")
        check(LibraryStore.wordCount("> under it — **very faintly** — a piano.\n\n***\n\n- café × 2") == 8,
              "word count leaves out lone symbols and dashes")

        store.rename(item(firstScene), to: "Low Tide")
        guard let renamed = chapters().first?.scenes.first else {
            failures += 1
            finish()
            return
        }
        check(renamed.url.lastPathComponent == "01 Low Tide.md", "scene renames on disk")
        check(store.selection == .scene(renamed.url), "selection follows a rename")
        check(disk(renamed.url) == prose, "renamed scene keeps its text")

        store.createSceneInContext()
        check(chapters().first?.scenes.count == 2, "a second scene is created")

        if let second = chapters().first?.scenes.last {
            store.move(item(second), by: -1)
            check(chapters().first?.scenes.first?.title == second.title, "scene moves up in order")
            if let top = chapters().first?.scenes.first {
                store.margin.setInfo(SceneInfo(synopsis: "To go", status: .draft, target: 300), for: top.url)
                let before = Discard.log.count
                store.delete(item(top))
                let letGo = Discard.log.dropFirst(before)
                check(letGo.filter(\.kept).count == 1 && letGo.first(where: \.kept)?.url == top.url,
                      "trash: deleting a scene sends only the scene to the Trash")
                check(letGo.contains { !$0.kept && $0.url.path.contains("/.longhand/scenes/") },
                      "trash: its details are removed quietly, not left in the Trash")
            }
        }
        check(chapters().first?.scenes.count == 1, "scene deletes")

        // MARK: The open scene keeps saving while other items change

        guard let lowTide = chapters().first?.scenes.first else {
            failures += 1
            finish()
            return
        }
        store.createSceneInContext()
        guard let other = chapters().first?.scenes.last, other.url != lowTide.url else {
            failures += 1
            finish()
            return
        }

        store.selection = .scene(lowTide.url)
        store.updateText("alpha one")
        store.rename(item(other), to: "Second")
        check(disk(lowTide.url) == "alpha one", "typing just before renaming another scene is saved")
        store.updateText("alpha two")
        store.saveNow()
        check(disk(lowTide.url) == "alpha two", "open scene still saves after renaming another scene")

        if let second = chapters().first?.scenes.first(where: { $0.title == "Second" }) {
            store.updateText("alpha three")
            // This swaps "Second" with the open scene, so the open scene's file is renamed.
            store.move(item(second), by: -1)
            let openScene = selectedSceneURL
            check(openScene.map { store.scene(for: $0)?.title } == "Low Tide",
                  "open scene stays open when it is reordered")
            check(disk(openScene) == "alpha three", "typing just before reordering is saved")
            store.updateText("alpha four")
            store.saveNow()
            check(disk(openScene) == "alpha four", "open scene still saves after reordering")

            if let movedSecond = chapters().first?.scenes.first(where: { $0.title == "Second" }) {
                store.updateText("alpha five")
                store.delete(item(movedSecond))
                check(disk(openScene) == "alpha five", "typing just before deleting another scene is saved")
                store.updateText("alpha six")
                store.saveNow()
                check(disk(openScene) == "alpha six", "open scene still saves after deleting another scene")
            } else {
                check(false, "second scene is found after reordering")
            }
        } else {
            check(false, "renamed scene is found")
        }

        // MARK: Moving the chapter that holds the open scene

        let openBeforeChapterMove = selectedSceneURL
        store.createChapterInContext()
        check(chapters().count == 2, "a second chapter is created")
        if let openBeforeChapterMove { store.selection = .scene(openBeforeChapterMove) }
        store.updateText("alpha seven")

        if let chapterOne = chapters().first {
            store.move(item(chapterOne), by: 1)
            let followed = selectedSceneURL
            check(followed != nil && followed != openBeforeChapterMove,
                  "selection follows its chapter when it moves")
            check(disk(followed) == "alpha seven", "typing just before moving the chapter is saved")
            store.updateText("alpha eight")
            store.saveNow()
            check(disk(followed) == "alpha eight", "open scene still saves after its chapter moves")
            check(openBeforeChapterMove.map { !fm.fileExists(atPath: $0.path) } == true,
                  "no stray file is left at the old path")
        }

        // MARK: Swapping two scenes with the same name keeps both names

        if let newChapter = chapters().first {
            store.selection = .chapter(newChapter.url)
            store.createSceneInContext()
            let scenes = chapters().first?.scenes ?? []
            check(scenes.count == 2 && Set(scenes.map(\.title)) == ["Untitled Scene"],
                  "chapter has two scenes with the same name")
            if let last = scenes.last {
                store.move(item(last), by: -1)
                let titles = chapters().first?.scenes.map(\.title) ?? []
                check(titles == ["Untitled Scene", "Untitled Scene"], "swapping same-named scenes keeps their names")
            }
        }

        // MARK: Switching straight from one chapter to another shows the right text

        if chapters().count == 2, let bravoScene = chapters()[0].scenes.first {
            store.selection = .scene(bravoScene.url)
            store.updateText("bravo")
            store.saveNow()

            store.selection = .chapter(chapters()[0].url)
            try? await Task.sleep(for: .milliseconds(600))
            let first = chapterPage()?.string
            store.selection = .chapter(chapters()[1].url)
            try? await Task.sleep(for: .milliseconds(600))
            let second = chapterPage()?.string
            check(first?.contains("bravo") == true, "chapter view shows the first chapter")
            check(second?.contains("alpha eight") == true && second?.contains("bravo") == false,
                  "chapter view updates when switching straight to another chapter")
        } else {
            check(false, "two chapters exist for the chapter-switch test")
        }

        // MARK: Editing on the chapter page

        if let chapter = chapters().first, chapter.scenes.count == 2 {
            let sceneA = chapter.scenes[0].url
            let sceneB = chapter.scenes[1].url
            store.selection = .chapter(chapter.url)
            try? await Task.sleep(for: .milliseconds(600))

            if let page = chapterPage(),
               let editor = page.delegate as? ChapterEditor.Coordinator,
               editor.segments.count == 2 {
                func pause() async { try? await Task.sleep(for: .milliseconds(120)) }
                let beforeA = disk(sceneA)

                // Typing at the end of the first scene goes into the first scene's file.
                page.setSelectedRange(NSRange(location: NSMaxRange(editor.segments[0].range), length: 0))
                page.insertText(" and more", replacementRange: page.selectedRange())
                await pause()
                store.saveNow()
                check(disk(sceneA) == beforeA + " and more", "chapter page: typing saves into that scene")
                check(disk(sceneB) == "", "chapter page: other scenes are untouched")

                // Typing into an empty scene fills that scene's file.
                page.setSelectedRange(NSRange(location: editor.segments[1].range.location, length: 0))
                page.insertText("charlie", replacementRange: page.selectedRange())
                await pause()
                store.saveNow()
                check(disk(sceneB) == "charlie", "chapter page: typing into an empty scene saves it")
                check(disk(sceneA) == beforeA + " and more", "chapter page: the scene before stays as it was")
                // A refresh (word counts change after every edit) must not reload old text.
                store.objectWillChange.send()
                await pause()
                check(page.string.contains("charlie") && page.string.contains(" and more"),
                      "chapter page: the screen keeps the newest text after a refresh")

                // Edits that would merge two scenes are refused.
                let boundary = editor.segments[1].range.location
                check(!page.shouldChangeText(in: NSRange(location: boundary - 1, length: 1), replacementString: ""),
                      "chapter page: backspacing at the start of a scene is refused")
                check(!page.shouldChangeText(in: NSRange(location: boundary - 3, length: 6), replacementString: ""),
                      "chapter page: deleting across two scenes is refused")
                check(!page.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"),
                      "chapter page: the chapter title is not editable")

                // ⌘A: the scene the caret is in, then every scene; never the chapter's title.
                page.setSelectedRange(NSRange(location: editor.segments[1].range.location + 1, length: 0))
                page.selectAll(nil)
                check(page.selectedRange() == editor.segments[1].range, "chapter page: ⌘A selects the scene the caret is in")
                page.selectAll(nil)
                let body = NSRange(location: editor.segments[0].range.location,
                                   length: NSMaxRange(editor.segments[editor.segments.count - 1].range) - editor.segments[0].range.location)
                check(page.selectedRange() == body && body.location >= editor.bodyStart,
                      "chapter page: ⌘A again selects every scene, not the title")
                page.setSelectedRange(NSRange(location: NSMaxRange(editor.segments[1].range), length: 0))

                // Undo puts the scene back, and that is saved too.
                editor.undo.undo()
                await pause()
                store.saveNow()
                check(disk(sceneB) == "", "chapter page: undo is saved to the right scene")

                // Quitting straight after typing on the chapter page saves.
                page.setSelectedRange(NSRange(location: NSMaxRange(editor.segments[1].range), length: 0))
                page.insertText("delta", replacementRange: page.selectedRange())
                await pause()
                NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
                check(disk(sceneB) == "delta", "chapter page: quitting straight after typing saves")

                // Scene numbers: set between scenes, never part of a scene, never copied.
                let text = page.string as NSString
                let first = editor.segments[0].range, second = editor.segments[1].range
                check(first.location == editor.bodyStart
                      && second.location >= 6 && text.substring(with: NSRange(location: second.location - 6, length: 6)) == "* * *\n",
                      "chapter page: three asterisks between scenes, none before the first")
                check(!disk(sceneA).contains("* * *") && !disk(sceneB).contains("* * *"),
                      "chapter page: the break is never saved into a scene")
                check(!page.shouldChangeText(in: NSRange(location: second.location - 2, length: 0), replacementString: "x"),
                      "chapter page: a scene's number is not editable")
                page.setSelectedRange(NSRange(location: first.location, length: NSMaxRange(second) - first.location))
                let board = NSPasteboard(name: NSPasteboard.Name("longhand-selftest"))
                _ = page.writeSelection(to: board, types: [.string])
                check(board.string(forType: .string) == disk(sceneA) + "\n\n" + disk(sceneB),
                      "chapter page: copying across scenes leaves the numbers out")
                board.releaseGlobally()
                // The caret skips the number line, the way it was heading.
                page.setSelectedRange(NSRange(location: NSMaxRange(first), length: 0))
                page.setSelectedRange(NSRange(location: second.location - 2, length: 0))
                check(page.selectedRange().location == second.location, "chapter page: the caret steps over a scene's number going down")
                page.setSelectedRange(NSRange(location: second.location - 2, length: 0))
                check(page.selectedRange().location == NSMaxRange(first), "chapter page: and going up")
                page.setSelectedRange(NSRange(location: 0, length: 0))
                check(page.selectedRange().location == first.location, "chapter page: the caret never rests in the title")
            } else {
                check(false, "chapter page is on screen with two scenes")
            }
        } else {
            check(false, "a chapter with two scenes exists for the chapter-page test")
        }

        // MARK: Comments and notes

        let margin = store.margin
        func settle(_ milliseconds: Int = 500) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func reopen(_ scene: URL, from chapter: URL) async {
            store.selection = .chapter(chapter)
            await settle(300)
            store.selection = .scene(scene)
            await settle()
        }
        func passage(_ id: UUID) -> String? {
            guard let page = margin.textView,
                  let comment = margin.comments.first(where: { $0.id == id }),
                  NSMaxRange(comment.range) <= (page.string as NSString).length else { return nil }
            return (page.string as NSString).substring(with: comment.range)
        }

        if let chapter = chapters().first, let sceneURL = chapter.scenes.first?.url {
            store.selection = .scene(sceneURL)
            store.updateText("One two three. The lamp burned. Four five.")
            store.saveNow()
            await reopen(sceneURL, from: chapter.url)

            if let page = margin.textView {
                page.setSelectedRange((page.string as NSString).range(of: "The lamp burned"))
                let made = margin.addCommentOnSelection()
                check(made != nil, "comments: a comment is made on the selected text")
                check(page.selectedRange().length == 0, "comments: making one leaves its passage unselected")
                if let id = made?.id {
                    await settle(250)   // the comment's field opens and takes the keys
                    margin.setText("Quick note", of: id)
                    margin.finishEditing(id)
                    await settle(100)
                    check(margin.focused == nil, "comments: Return finishes one")
                    check(page.window?.firstResponder === page, "comments: after Return the keys go back to the page")
                    check(margin.comments.contains { $0.id == id && $0.text == "Quick note" }, "comments: a finished comment is kept")
                }
                if let id = made?.id {
                    margin.setText("Who lit it?", of: id)
                    margin.focused = nil
                    margin.saveNow()
                    check(margin.readComments(for: sceneURL).first?.text == "Who lit it?", "comments: the comment is saved")
                    check(margin.openCounts[sceneURL] == 1, "comments: the contents shows one open comment")
                    check(!disk(sceneURL).contains("Who lit it?"), "comments: the scene file is untouched")

                    page.setSelectedRange(NSRange(location: 0, length: 0))
                    page.insertText("Zero. ", replacementRange: page.selectedRange())
                    await settle(150)
                    check(passage(id) == "The lamp burned", "comments: the comment moves with its passage while typing")
                    store.saveNow()

                    // Text added before the passage outside Longhand (another editor, say).
                    try? ("Prologue.\n\n" + disk(sceneURL)).write(to: sceneURL, atomically: true, encoding: .utf8)
                    await reopen(sceneURL, from: chapter.url)
                    check(passage(id) == "The lamp burned", "comments: the comment finds its passage after an edit elsewhere")

                    margin.setSceneNote("Remember the lamp.")
                    margin.setChapterNote("Low tide.")
                    margin.saveNow()

                    if let scene = store.scene(for: sceneURL) {
                        store.rename(item(scene), to: "Lamp")
                        if case .scene(let renamed) = store.selection, renamed != sceneURL {
                            check(margin.readComments(for: renamed).first?.text == "Who lit it?",
                                  "comments: the comment follows a renamed scene")
                            check(margin.sceneNote == "Remember the lamp.", "notes: the scene note follows a renamed scene")

                            if chapters().count == 2, let parent = chapters().first {
                                store.move(item(parent), by: 1)
                                if case .scene(let moved) = store.selection, moved != renamed {
                                    check(margin.readComments(for: moved).count == 1,
                                          "comments: the comment follows its chapter when it moves")
                                    check(margin.chapterNote == "Low tide.", "notes: the chapter note follows its chapter")
                                    margin.setResolved(true, id)
                                    check(margin.openCounts[moved] == nil, "comments: resolving clears the count")
                                    check(margin.readComments(for: moved).first?.resolved == true,
                                          "comments: a resolved comment is kept")
                                } else {
                                    check(false, "comments: the open scene follows its chapter")
                                }
                            }
                        } else {
                            check(false, "comments: the renamed scene stays open")
                        }
                    }
                }
            } else {
                check(false, "comments: the scene editor is on screen")
            }

            margin.createBookNote()
            store.refreshFromDisk()
            let notesFolder = store.library?.books.first.map { MarginStore.notesFolder(of: $0.url) }
            check(notesFolder.map { fm.fileExists(atPath: $0.path) } == true, "notes: a book note is made in the Notes folder")
            check(store.library?.books.first?.chapters.contains { $0.title == "Notes" } == false,
                  "notes: the Notes folder is not a chapter")
        }

        // MARK: Cards: scene details and moving scenes

        store.createBook()
        func cardChapters() -> [Chapter] { store.library?.books.last?.chapters ?? [] }
        func titles(_ index: Int) -> [String] {
            cardChapters().indices.contains(index) ? cardChapters()[index].scenes.map(\.title) : []
        }
        func files(_ index: Int) -> [String] {
            cardChapters().indices.contains(index)
                ? cardChapters()[index].scenes.map { $0.url.lastPathComponent } : []
        }
        func sceneNamed(_ title: String) -> Scene? {
            cardChapters().flatMap(\.scenes).first { $0.title == title }
        }

        if let firstScene = cardChapters().first?.scenes.first {
            store.selection = .scene(firstScene.url)
            store.createSceneInContext()
            store.createSceneInContext()
            for (index, name) in ["A", "B", "C"].enumerated() {
                if let scene = cardChapters().first?.scenes[safe: index] { store.rename(item(scene), to: name) }
            }
            check(titles(0) == ["A", "B", "C"], "cards: a chapter with scenes A, B, C")

            if let b = sceneNamed("B") {
                margin.setInfo(SceneInfo(synopsis: "Bee", status: .draft, target: 500), for: b.url)
            }
            if let c = sceneNamed("C"), let chapter = cardChapters().first {
                store.placeScene(c.url, inChapter: chapter.url, at: 0)
            }
            check(titles(0) == ["C", "A", "B"], "cards: dragging a card reorders the scenes")
            check(files(0) == ["01 C.md", "02 A.md", "03 B.md"], "cards: filenames are renumbered in order")
            check(sceneNamed("B").map { margin.info(for: $0.url).synopsis } == "Bee",
                  "cards: a scene's details follow it when the order changes")

            if let chapter = cardChapters().first {
                store.selection = .chapter(chapter.url)
                store.createChapterInContext()
            }
            if let a = sceneNamed("A"), cardChapters().count == 2 {
                store.placeScene(a.url, inChapter: cardChapters()[1].url, at: 0)
                check(titles(0) == ["C", "B"] && files(0) == ["01 C.md", "02 B.md"],
                      "cards: moving a scene out renumbers the chapter it left")
                check(titles(1).first == "A", "cards: the scene arrives at the top of the other chapter")
            } else {
                check(false, "cards: two chapters exist for moving a scene")
            }
            if let b = sceneNamed("B"), cardChapters().count == 2 {
                store.placeScene(b.url, inChapter: cardChapters()[1].url, at: 99)
                check(titles(1).last == "B", "cards: dropping on a chapter puts the scene last")
                check(sceneNamed("B").map { margin.info(for: $0.url) }
                      == SceneInfo(synopsis: "Bee", status: .draft, target: 500),
                      "cards: a scene's details follow it to another chapter")
            }
            let leftovers = cardChapters().flatMap { chapter in
                ((try? fm.contentsOfDirectory(atPath: chapter.url.path)) ?? []).filter { $0.hasPrefix(".longhand-moving") }
            }
            check(leftovers.isEmpty, "cards: no hidden files are left behind")

            if let cardBook = store.library?.books.last {
                margin.setInfo(SceneInfo(target: 90000), for: cardBook.url)
                store.rename(ManuscriptItem(url: cardBook.url, title: cardBook.title, order: cardBook.order, kind: .book),
                             to: "Cards Book")
                let renamed = store.library?.books.first { $0.title == "Cards Book" }
                check(renamed.map { margin.info(for: $0.url).target } == 90000,
                      "targets: a book's word target follows the book when it is renamed")
            }
        } else {
            check(false, "cards: a new book is made for the cards test")
        }

        // MARK: Comments on the chapter page

        if let chapter = cardChapters().last, chapter.scenes.count >= 2 {
            let second = chapter.scenes[1].url
            store.selection = .scene(second)
            store.updateText("Quiet morning. The gate was open. Birds.")
            store.saveNow()
            store.selection = .chapter(chapter.url)
            await settle(700)

            if let page = chapterPage(), let editor = page.delegate as? ChapterEditor.Coordinator,
               editor.segments.count >= 2 {
                page.setSelectedRange((page.string as NSString).range(of: "The gate was open"))
                let made = margin.addCommentOnSelection()
                check(made?.scene == second && made?.location == 15,
                      "chapter comments: a comment on the chapter page belongs to its scene")
                if let id = made?.id {
                    margin.setText("Who left it open?", of: id)
                    margin.focused = nil
                    margin.saveNow()
                    check(margin.readComments(for: second).first?.text == "Who left it open?",
                          "chapter comments: the comment is saved with its scene")

                    page.setSelectedRange(NSRange(location: editor.segments[0].range.location, length: 0))
                    page.insertText("Hello. ", replacementRange: page.selectedRange())
                    await settle(250)
                    let moved = margin.comments.first { $0.id == id }
                    check(moved?.location == 15, "chapter comments: typing in another scene leaves it in place")
                    check(moved.flatMap { margin.pageRange(of: $0) }.map { (page.string as NSString).substring(with: $0) }
                          == "The gate was open", "chapter comments: it stays on its passage on the page")
                    check((page as? HighlightTextView)?.highlights.isEmpty == false, "chapter comments: its passage is highlighted on the page")

                    store.saveNow()
                    store.selection = .scene(second)
                    await settle()
                    check(passage(id) == "The gate was open", "chapter comments: the same comment shows on the scene")
                }
            } else {
                check(false, "chapter comments: the chapter page is on screen")
            }
        }

        // MARK: Restyling only the edited lines matches restyling everything

        if let scene = chapters().last?.scenes.first {
            store.selection = .scene(scene.url)
            store.updateText("First paragraph here.\n\nSecond paragraph.\n\nThird one, *italic*.\n\n> A quote\n\nAfter the quote.\n\n- one\n- two\n\nLast.")
            await settle(300)
            if let page = margin.textView {
                func type(_ text: String, at location: Int, replacing length: Int = 0) async {
                    page.setSelectedRange(NSRange(location: location, length: length))
                    page.insertText(text, replacementRange: page.selectedRange())
                    await settle(30)
                }
                let string = { page.string as NSString }
                await type("# ", at: string().range(of: "Second").location)            // body → heading
                await type("", at: string().range(of: "# ").location, replacing: 2)      // and back
                await type("- ", at: string().range(of: "Third").location)              // body → list
                await type("x", at: string().range(of: "After").location)               // typing after a quote
                await type("\n\nNew paragraph", at: string().range(of: "Last.").location + 5)
                await type("**bold** ", at: 0)

                let fresh = NSTextStorage(string: page.string)
                MarkdownStyler.apply(to: fresh)
                var same = true
                var location = 0
                let text = page.string as NSString
                while location < text.length {
                    let line = text.lineRange(for: NSRange(location: location, length: 0))
                    let a = page.textStorage?.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle
                    let b = fresh.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle
                    let fa = page.textStorage?.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont
                    let fb = fresh.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont
                    if a?.firstLineHeadIndent != b?.firstLineHeadIndent || a?.paragraphSpacingBefore != b?.paragraphSpacingBefore
                        || a?.headIndent != b?.headIndent || fa != fb {
                        same = false
                    }
                    location = NSMaxRange(line)
                }
                check(same, "speed: restyling only the edited lines looks the same as restyling the whole scene")
            }
            store.saveNow()
        }

        // MARK: History

        if let chapter = chapters().first {
            store.selection = .chapter(chapter.url)
            store.createSceneInContext()
            if case .scene(let url) = store.selection {
                store.updateText("First draft of the scene.")
                store.saveNow()
                store.updateText("Second draft of the scene.")
                store.saveNow()
                store.updateText("Third draft of the scene.")
                store.saveNow()
                let versions = store.history.versions(of: url)
                check(versions.count == 1 && versions.first.map(store.history.text(of:)) == "First draft of the scene.",
                      "history: the text before an overwrite is kept, once per ten minutes")

                if let first = versions.first {
                    store.restore(first)
                    check(disk(url) == "First draft of the scene.", "history: restoring a version puts it back")
                    let after = store.history.versions(of: url)
                    check(after.contains { store.history.text(of: $0) == "Third draft of the scene." },
                          "history: restoring keeps the replaced text as a version")
                }

                if let scene = store.scene(for: url) {
                    store.rename(item(scene), to: "Versions")
                    if case .scene(let renamed) = store.selection {
                        check(store.history.versions(of: renamed).count >= 2, "history: versions follow a renamed scene")
                    }
                }
            }
        }

        // MARK: Export

        let parsed = ManuscriptBuilder.blocks(
            from: "# Arrival\n\nShe walked *out* at **low** tide.\nStill walking.\n\n---\n\n> A letter.\n\n## Later\n\nEnd.",
            sceneTitle: "Arrival"
        )
        check(parsed == [
            .paragraph([.init(text: "She walked "), .init(text: "out", italic: true), .init(text: " at "),
                        .init(text: "low", bold: true), .init(text: " tide. Still walking.")], opening: false),
            .sceneBreak,
            .quote([.init(text: "A letter.")]),
            .heading([.init(text: "Later")]),
            .paragraph([.init(text: "End.")], opening: false)
        ], "export: Markdown becomes paragraphs, emphasis, breaks and quotes (the scene's own title dropped)")

        do {
            typealias Run = ManuscriptBook.Run
            check(ManuscriptBuilder.runs("a ***both*** b") == [Run(text: "a "), Run(text: "both", italic: true, bold: true), Run(text: " b")],
                  "export: three stars are bold and italic together")
            check(ManuscriptBuilder.runs("**bold *and italic* here**") == [Run(text: "bold ", bold: true),
                    Run(text: "and italic", italic: true, bold: true), Run(text: " here", bold: true)],
                  "export: italic inside bold")
            check(ManuscriptBuilder.runs("*soft **loud** soft*") == [Run(text: "soft ", italic: true),
                    Run(text: "loud", italic: true, bold: true), Run(text: " soft", italic: true)],
                  "export: bold inside italic")
            check(ManuscriptBuilder.runs(#"an escaped \*star\* and 2 * 3 * 4"#) == [Run(text: "an escaped *star* and 2 * 3 * 4")],
                  "export: a backslash makes a star plain, and loose stars stay")
            check(ManuscriptBuilder.runs("snake_case_word and file_name.txt") == [Run(text: "snake_case_word and file_name.txt")],
                  "export: underscores inside words are left alone")
            check(ManuscriptBuilder.runs("a [link *here*](https://example.com/a_b) and `code`") == [Run(text: "a link "),
                    Run(text: "here", italic: true), Run(text: " and code")],
                  "export: a link keeps its words; code is plain")
            let tabled = ManuscriptBuilder.blocks(
                from: "Before.\n\n| Tide | Time |\n|------|:----:|\n| High | *six* |\n| Low \\| ebb | |\n\nAfter | not a table.",
                sceneTitle: "S")
            let expected: ManuscriptBook.Block = .table([
                [[Run(text: "Tide")], [Run(text: "Time")]],
                [[Run(text: "High")], [Run(text: "six", italic: true)]],
                [[Run(text: "Low | ebb")], []]
            ])
            check(tabled.count == 3 && tabled[1] == expected, "export: a table keeps its rows and cells, an escaped bar and an empty cell")
            check(tabled.last == .paragraph([Run(text: "After | not a table.")], opening: false),
                  "export: a line with a bar but no ruled line under it is ordinary prose")
            let noted = ManuscriptBuilder.blocks(
                from: "The tide[^t] turned, and the *bell*[^2] rang. No such[^x] note.\n\n[^t]: Twice a day,\n    more or *less*.\n[^2]: Cast in 1890.\n\nAfter.",
                sceneTitle: "S")
            let afterNotes: [ManuscriptBook.Block] = [.paragraph([Run(text: "After.")], opening: false)]
            check(noted.count == 2 && Array(noted.dropFirst()) == afterNotes, "export: footnote lines are taken out of the text")
            if case .paragraph(let runs, _)? = noted.first {
                check(runs.map(\.text).joined() == "The tide turned, and the bell rang. No such[^x] note.",
                      "export: a footnote's call leaves the sentence; a call with no note stays as typed")
                let found = runs.compactMap(\.note)
                check(found.count == 2 && found.first == [Run(text: "Twice a day, more or "), Run(text: "less", italic: true), Run(text: ".")]
                      && found.last == [Run(text: "Cast in 1890.")],
                      "export: footnotes keep their words and emphasis, carried-on lines included")
                let numbered = ManuscriptBook.Chapter(number: 1, title: "C", blocks: noted).numbered()
                if case .paragraph(let shown, _)? = numbered.blocks.first {
                    check(shown.filter(\.raised).map(\.text) == ["1", "2"] && numbered.notes.count == 2,
                          "export: for the PDFs footnotes are numbered and listed for the chapter's end")
                }
            } else {
                check(false, "export: a paragraph with footnotes")
            }
            check(ManuscriptBuilder.runs(#"C:\Users and a\b"#) == [Run(text: #"C:\Users and a\b"#)],
                  "export: a backslash before a letter stays")
        }

        if let book = store.library?.books.first {
            var settings = ExportSettings()
            settings.name = "Test Writer"
            settings.contact = "1 Test Street\ntest@example.com"
            let folder = fm.temporaryDirectory.appendingPathComponent("LonghandExport-\(UUID().uuidString)")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }

            settings.format = .manuscriptWord
            let docx = folder.appendingPathComponent("test.docx")
            let wordOK = (try? Exporter.export(book, store: store, settings: settings, to: docx)) != nil
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-p", docx.path, "word/document.xml", "word/header1.xml"]
            let pipe = Pipe()
            unzip.standardOutput = pipe
            try? unzip.run()
            let xml = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            unzip.waitUntilExit()
            check(wordOK && xml.contains("THE END") && xml.contains("Writer / \(book.title) / ") && xml.contains("Test Writer"),
                  "export: the Word manuscript has a title page, the text, THE END and a running header")

            settings.format = .manuscriptPDF
            let pdf = folder.appendingPathComponent("test.pdf")
            let pdfOK = (try? Exporter.export(book, store: store, settings: settings, to: pdf)) != nil
            let manuscript = PDFDocument(url: pdf)
            check(pdfOK && (manuscript?.pageCount ?? 0) >= 2 && (manuscript?.string ?? "").contains("THE END"),
                  "export: the PDF manuscript has a title page and the text")

            settings.format = .bookPDF
            let printed = folder.appendingPathComponent("book.pdf")
            let bookOK = (try? Exporter.export(book, store: store, settings: settings, to: printed)) != nil
            let edition = PDFDocument(url: printed)
            check(bookOK && (edition?.pageCount ?? 0) >= 3 && edition?.page(at: 0)?.bounds(for: .mediaBox).width == 396
                  && (edition?.string ?? "").contains("Contents") && (edition?.string ?? "").contains("All rights reserved"),
                  "export: the book PDF is a 5.5 by 8.5 inch book with title, copyright and contents pages")
        }

        // MARK: Versions (Git)

        let versions = store.versions
        func idle() async {
            versions.waitUntilIdle()
            await settle(150)
            versions.waitUntilIdle()
            await settle(150)
        }
        func git(_ args: String...) -> String {
            guard let lib = store.libraryURL else { return "" }
            return Git.run(args, in: lib).output
        }
        await idle()
        if let lib = store.libraryURL {
            check(versions.available && fm.fileExists(atPath: lib.appendingPathComponent(".git").path),
                  "versions: the library becomes a Git repository")
            check(disk(lib.appendingPathComponent(".gitattributes")).contains("*.md     text eol=lf diff=markdown"),
                  "versions: .gitattributes labels changes by Markdown heading")
            check(git("log", "--format=%s").contains("Initial commit"),
                  "versions: a first version is recorded")
            check(git("config", "user.email").hasSuffix("@longhand.local"),
                  "versions: signed with this Mac's user, not a work account")
            check(git("ls-files", ".longhand/history").isEmpty && !git("ls-files").isEmpty,
                  "versions: the History tab's copies are left out, everything else is kept")

            if let scene = chapters().first?.scenes.first {
                store.selection = .scene(scene.url)
                store.updateText("A version worth keeping.")
                store.saveNow()
                let saved: Bool = await withCheckedContinuation { go in versions.save(note: "Ch 1: kept") { go.resume(returning: $0) } }
                check(saved && git("log", "-1", "--format=%s") == "Ch 1: kept", "versions: Save Version records a note")
                let again: Bool = await withCheckedContinuation { go in versions.save(note: "nothing") { go.resume(returning: $0) } }
                check(!again && git("log", "-1", "--format=%s") == "Ch 1: kept", "versions: nothing changed, nothing recorded")
            }

            await idle()
            check(versions.nextDraftName == "Draft 1", "versions: the first draft is offered as Draft 1")
            let first: String? = await withCheckedContinuation { go in versions.markDraft(name: "Draft 1", note: "") { go.resume(returning: $0) } }
            let twice: String? = await withCheckedContinuation { go in versions.markDraft(name: "Draft 1", note: "") { go.resume(returning: $0) } }
            let tags = git("tag", "--list")
            check(first == nil && twice == nil && tags.contains("draft-1") && tags.contains("draft-1-2"),
                  "versions: Mark as Draft names the version, and never reuses a name")
            await idle()
            check(versions.nextDraftName == "Draft 2", "versions: the next draft is offered as Draft 2")
            check(versions.recent.first?.drafts.contains("draft-1") == true, "versions: recent versions show their draft names")
            check(VersionStore.tagName("Sent to Agent, Nov") == "sent-to-agent-nov", "versions: draft names become tag names")
            check(GitHub.page(for: "https://spec-proj@github.com/spec-proj/novel.git") == "https://github.com/spec-proj/novel",
                  "versions: the GitHub page is worked out from the backup address")

            // A local stand-in for GitHub: a bare repository in a temporary folder.
            let remote = fm.temporaryDirectory.appendingPathComponent("LonghandRemote-\(UUID().uuidString).git")
            defer { try? fm.removeItem(at: remote) }
            Git.run(["init", "-q", "--bare", remote.path], in: fm.temporaryDirectory)
            Git.run(["remote", "add", "origin", remote.path], in: lib)
            versions.refresh()
            await idle()
            let sent: Bool = await withCheckedContinuation { go in versions.backUp { go.resume(returning: $0) } }
            let remoteHead = Git.run(["--git-dir", remote.path, "rev-parse", "main"], in: lib).output
            check(sent && remoteHead == git("rev-parse", "HEAD")
                  && Git.run(["--git-dir", remote.path, "tag", "--list"], in: lib).output.contains("draft-1"),
                  "versions: backing up sends every version and draft")

            if let scene = chapters().first?.scenes.first {
                store.selection = .scene(scene.url)
                store.updateText("Words written just before quitting.")
                NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
                check(git("log", "-1", "--format=%s").hasPrefix("Writing session, ")
                      && Git.run(["--git-dir", remote.path, "rev-parse", "main"], in: lib).output == git("rev-parse", "HEAD"),
                      "versions: quitting records a version and backs it up")
            }

            // MARK: Comparing versions, word by word
            let words = WordDiff.segments(from: "She walked out at low tide.", to: "She walked at low tide, slowly.")
            check(words.filter { $0.kind == .removed }.map(\.text) == ["out ", "tide."]
                  && words.filter { $0.kind == .added }.map(\.text) == ["tide, slowly."],
                  "compare: only the changed words are marked")
            check(Git.isScene("01 Book/01 Chapter/01 Scene.md") && !Git.isScene("01 Book/Notes/Cast.md")
                  && !Git.isScene(".longhand/notes/01 Book/01 Chapter/01 Scene.md"),
                  "compare: only scenes are compared, not notes")

            if let chapter = chapters().first, chapter.scenes.count >= 2 {
                let baseline = git("rev-parse", "HEAD")
                let first = chapter.scenes[0], second = chapter.scenes[1]
                // Edit one scene, reorder (renames both files), add a scene: none saved as a version.
                store.selection = .scene(first.url)
                store.updateText("Changed words in the opening scene.")
                store.saveNow()
                store.placeScene(second.url, inChapter: chapter.url, at: 0)
                store.selection = .chapter(chapter.url)
                store.createSceneInContext()
                if case .scene = store.selection { store.updateText("A brand new scene.") }
                store.saveNow()
                let stagedBefore = git("diff", "--cached", "--name-only")
                let result = Git.compare(lib, from: baseline, to: nil)
                let paths = result.scenes.map(\.path)
                check(result.scenes.contains { $0.status == .added && $0.wordsAdded == 4 },
                      "compare: a new scene is found, even before it's in a version")
                check(result.scenes.contains { $0.status == .changed && $0.wordsAdded == 6 && $0.wordsRemoved > 0 },
                      "compare: an edited scene shows the words added and removed")
                check(!result.scenes.contains { $0.status == .removed } && Set(paths).count == paths.count,
                      "compare: reordered (renamed) scenes are followed, not shown as removed")
                check(git("diff", "--cached", "--name-only") == stagedBefore && git("rev-parse", "HEAD") == baseline,
                      "compare: comparing with now changes nothing in the repository")
                let built = CompareText.build(result.scenes)
                check(!built.added.isEmpty && !built.removed.isEmpty && built.headings.count == result.scenes.count,
                      "compare: the page marks added and removed words under each scene's heading")

                versions.save(note: "After reordering")
                await idle()
                let saved = Git.compare(lib, from: baseline, to: git("rev-parse", "HEAD"))
                check(saved.scenes.map(\.path) == result.scenes.map(\.path) && saved.wordsAdded == result.wordsAdded,
                      "compare: two saved versions compare the same as a version and now")
                store.compareVersions()
                await idle()
                check(versions.comparing && versions.compareFrom != nil && versions.comparison != nil,
                      "compare: Compare Versions opens from the latest draft")
                store.selection = .chapter(chapter.url)
                check(!versions.comparing, "compare: choosing something in the contents closes the comparison")

                // MARK: Restoring from a comparison
                // A scene whose file is where it was in the baseline (reordering renamed some).
                if let scene = chapters().flatMap(\.scenes).first(where: {
                    Git.run(["cat-file", "-e", "\(baseline):\(String($0.url.path.dropFirst(lib.path.count + 1)))"], in: lib).ok
                }) {
                    let path = String(scene.url.path.dropFirst(lib.path.count + 1))
                    let then = Git.show(lib, baseline, path)
                    store.selection = .scene(scene.url)
                    store.updateText("Words that will be replaced.")
                    store.saveNow()
                    store.compareVersions()
                    await idle()
                    versions.compare(from: baseline, to: nil)
                    await idle()
                    if let change = versions.comparison?.scenes.first(where: { $0.path == path }) {
                        store.restoreScene(change)
                        await idle()
                        check(disk(scene.url) == then && store.text == then, "restore: a scene goes back to the older version, on disk and on screen")
                        check(store.history.versions(of: scene.url).contains { store.history.text(of: $0) == "Words that will be replaced." },
                              "restore: the replaced text is kept in the scene's History")
                    } else {
                        check(false, "restore: the edited scene is in the comparison")
                    }
                } else {
                    check(false, "restore: a scene from the older version exists")
                }

                store.selection = .chapter(chapter.url)
                store.createSceneInContext()
                if case .scene = store.selection { store.updateText("A scene that didn't exist then.") }
                store.saveNow()
                store.compareVersions()
                await idle()
                versions.compare(from: baseline, to: nil)
                await idle()
                let restored: Bool = await withCheckedContinuation { go in store.restoreLibrary { go.resume(returning: $0) } }
                await idle()
                let scenesNow = git("diff", "--name-only", baseline, "HEAD", "--", "*.md")
                    .split(separator: "\n").filter { Git.isScene(String($0)) }
                check(restored && scenesNow.isEmpty && git("log", "-1", "--format=%s").hasPrefix("Restored ")
                      && git("log", "-2", "--format=%s").contains("Before restoring "),
                      "restore: Restore All puts every scene back, after saving the present as a version")
                check(store.library?.books.first?.chapters.first?.scenes.contains { (try? String(contentsOf: $0.url, encoding: .utf8)) == "A scene that didn't exist then." } == false,
                      "restore: scenes written since are gone from the contents (and kept in the version before)")
            } else {
                check(false, "compare: a chapter with two scenes exists")
            }

            // MARK: Rewrites
            let all = chapters().flatMap(\.scenes)
            if all.count >= 2 {
                let a = all[0].url, b = all[1].url
                func write(_ url: URL, _ text: String) {
                    store.selection = .scene(url)
                    store.updateText(text)
                    store.saveNow()
                }
                let original = "Para one.\n\nPara two.\n\nPara three.\n"
                let rewritten = "Para one.\n\nPara two, in first person.\n\nPara three.\n"
                write(a, original)
                write(b, "B original.\n")
                store.startRewrite(title: "First person")
                check(versions.currentRewrite?.title == "First person" && git("symbolic-ref", "--short", "HEAD") == "rewrite/first-person",
                      "rewrites: starting one moves onto it")
                write(a, rewritten)
                store.switchTo(nil)
                check(versions.currentRewrite == nil && disk(a) == original && store.text == original,
                      "rewrites: back on the manuscript, its text is as it was, on disk and on screen")
                write(b, "B changed in the manuscript.\n")
                store.switchTo(versions.rewrites.first)
                check(disk(a) == rewritten && disk(b) == "B original.\n", "rewrites: switching back shows the rewrite's text")
                store.keepRewrite()
                check(versions.mergePlan == nil && versions.currentRewrite == nil && versions.rewrites.isEmpty
                      && disk(a) == rewritten && disk(b) == "B changed in the manuscript.\n"
                      && git("rev-list", "--parents", "-n", "1", "HEAD").split(separator: " ").count == 3,
                      "rewrites: keeping one with no overlap brings both sets of changes into the manuscript")

                store.startRewrite(title: "Second try")
                write(a, "Para one.\n\nPara two, rewrite side.\n\nPara three.\n")
                store.switchTo(nil)
                write(a, "Para one.\n\nPara two, manuscript side.\n\nPara three.\n")
                store.switchTo(versions.rewrites.first)
                store.keepRewrite()
                let plan = versions.mergePlan
                check(plan?.passages.count == 1 && plan?.passages.first?.manuscript.contains("manuscript side") == true
                      && plan?.passages.first?.rewrite.contains("rewrite side") == true
                      && !disk(a).contains("<<<<<<<") && versions.currentRewrite != nil,
                      "rewrites: a paragraph changed on both sides is offered as a choice; the files never hold conflict marks")
                if var plan {
                    plan.passages[0].choice = .both
                    store.finishKeep(plan)
                    check(disk(a) == "Para one.\n\nPara two, manuscript side.\n\nPara two, rewrite side.\n\nPara three.\n"
                          && versions.currentRewrite == nil && versions.mergePlan == nil,
                          "rewrites: choosing Both keeps the manuscript's paragraph, then the rewrite's")
                }

                let kept = disk(a)
                store.startRewrite(title: "Throwaway")
                write(a, "Gone soon.\n")
                store.discardRewrite()
                check(versions.currentRewrite == nil && disk(a) == kept && versions.rewrites.isEmpty
                      && Git.branchTips(lib).contains { $0.title == "Discarded rewrite “Throwaway”" },
                      "rewrites: discarding goes back to the manuscript and keeps the rewrite by name")
                if let chapterURL = store.location(ofScene: a)?.chapter.url {
                    store.startRewrite(title: "Chapter check")
                    write(a, "Chapter page text in the rewrite.\n")
                    store.selection = .chapter(chapterURL)
                    await settle(500)
                    store.switchTo(nil)
                    await settle(500)
                    let onManuscript = chapterPage()?.string ?? ""
                    store.switchTo(versions.rewrites.first)
                    await settle(500)
                    let onRewrite = chapterPage()?.string ?? ""
                    check(onManuscript.contains("manuscript side") && !onManuscript.contains("Chapter page text in the rewrite")
                          && onRewrite.contains("Chapter page text in the rewrite"),
                          "rewrites: the chapter page follows a switch")
                    store.discardRewrite()
                    await settle(300)
                }
                // MARK: Polish: a scene's history in the Versions tab, backup sign, accounts
                let scenePath = String(a.path.dropFirst(lib.path.count + 1))
                versions.scheduleChanges(after: 0)
                await settle(300)
                versions.waitUntilIdle()
                await settle(100)
                let sceneHistory = versions.changes.history(of: a)
                check(sceneHistory.count >= 3 && sceneHistory.contains { $0.note.contains("rewrite") },
                      "history: the scene's saved versions are listed, following it through rewrites")
                if let older = sceneHistory.last {
                    store.selection = .scene(a)
                    versions.openScene(scenePath, from: older.commit)
                    await idle()
                    check(versions.comparing && versions.detail?.path == scenePath && versions.compareFrom == older.commit,
                          "history: choosing a saved version compares the scene with it, ready to restore")
                    versions.comparing = false
                }
                let goodRemote = git("remote", "get-url", "origin")
                Git.run(["remote", "set-url", "origin", "/nonexistent/remote.git"], in: lib)
                let failed: Bool = await withCheckedContinuation { go in versions.backUp { go.resume(returning: $0) } }
                check(!failed && versions.backupFailed, "backup: a backup that doesn't get through is flagged")
                Git.run(["remote", "set-url", "origin", goodRemote], in: lib)
                let sentAgain: Bool = await withCheckedContinuation { go in versions.backUp { go.resume(returning: $0) } }
                check(sentAgain && !versions.backupFailed, "backup: the flag clears when a backup gets through")
                if GitHub.executable != nil {
                    check(!GitHub.accounts().isEmpty, "backup: the GitHub accounts on this Mac are found")
                }

                // MARK: Sync: automatic commits, push after commit, pull, divergence
                // Waits until syncing has been quiet for a while (a push refused, a pull and a
                // push again can take more than a second on a busy Mac; a fixed wait once let a
                // check run early, and the checks after it inherited the mess). At most ~10 s.
                func syncSettle() async {
                    var quiet = 0
                    for round in 0..<60 {
                        await settle(150)
                        versions.waitUntilIdle()
                        quiet = versions.sync.activity == .idle ? quiet + 1 : 0
                        if round >= 5 && quiet >= 4 { break }
                    }
                    await settle(100)
                }
                func remoteHead() -> String { Git.run(["--git-dir", goodRemote, "rev-parse", "main"], in: lib).output }
                await syncSettle()
                store.pullPause = 0
                defer { store.pullPause = 3 }
                store.selection = .scene(a)
                await idle()
                store.updateText("Auto-commit: the first line.\n\nA second paragraph.\n")
                store.saveNow()
                let autoCommitted: Bool = await withCheckedContinuation { go in versions.commitNow { go.resume(returning: $0) } }
                await syncSettle()
                check(autoCommitted && git("log", "-1", "--format=%s").hasPrefix("Auto-commit ")
                      && git("status", "--porcelain").isEmpty,
                      "sync: saved text is committed automatically")
                check(remoteHead() == git("rev-parse", "HEAD") && versions.sync.lastPush != nil && versions.sync.problem == nil,
                      "sync: an automatic commit is pushed without being asked")
                check(versions.sync.log.contains { $0.command.hasPrefix("git push") && $0.ok },
                      "sync: every push is in the Git Activity log")

                // A report from an editor still holding older text is dropped, never saved.
                let before = store.text
                store.updateText("Stale text from an editor that hasn't reloaded.", fromEditor: true, version: store.textVersion - 1)
                store.saveNow()
                check(store.text == before && (try? String(contentsOf: a, encoding: .utf8)) == before,
                      "editor: text from an editor that hasn't reloaded is never saved over the scene")

                // Another Mac: a clone that commits and pushes.
                let other = fm.temporaryDirectory.appendingPathComponent("LonghandOther-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: other) }
                Git.run(["clone", "-q", goodRemote, other.path], in: fm.temporaryDirectory)
                Git.run(["config", "user.email", "other@longhand.local"], in: other)
                Git.run(["config", "user.name", "Other Mac"], in: other)
                let otherA = other.appendingPathComponent(scenePath)
                func otherCommit(_ text: String, file: URL? = nil) {
                    try? text.write(to: file ?? otherA, atomically: true, encoding: .utf8)
                    Git.run(["add", "-A"], in: other)
                    Git.run(["commit", "-q", "-m", "From the other Mac"], in: other)
                    Git.run(["push", "-q", "origin", "main"], in: other)
                }
                otherCommit("Auto-commit: the first line.\n\nA second paragraph, changed on the other Mac.\n")
                await withCheckedContinuation { go in versions.syncNow { go.resume() } }
                await syncSettle()
                check(store.text.contains("changed on the other Mac") && versions.sync.behind == 0,
                      "sync: commits pushed from another Mac are pulled and shown")

                // Both Macs commit, in different paragraphs: this Mac's commit is replayed on top.
                Git.run(["pull", "-q"], in: other)
                otherCommit("Auto-commit: the first line.\n\nA second paragraph, changed twice on the other Mac.\n")
                store.updateText("Auto-commit: the first line, changed here.\n\nA second paragraph, changed on the other Mac.\n")
                store.saveNow()
                _ = await withCheckedContinuation { go in versions.commitNow { go.resume(returning: $0) } }
                await syncSettle()
                check(store.text.contains("changed here") && store.text.contains("changed twice")
                      && remoteHead() == git("rev-parse", "HEAD") && versions.sync.problem == nil,
                      "sync: commits on both Macs in different paragraphs are joined and pushed")

                // Both change the same line: nothing is touched, and Keep Both loses neither.
                Git.run(["pull", "-q"], in: other)
                otherCommit("Auto-commit: the first line, changed THERE.\n\nA second paragraph.\n")
                let mine = "Auto-commit: the first line, changed HERE again.\n\nA second paragraph.\n"
                store.updateText(mine)
                store.saveNow()
                _ = await withCheckedContinuation { go in versions.commitNow { go.resume(returning: $0) } }
                await syncSettle()
                check(versions.sync.problem == .diverged && store.text == mine
                      && !fm.fileExists(atPath: lib.appendingPathComponent(".git/rebase-merge").path)
                      && git("status", "--porcelain").isEmpty,
                      "sync: when both Macs change the same line, nothing is touched and it says Diverged")
                let keptBoth: Bool = await withCheckedContinuation { go in versions.keepBoth { go.resume(returning: $0) } }
                await syncSettle()
                let copy = versions.rewrites.first { $0.title.hasPrefix("Remote copy") }
                check(keptBoth && versions.sync.problem == nil && remoteHead() == git("rev-parse", "HEAD") && store.text == mine
                      && copy.map { git("show", "\($0.id):\(scenePath)").contains("changed THERE") } == true,
                      "sync: Keep Both pushes this Mac's commits and keeps the remote's as a branch")

                // Branches across Macs: one made on the other Mac appears here and is never
                // pruned by this Mac's push; one deleted here is deleted on the remote.
                func remoteBranches() -> String { Git.run(["--git-dir", goodRemote, "branch", "--list"], in: lib).output }
                Git.run(["pull", "-q"], in: other)
                Git.run(["switch", "-q", "-c", "rewrite/from-other"], in: other)
                otherCommit("Written on a branch on the other Mac.\n", file: other.appendingPathComponent("branch-note.md"))
                Git.run(["push", "-q", "origin", "rewrite/from-other"], in: other)
                Git.run(["switch", "-q", "main"], in: other)
                await withCheckedContinuation { go in versions.syncNow { go.resume() } }
                await syncSettle()
                check(versions.rewrites.contains { $0.id == "rewrite/from-other" },
                      "sync: a branch pushed from another Mac appears here")
                store.updateText(mine + "\nOne more line.\n")
                store.saveNow()
                _ = await withCheckedContinuation { go in versions.commitNow { go.resume(returning: $0) } }
                await syncSettle()
                check(remoteBranches().contains("rewrite/from-other") && remoteHead() == git("rev-parse", "HEAD"),
                      "sync: pushing never deletes a branch another Mac pushed")
                store.startRewrite(title: "Soon deleted")
                await syncSettle()
                let hadBranch = remoteBranches().contains("rewrite/soon-deleted")
                store.discardRewrite()
                await syncSettle()
                check(hadBranch && !remoteBranches().contains("rewrite/soon-deleted"),
                      "sync: a branch deleted here is deleted on the remote, by name")

                // A push the remote keeps rejecting is reported once, not retried for ever.
                Git.run(["switch", "-q", "rewrite/from-other"], in: other)
                otherCommit("Written twice on the other Mac's branch.\n", file: other.appendingPathComponent("branch-note.md"))
                Git.run(["push", "-q", "origin", "rewrite/from-other"], in: other)
                Git.run(["switch", "-q", "main"], in: other)
                let stray = git("commit-tree", "rewrite/from-other^{tree}", "-p", "rewrite/from-other", "-m", "Diverges from the other Mac")
                _ = git("branch", "-f", "rewrite/from-other", stray)
                _ = await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in versions.pushNow { go.resume(returning: $0) } }
                await syncSettle()
                let pushes = versions.sync.log.filter { $0.command.hasPrefix("git push --all") }.count
                await syncSettle()
                var reported = false
                if case .other(let message) = versions.sync.problem { reported = message.contains("rejected") }
                check(reported && versions.sync.log.filter { $0.command.hasPrefix("git push --all") }.count == pushes,
                      "sync: a push that stays rejected is reported, not retried in a loop")
                _ = git("branch", "-f", "rewrite/from-other", "refs/remotes/origin/rewrite/from-other")
                _ = await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in versions.pushNow { go.resume(returning: $0) } }
                await syncSettle()
                check(versions.sync.problem == nil, "sync: the report clears once a push goes through")
                check(Git.parseConflicts("a\n<<<<<<< x\nb\n=======\nc\n>>>>>>> y\nd\n", startingAt: 0).passages.map(\.rewrite) == ["c\n"],
                      "rewrites: Git's conflict marks are read into passages")
            } else {
                check(false, "rewrites: two scenes exist")
            }
        } else {
            check(false, "versions: a library is open")
        }

        // MARK: Focus

        do {
            let text = "One sentence. Two here! Three?\nNext paragraph.\n\nLast." as NSString
            func kept(_ location: Int, _ length: Int = 0, _ unit: WritingModes.Unit) -> String {
                text.substring(with: WritingModes.focusRange(in: text, selection: NSRange(location: location, length: length), unit: unit))
            }
            check(kept(16, 0, .sentence) == "Two here! ", "focus: the caret's sentence stays bright")
            check(kept(30, 0, .sentence) == "Three?", "focus: at the end of a paragraph, its last sentence")
            check(kept(3, 0, .paragraph) == "One sentence. Two here! Three?", "focus: the caret's paragraph, without its newline")
            check(!kept(47, 0, .sentence).isEmpty, "focus: an empty line keeps the sentence above it bright")
            check(WritingModes.shift(NSRange(location: 10, length: 5), by: NSRange(location: 2, length: 3), delta: 3) == NSRange(location: 13, length: 5)
                  && WritingModes.shift(NSRange(location: 10, length: 5), by: NSRange(location: 12, length: 1), delta: 1) == NSRange(location: 10, length: 6)
                  && WritingModes.shift(NSRange(location: 10, length: 5), by: NSRange(location: 20, length: 0), delta: -2) == NSRange(location: 10, length: 5),
                  "focus: the bright passage moves with edits before and inside it")
            check(kept(0, 31, .paragraph) == "One sentence. Two here! Three?",
                  "focus: a selected line (ending at the next line's start) keeps only that line bright")
            let quote = "> Come when the water is out." as NSString
            let marks = [NSTextCheckingResult.spellCheckingResult(range: NSRange(location: 0, length: 1)),
                         NSTextCheckingResult.spellCheckingResult(range: NSRange(location: 2, length: 4))]
            check(ProofingFilter.filter(marks, in: quote).map(\.range) == [NSRange(location: 2, length: 4)],
                  "proofing: no spelling mark on a quote's > symbol, words still checked")
            check(kept(3, 30, .paragraph) == "One sentence. Two here! Three?\nNext paragraph.", "focus: a selection keeps every paragraph it touches")
        }

        // MARK: Running commands

        do {
            let echo = Process.captureData("/bin/cat", [], in: root, timeout: 5, input: Data("piped in".utf8))
            check(echo.status == 0 && String(decoding: echo.output, as: UTF8.self) == "piped in",
                  "commands: input goes in and output comes back")
            let failing = Process.capture("/bin/sh", ["-c", "echo oops >&2; exit 3"], in: root, timeout: 5)
            check(failing.status == 3 && failing.error == "oops", "commands: a failure's status and message come back")
            let started = Date()
            let stuck = Process.capture("/bin/sh", ["-c", "sleep 30 & sleep 30"], in: root, timeout: 0.5)
            check(stuck.status == -1 && Date().timeIntervalSince(started) < 3,
                  "commands: a command that runs too long is stopped, with anything it started")
        }

        // MARK: Branch listing (one Git call for every branch and the open one)

        do {
            let repo = root.appendingPathComponent("branch-check")
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            Git.run(["init", "-q", "-b", "main"], in: repo)
            Git.run(["-c", "user.email=t@longhand.local", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "a"], in: repo)
            Git.run(["branch", "rewrite/alpha"], in: repo)
            Git.run(["config", "--local", "branch.rewrite/alpha.description", "Alpha draft"], in: repo)
            let state = Git.branchState(repo)
            check(state.current == "main" && state.rewrites.map(\.title) == ["Alpha draft"] && state.rewrites.first?.id == "rewrite/alpha",
                  "rewrites: the open branch and every rewrite's title come from one listing")
        }

        // MARK: TextKit 2, and focus on a live page

        if let scene = chapters().last?.scenes.first {
            let defaults = UserDefaults.standard
            let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(saved.merging([WritingModes.focusKey: true, WritingModes.unitKey: "sentence"]) { $1 },
                                       forName: UserDefaults.argumentDomain)
            store.selection = .scene(scene.url)
            await settle()
            if let page = store.margin.textView {
                check(page.textLayoutManager != nil, "editor: on TextKit 2 (anything touching layoutManager would switch it back)")
                page.window?.makeFirstResponder(page)
                page.setSelectedRange(NSRange(location: 0, length: (page.string as NSString).length))
                page.insertText("First sentence here. Second one", replacementRange: page.selectedRange())
                await settle(100)
                func dimmed(_ offset: Int) -> Bool {
                    guard let bright = (page as? HighlightTextView)?.focusBright else { return false }
                    return !(offset >= bright.location && offset < NSMaxRange(bright))
                }
                check(dimmed(2) && !dimmed(25), "focus: on the page, the other sentence is dimmed and the one being typed is not")
            }
            defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
            await settle(100)
        }

        // MARK: Changes since the last version

        do {
            // Lines compared with the last version: an edit, a cut, an addition.
            let bars = ChangeBars.bars(old: "One line.\nKept.\nTwo line.\nThree line.\n", new: "One line, changed.\nKept.\nThree line.\nFour line.\n")
            check(bars.map(\.kind) == [.changed, .removed, .added],
                  "changes: lines compared with the last version give edited, cut and added bars")
            check(bars.first?.oldText == "One line.\n" && bars.dropFirst().first?.oldText.hasPrefix("Two line.") == true,
                  "changes: each bar keeps the lines as they were")
            check(ChangeBars.bars(old: "A\n\nB", new: "A\n\n\nB").isEmpty, "changes: blank lines alone make no bar")
            let segments = WordDiff.segments(from: "The sand was cold.\nGulls.\n", to: "The sand was warm.\nGulls, and a piano.\n")
            let change = Comparison.SceneChange(path: "a/b/c.md", oldPath: nil, status: .changed, segments: segments, wordsAdded: 0, wordsRemoved: 0)
            check(change.olderText == "The sand was cold.\nGulls.\n", "changes: the last version's text is rebuilt exactly from a comparison")
        }

        if let scene = chapters().last?.scenes.first {
            let versions = store.versions
            store.saveNow()
            _ = await withCheckedContinuation { go in versions.save(note: "Before changes") { go.resume(returning: $0) } }
            versions.scheduleChanges(after: 0)
            await settle(300)
            versions.waitUntilIdle()
            await settle(100)
            store.selection = .scene(scene.url)
            await settle(300)
            check(versions.changes.marks[scene.url] == nil, "changes: a scene unchanged since the last version has no mark")
            if let page = store.margin.textView as? HighlightTextView {
                // Written to the file and read again rather than typed: a hidden run has no
                // clicks to end the typing's undo step, so Put Back would share it.
                let original = page.string
                try? (original + "\n\nA paragraph written after the last version.").write(to: scene.url, atomically: true, encoding: .utf8)
                if let other = chapters().first?.scenes.first, other.url != scene.url {
                    store.selection = .scene(other.url)
                    await settle(150)
                }
                store.selection = .scene(scene.url)
                await settle(200)
                check(store.margin.textView === page && page.string.hasSuffix("after the last version."),
                      "changes: (the same page, with the paragraph read from the file)")
                page.window?.makeFirstResponder(page)
                versions.scheduleChanges(after: 0)
                await settle(300)
                versions.waitUntilIdle()
                await settle(600)
                check(versions.changes.marks[scene.url] == .changed && versions.changes.count == 1,
                      "changes: an edited scene is marked in the contents and counted")
                check(versions.changes.chapterMarks.contains(scene.url.deletingLastPathComponent().canonical),
                      "changes: its chapter is marked too")
                let added = page.changeBars.first { $0.kind == .added }
                check(added != nil, "changes: the new paragraph has a bar on the page")
                if let added {
                    store.margin.putBack(added)
                    await settle(100)
                    check((page.string as NSString).isEqual(to: original), "changes: Remove takes the paragraph out again")
                    page.undoManager?.undo()
                    await settle(100)
                    check(page.string.hasSuffix("after the last version."), "changes: Undo brings it back")
                }
                await settle(200)
                store.saveNow()
                let onDisk = (try? String(contentsOf: scene.url, encoding: .utf8)) ?? ""
                check(onDisk.hasSuffix("after the last version."), "changes: what Undo brings back is saved")
                _ = await withCheckedContinuation { go in versions.save(note: "After changes") { go.resume(returning: $0) } }
                await settle(300)
                versions.waitUntilIdle()
                await settle(400)
                check(versions.changes.scenes.isEmpty && versions.changes.marks.isEmpty,
                      "changes: saving a version clears the marks")
                await settle(500)
                check(page.changeBars.isEmpty, "changes: and the bars on the page")

                // Versions belong to scenes: numbered per scene, quitting isn't one, and a
                // renamed scene keeps its history.
                let history = versions.changes.history(of: scene.url)
                let numbers = history.compactMap(\.number)
                check(!numbers.isEmpty && numbers == Array((1...numbers.count).reversed()),
                      "versions: a scene's versions are numbered v1, v2 … in its own order")
                check(history.first?.note == "After changes", "versions: the latest version carries its note")
                let before = versions.changes.lastVersion(of: scene.url)?.number
                page.setSelectedRange(NSRange(location: (page.string as NSString).length, length: 0))
                page.insertText(" One more line.", replacementRange: page.selectedRange())
                await settle(150)
                store.saveNow()
                // Quitting the way the app does now: in the background, saying when it pushes.
                let headBefore = Git.run(["rev-parse", "HEAD"], in: versions.root!).output
                var reportedStage = false
                await withCheckedContinuation { go in
                    versions.endSessionInBackground(words: 0, stage: { _ in reportedStage = true }, done: { go.resume() })
                }
                let headAfter = Git.run(["rev-parse", "HEAD"], in: versions.root!).output
                versions.endSession(words: 0)
                check(reportedStage && headAfter != headBefore && Git.run(["status", "--porcelain"], in: versions.root!).output.isEmpty
                      && Git.run(["rev-parse", "HEAD"], in: versions.root!).output == headAfter,
                      "quit: commits in the background, says when it pushes, and the exit doesn't commit again")
                versions.resumeSession()
                versions.scheduleChanges(after: 0)
                await settle(300)
                versions.waitUntilIdle()
                await settle(400)
                check(versions.changes.lastVersion(of: scene.url)?.number == before && versions.changes.change(of: scene.url) != nil
                      && versions.changes.history(of: scene.url).first?.kind == .automatic,
                      "versions: quitting keeps a copy but makes no version; the scene still shows its changes")
                let title = scene.title
                store.rename(ManuscriptItem(url: scene.url, title: title, order: scene.order, kind: .scene), to: title + " Renamed")
                await settle(300)
                versions.scheduleChanges(after: 0)
                await settle(300)
                versions.waitUntilIdle()
                await settle(400)
                if case .scene(let renamed) = store.selection {
                    check(versions.changes.lastVersion(of: renamed)?.number == before,
                          "versions: a renamed scene keeps its versions")
                } else {
                    check(false, "versions: a renamed scene keeps its versions (no scene open)")
                }
            } else {
                check(false, "changes: the scene editor is on screen")
            }
        }

        // MARK: Focus: sentences and blank lines

        do {
            let text = "Mr. Utterson the lawyer was a man. Dr. Jekyll was not.\n\nA second paragraph." as NSString
            let first = WritingModes.focusRange(in: text, selection: NSRange(location: 0, length: 0), unit: .sentence)
            check(text.substring(with: first) == "Mr. Utterson the lawyer was a man. ",
                  "focus: “Mr.” doesn’t end the sentence")
            let second = WritingModes.focusRange(in: text, selection: NSRange(location: 40, length: 0), unit: .sentence)
            check(text.substring(with: second) == "Dr. Jekyll was not.", "focus: nor does “Dr.”")
            let blank = WritingModes.focusRange(in: text, selection: NSRange(location: 55, length: 0), unit: .paragraph)
            check(text.substring(with: blank).hasPrefix("Mr. Utterson"), "focus: a blank line keeps the paragraph above bright")
        }

        // MARK: Book Info: details and cover

        if let book = store.library?.books.first {
            var info = store.margin.info(for: book.url)
            info.stage = .writing
            info.form = .novella
            info.genre = "Crime"
            info.authorEmail = "writer@example.com"
            info.hideChapterNumbers = true
            store.margin.setInfo(info, for: book.url)
            let data = try? JSONEncoder().encode(info)
            let back = data.flatMap { try? JSONDecoder().decode(SceneInfo.self, from: $0) }
            check(back?.stage == .writing && back?.form == .novella && back?.genre == "Crime"
                  && back?.authorEmail == "writer@example.com" && back?.hideChapterNumbers == true,
                  "book info: stage, form, genre, author and chapter numbers are kept")
            check(Genres.all(for: .screenplay).contains("Science Fiction")
                  && !Genres.all(for: .screenplay).contains("Literary")
                  && Genres.all(for: .novel).contains("Literary")
                  && Genres.all(for: nil) == Genres.all(for: .novel),
                  "genres: a screenplay gets the movie list, a novel the book trade’s")
            check(Genres.all(for: .novella) == Genres.all(for: .novel) && Genres.all(for: .shortStory) == Genres.all(for: .novel),
                  "genres: novels, novellas and short stories share the book trade’s list")
            let ownLists = BookForm.allCases.filter { ![.novel, .novella, .shortStory].contains($0) }.map { Genres.all(for: $0) }
            check(ownLists.allSatisfy { $0 != Genres.all(for: .novel) && Set($0).count == $0.count && !$0.isEmpty },
                  "genres: poetry, lyrics, essays, screenplays and notebooks each have a list of their own, with no repeats")
            check(Genres.all(for: .notebook).contains("Diary") && Genres.all(for: .poetry).contains("Sonnet")
                  && Genres.all(for: .lyrics).contains("Hip-Hop & Rap") && Genres.all(for: .essay).contains("Memoir"),
                  "genres: a notebook offers Diary, poetry Sonnet, lyrics Hip-Hop, essays Memoir")
            check(BookForm.allCases.filter { Genres.label(for: $0) == "Type" } == [.poetry, .essay, .notebook]
                  && Genres.label(for: nil) == "Genre",
                  "genres: the menu is called Type where the choices are kinds, Genre elsewhere")
            // MARK: Contents on a story's page, by form (issue #8)
            check(ContentsKind.of(form: .novel, shape: .chaptersAndScenes) == .chapters
                  && ContentsKind.of(form: .shortStory, shape: .chapters) == .chapters
                  && ContentsKind.of(form: .screenplay, shape: .document) == .chapters,
                  "contents: novels, collections with chapters and screenplays keep the chapter list")
            check(ContentsKind.of(form: .poetry, shape: .document) == .poem && ContentsKind.of(form: .lyrics, shape: .document) == .poem
                  && ContentsKind.of(form: .poetry, shape: .scenes) == .poems && ContentsKind.of(form: .lyrics, shape: .scenes) == .poems,
                  "contents: one poem or song shows itself, a book of them lists each")
            check(ContentsKind.of(form: .shortStory, shape: .document) == .headings && ContentsKind.of(form: .essay, shape: .document) == .headings
                  && ContentsKind.of(form: .notebook, shape: .document) == .headings,
                  "contents: a single story, essay or note lists its headings")
            let essay = DocumentSummary(text: "# Title\n\nA long opening paragraph " + String(repeating: "word ", count: 300)
                                        + "\n\n## Departure\n\n" + String(repeating: "word ", count: 600)
                                        + "\n\n### Midnight\n\nShort.\n\n## Arrival\n\nEnd.\n")
            check(essay.headings.map(\.title) == ["Departure", "Midnight", "Arrival"] && essay.headings.map(\.level) == [2, 3, 2],
                  "contents: a document's headings are listed, its title is not")
            check(essay.headings.map(\.id) == [1, 2, 3], "contents: each heading keeps its place in the outline, for jumping to it")
            check(essay.headings.map(\.page) == [2, 4, 4], "contents: headings fall on the page their words reach (250 words a page)")
            let headless = DocumentSummary(text: "# Salt\n\nShe set her suitcase down.\n\n***\n\nThe second thing was the salt.\n")
            check(headless.headings.isEmpty && headless.opening == "She set her suitcase down.\n\nThe second thing was the salt.",
                  "contents: with no headings, the opening is the first paragraphs (a short one takes the next), not a break")
            let verse = DocumentSummary(text: "# Tide\n\nThe ferryman's wife\n    kept the tables\n\neach *low water*\n")
            check(verse.body == "The ferryman's wife\n    kept the tables\n\neach *low water*", "contents: a poem keeps its lines and indents, without its title")
            var shown = SceneInfo()
            shown.setShows(.reading, false)
            let factsBack = (try? JSONEncoder().encode(shown)).flatMap { try? JSONDecoder().decode(SceneInfo.self, from: $0) }
            check(factsBack?.shows(.reading) == false && factsBack?.shows(.words) == true && !shown.isEmpty,
                  "story page: a figure turned off stays off, the others on")
            shown.setShows(.reading, true)
            check(shown.isEmpty, "story page: turning it back on leaves nothing stored")

            // A chapter's status is kept and read back when the library is read again.
            if let chapter = store.library?.books.flatMap(\.chapters).first {
                var status = store.margin.info(for: chapter.url)
                status.status = .revised
                store.margin.setInfo(status, for: chapter.url)
                store.margin.saveNow()
                store.refreshFromDisk()
                check(store.margin.info(for: chapter.url).status == .revised, "a chapter's status survives re-reading the library")
                status.status = nil
                store.margin.setInfo(status, for: chapter.url)
            }

            // An e-book: a zip with mimetype first, the chapters, and well-formed pages.
            let epub = FileManager.default.temporaryDirectory.appendingPathComponent("longhand-test-\(UUID().uuidString).epub")
            let noted = ManuscriptBuilder.make(title: "A & B", chapters: [(title: "Fog", scenes: [(title: "A", text: "One[^n].\n\n[^n]: A note.")])], words: 1)
            do {
                try EPUBWriter.write(noted, settings: ExportSettings(), details: .init(synopsis: "S"), to: epub)
                let data = (try? Data(contentsOf: epub)) ?? Data()
                let head = String(decoding: data.prefix(60), as: UTF8.self)
                check(head.hasPrefix("PK") && head.contains("mimetypeapplication/epub+zip"), "e-book: mimetype comes first, uncompressed")
            } catch {
                check(false, "e-book: writes (\(error))")
            }
            try? FileManager.default.removeItem(at: epub)

            // Plain Git: connecting to any remote pushes everything; a remote holding other
            // work is refused, and the library is left without a half-made connection.
            do {
                let fm = FileManager.default
                let base = fm.temporaryDirectory.appendingPathComponent("longhand-remote-\(UUID().uuidString)")
                let lib = base.appendingPathComponent("lib"), empty = base.appendingPathComponent("empty.git"),
                    other = base.appendingPathComponent("other.git"), seed = base.appendingPathComponent("seed")
                for dir in [lib, seed] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                let who = ["-c", "user.name=T", "-c", "user.email=t@longhand.local"]
                Git.run(["init", "-q", "-b", "main"], in: lib)
                try? "One.".write(to: lib.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
                Git.run(["add", "-A"], in: lib); Git.run(who + ["commit", "-q", "-m", "a"], in: lib)
                Git.run(["init", "-q", "--bare", empty.path], in: base)
                Git.run(["init", "-q", "--bare", other.path], in: base)
                Git.run(["init", "-q", "-b", "main"], in: seed)
                try? "Other.".write(to: seed.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
                Git.run(["add", "-A"], in: seed); Git.run(who + ["commit", "-q", "-m", "b"], in: seed)
                Git.run(["push", "-q", other.path, "main"], in: seed)

                check(Git.connect(lib, to: "  ") != nil, "remote: an empty address is refused")
                check(Git.connect(lib, to: base.appendingPathComponent("nowhere.git").path) != nil && Git.remoteURL(lib) == nil,
                      "remote: an address that can't be reached is refused, nothing connected")
                check(Git.connect(lib, to: other.path) != nil && Git.remoteURL(lib) == nil,
                      "remote: a remote holding other work is refused, and the library is left unconnected")
                let connected = Git.connect(lib, to: empty.path)
                check(connected == nil && Git.remoteURL(lib) == empty.path
                      && Git.run(["rev-parse", "main"], in: empty).output == Git.run(["rev-parse", "HEAD"], in: lib).output,
                      "remote: an empty remote is connected and receives every commit")
                // A folder on this Mac or a drive: the repository is made there, then used again.
                let lib2 = base.appendingPathComponent("lib2"), drive = base.appendingPathComponent("Drive")
                for dir in [lib2, drive] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                Git.run(["init", "-q", "-b", "main"], in: lib2)
                try? "Two.".write(to: lib2.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
                Git.run(["add", "-A"], in: lib2); Git.run(who + ["commit", "-q", "-m", "a"], in: lib2)
                let made = Git.folderRemote(in: drive, named: "lib2")
                check(made.path != nil && Git.connect(lib2, to: made.path ?? "") == nil
                      && Git.run(["rev-parse", "main"], in: drive.appendingPathComponent("lib2.git")).output
                         == Git.run(["rev-parse", "HEAD"], in: lib2).output,
                      "remote: a folder on a drive gets a repository, which receives every commit")
                try? fm.createDirectory(at: drive.appendingPathComponent("plain.git"), withIntermediateDirectories: true)
                check(Git.folderRemote(in: drive, named: "plain").path == nil,
                      "remote: a folder that isn't a repository is never used")
                check(Git.repositoryName(of: "git@example.com:me/My Novel.git") == "My Novel"
                      && Git.repositoryName(of: "https://host.org/me/novel/") == "novel",
                      "remote: a clone's folder is named after the repository")
                try? fm.removeItem(at: base)
            }

            // The story page's contents: each chapter starts on a fresh page, 250 words a page.
            check(Estimate.startPages([600, 0, 250, 10]) == [1, 4, 5, 6],
                  "story page: chapters start on estimated pages (a fresh page each, 250 words a page)")

            // A story with no cover picture: the e-book has the lettered cover chosen, or none.
            if let book = store.library?.books.first, store.margin.cover(of: book.url) == nil {
                var lettered = ExportSettings()
                lettered.format = .epub
                check(Exporter.cover(of: book, store: store, settings: lettered) == nil,
                      "e-book: no cover picture and no lettered cover chosen gives no cover")
                lettered.letteredCover = .shelf
                let rep = Exporter.cover(of: book, store: store, settings: lettered)?.representations.first as? NSBitmapImageRep
                check(rep?.pixelsWide == 1600 && rep?.pixelsHigh == 2560,
                      "e-book: the chosen lettered cover is drawn at 1600 by 2560")
                let saved = (try? JSONEncoder().encode(lettered)).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) }
                check(saved?.letteredCover == .shelf, "e-book: the chosen lettered cover is remembered")
                // The book PDF takes it as a page before the title page.
                let plainPDF = FileManager.default.temporaryDirectory.appendingPathComponent("longhand-test-\(UUID().uuidString).pdf")
                let coverPDF = FileManager.default.temporaryDirectory.appendingPathComponent("longhand-test-\(UUID().uuidString).pdf")
                let short = ManuscriptBuilder.make(title: "T", chapters: [(title: "Fog", scenes: [(title: "A", text: "One.")])], words: 1)
                try? BookWriter.write(short, settings: ExportSettings(), to: plainPDF)
                try? BookWriter.write(short, settings: ExportSettings(), lettered: (.frame, .init(title: "T", author: "A", form: "a novel")), to: coverPDF)
                let plainPages = PDFDocument(url: plainPDF)?.pageCount ?? 0, coverPages = PDFDocument(url: coverPDF)?.pageCount ?? 0
                check(plainPages > 0 && coverPages == plainPages + 1, "book PDF: a lettered cover is a page of its own before the title page")
                try? FileManager.default.removeItem(at: plainPDF)
                try? FileManager.default.removeItem(at: coverPDF)
            }

            // Numbers off: the export's chapters carry no "Chapter 1" line.
            let plain = ManuscriptBuilder.make(title: "T", chapters: [(title: "Fog", scenes: [(title: "A", text: "One.")])],
                                               words: 1, numbered: false)
            let numbered = ManuscriptBuilder.make(title: "T", chapters: [(title: "1", scenes: [(title: "A", text: "One.")])], words: 1)
            check(plain.chapters.first?.label == nil && plain.chapters.first?.heading == "Fog"
                  && numbered.chapters.first?.label == "Chapter 1" && numbered.chapters.first?.heading == nil,
                  "export: chapter numbers only when the story's numbers are on")

            let older = try? JSONDecoder().decode(SceneInfo.self, from: Data(#"{"stage":"manuscript"}"#.utf8))
            check(older?.stage == .final, "book info: a book saved as Manuscript reads as Final")
            let staged = ["draft": BookStage.writing, "drafted": .draft, "idea": .sketch, "sketch": .sketch, "manuscript": .final]
            check(staged.allSatisfy { name, stage in
                      (try? JSONDecoder().decode(SceneInfo.self, from: Data(#"{"stage":"\#(name)"}"#.utf8)))?.stage == stage }
                  && BookStage.allCases.map(\.title) == ["Sketch", "Writing", "Draft", "Final"]
                  && BookStage.allCases.allSatisfy { stage in
                      (try? JSONDecoder().decode(BookStage.self, from: JSONEncoder().encode(stage))) == stage },
                  "stages: Sketch, Writing, Draft, Final; a story saved as Idea reads as Sketch, older names keep their meaning")

            // The author moves from the old export choices to Book Info, once.
            var cleared = store.margin.info(for: book.url)
            cleared.authorEmail = nil
            store.margin.setInfo(cleared, for: book.url)
            let exportFile = (store.libraryURL ?? fm.temporaryDirectory).appendingPathComponent(".longhand/export.json")
            try? Data(#"{"format":"manuscriptPDF","name":"Old Name","penName":"O. N.","contact":"1 Old Road\nold@example.com"}"#.utf8)
                .write(to: exportFile)
            store.adoptExportAuthor()
            let moved = store.margin.info(for: book.url)
            let left = (try? String(contentsOf: exportFile, encoding: .utf8)) ?? ""
            check(moved.authorName == "Old Name" && moved.authorPenName == "O. N." && moved.authorAddress == "1 Old Road\nold@example.com"
                  && !left.contains("Old Name") && store.loadExportSettings().format == .manuscriptPDF,
                  "author: the old export details move to Book Info, and the export choices stay")
            var filled = ExportSettings()
            var details = SceneInfo()
            details.authorName = "Test Writer"
            details.authorAddress = "1 Test Street"
            details.authorEmail = "test@example.com"
            details.authorPhone = "555 0100"
            filled.useAuthor(details)
            check(filled.byline == "Test Writer" && filled.contact == "1 Test Street\n555 0100\ntest@example.com",
                  "author: the title page takes its name and contact block from Book Info")
            let picture = fm.temporaryDirectory.appendingPathComponent("longhand-cover-\(UUID().uuidString).png")
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 900, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: picture)
            }
            let set = store.margin.setCover(of: book.url, from: picture)
            let saved = store.margin.coverURL(for: book.url).flatMap { NSBitmapImageRep(data: (try? Data(contentsOf: $0)) ?? Data()) }
            check(set && saved.map { abs(Double($0.pixelsHigh) / Double($0.pixelsWide) - 1.6) < 0.01 } == true,
                  "book info: a cover is cropped to the Kindle shape (1:1.6)")
            store.margin.removeCover(of: book.url)
            check(store.margin.cover(of: book.url) == nil, "book info: a cover can be removed")
            try? fm.removeItem(at: picture)
            info.hideChapterNumbers = nil
            store.margin.setInfo(info, for: book.url)
        }

        // MARK: Bold and italic (⌘B, ⌘I)

        do {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
            view.string = "She walked out at low tide."
            view.setSelectedRange(NSRange(location: 4, length: 6))
            MarkdownFormat.toggle(.bold, in: view)
            check(view.string == "She **walked** out at low tide.", "format: ⌘B wraps the selection in **")
            MarkdownFormat.toggle(.bold, in: view)
            check(view.string == "She walked out at low tide.", "format: ⌘B again takes them off")
            view.setSelectedRange(NSRange(location: 22, length: 0))
            MarkdownFormat.toggle(.italic, in: view)
            check(view.string == "She walked out at low *tide*.", "format: ⌘I with no selection does the word at the caret")
            view.setSelectedRange(NSRange(location: 23, length: 4))
            MarkdownFormat.toggle(.bold, in: view)
            check(view.string == "She walked out at low ***tide***.", "format: bold inside italic")
            MarkdownFormat.toggle(.italic, in: view)
            check(view.string == "She walked out at low **tide**.", "format: italic off leaves the bold")
        }

        // MARK: Text size (View › Bigger Text), in memory only

        if let scene = chapters().last?.scenes.first {
            let defaults = UserDefaults.standard
            let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            let normalSize = Layout.textSize, normalWidth = Layout.proseWidth
            defaults.setVolatileDomain(saved.merging([ProseSize.defaultsKey: 3]) { $1 }, forName: UserDefaults.argumentDomain)
            store.selection = .scene(scene.url)
            await settle(200)
            let font = store.margin.textView?.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            check(Layout.textSize == normalSize + 3 && font?.pointSize == normalSize + 3,
                  "text size: three steps bigger sets the page three points bigger")
            check(Layout.proseWidth > normalWidth * 1.1, "text size: the line widens with the type, so it keeps its length in characters")
            defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
            await settle(200)
            check(Layout.textSize == normalSize, "text size: Actual Size goes back to the default")
        }

        // Clicking a comment brings its passage into view, however far down the scene it is.
        let roomy = store.library?.books.flatMap(\.chapters).first { !$0.scenes.isEmpty }
        check(roomy != nil, "comments: (a scene to scroll in)")
        if let chapter = roomy, let sceneURL = chapter.scenes.first?.url {
            let filler = (1...160).map { "Paragraph \($0) of the long scene, there to push the passage far down the page." }
            store.selection = .scene(sceneURL)
            store.updateText(filler.joined(separator: "\n\n") + "\n\nAt the very end the lamp went out.")
            store.saveNow()
            await reopen(sceneURL, from: chapter.url)
            check(margin.textView?.enclosingScrollView != nil, "comments: (the page is on screen)")
            if let page = margin.textView, let clip = page.enclosingScrollView?.contentView {
                let target = (page.string as NSString).range(of: "the lamp went out")
                page.setSelectedRange(target)
                if let id = margin.addCommentOnSelection()?.id {
                    margin.setText("Who?", of: id)
                    await settle(150)
                    page.setSelectedRange(NSRange(location: 0, length: 0))
                    page.scrollRangeToVisible(NSRange(location: 0, length: 0))
                    await settle(150)
                    check(!clip.documentVisibleRect.intersects(page.bounds(of: target)), "comments: (the passage starts off screen)")
                    margin.scrollTo(id)
                    await settle(150)
                    check(clip.documentVisibleRect.contains(page.bounds(of: target)), "comments: clicking a comment scrolls to its passage")
                    check(page.selectedRange().length == 0, "comments: going to a passage never selects it (a key would replace it)")
                    margin.reveal(id)
                    check(page.selectedRange().length == 0, "comments: opening a comment from a list never selects its passage")

                    // A new line typed at the very start of the passage, reported by AppKit as
                    // an edit of the whole paragraph: the comment keeps its words.
                    let before = (page.string as NSString).range(of: "the lamp went out")
                    page.setSelectedRange(NSRange(location: before.location, length: 0))
                    page.insertText("\n", replacementRange: page.selectedRange())
                    let paragraph = (page.string as NSString).paragraphRange(for: NSRange(location: before.location + 1, length: 0))
                    margin.textDidEdit(scene: sceneURL, range: paragraph, delta: 0) { page.string as NSString }
                    check(passage(id) == "the lamp went out", "comments: a wide edit report around the passage keeps it")
                    page.undoManager?.undo()
                    margin.delete(id)
                    margin.saveNow()
                }
            }
        }

        // Remembering your place: switching away and back, reopening the library, and off.
        do {
            let all = store.library?.books.flatMap(\.chapters).flatMap(\.scenes) ?? []
            if all.count >= 2 {
                let first = all[0].url, second = all[1].url
                store.selection = .scene(first)
                store.updateText((1...150).map { "Line \($0) of a scene long enough to scroll." }.joined(separator: "\n\n"))
                store.saveNow()
                await settle(200)
                store.selection = .scene(second); await settle(200)
                store.selection = .scene(first); await settle(300)
                if let page = margin.textView {
                    let target = (page.string as NSString).range(of: "Line 120 of").location
                    page.setSelectedRange(NSRange(location: target, length: 0))
                    page.scrollRangeToVisible(NSRange(location: target, length: 0))
                    await settle(150)
                    let before = page.currentPlace
                    store.selection = .scene(second); await settle(250)
                    store.selection = .scene(first); await settle(300)
                    let back = margin.textView?.currentPlace
                    check(back?.caret == before.caret, "place: the caret is where you left it in a scene")
                    check(back.map { abs($0.top - before.top) < 60 } == true && before.top > 0,
                          "place: the page scrolls back to where you were")
                    store.places.save()
                    let file = root.appendingPathComponent(".longhand/places.json")
                    check(FileManager.default.fileExists(atPath: file.path), "place: places are saved in the library")
                    check(Git.ignore.contains(Git.placesRule), "place: left out of versions")

                    // Opening the library again: back on that scene, at that place.
                    store.selection = .scene(second); await settle(250)
                    store.selection = .scene(first); await settle(250)
                    store.openLibrary(at: root)
                    await settle(500)
                    check(store.selection == .scene(first), "place: the library opens on what was open last")
                    check(margin.textView?.currentPlace.caret == before.caret, "place: …at the same place")

                    // Turned off: scenes open at the top.
                    let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
                    defaults.setVolatileDomain(saved.merging([Places.settingKey: false]) { $1 }, forName: UserDefaults.argumentDomain)
                    store.selection = .scene(second); await settle(250)
                    store.selection = .scene(first); await settle(300)
                    check(margin.textView?.selectedRange().location == 0, "place: turned off, a scene opens at the top")
                    defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
                }
            }
        }

        // The path: full names while they fit; ancestors shortened first when they don't.
        do {
            let path = [PathSegment(id: 0, title: "Strange Case of Dr Jekyll and Mr Hyde", isCurrent: false),
                        PathSegment(id: 1, title: "The Long Low Water Between the Islands", isCurrent: false),
                        PathSegment(id: 2, title: "Arrival", isCurrent: true)]
            let full = path.map(PathBar.width(of:))
            check(PathBar.widths(of: path, room: 2000) == full.map { $0.rounded(.down) }, "path: names keep their (capped) widths when there's room")
            check(full[0] <= 180 && full[1] <= 180, "path: a long name is capped (180pt for ancestors)")
            // Narrower than the capped names: the ancestors shorten further, the open place doesn't.
            let tight = PathBar.widths(of: path, room: 380)
            check(tight[2] == full[2].rounded(.down) && tight[0] < full[0] && tight[1] < full[1] && tight.reduce(0, +) <= 380,
                  "path: ancestors give way first when the toolbar is narrow")
            check(!Git.ignore.contains(Git.coversRule), "covers are committed, so they reach GitHub and other Macs")
        }

        // MARK: Renaming to change only the capitals

        do {
            func all() -> [Scene] { store.library?.books.flatMap(\.chapters).flatMap(\.scenes) ?? [] }
            if all().isEmpty { store.createBook() }
            if let scene = all().first {
                let was = scene.title, count = all().count, oldName = scene.url.lastPathComponent
                store.selection = .scene(scene.url)
                store.rename(item(scene), to: was.uppercased())
                let shouted = all().first { $0.title == was.uppercased() }
                check(shouted != nil && shouted?.url.lastPathComponent.hasSuffix(" 2.md") == false && all().count == count,
                      "rename: changing only the capitals keeps the name (no “… 2”)")
                check(selectedSceneURL == shouted?.url, "rename: the open scene follows a capitals-only rename")
                if let shouted {
                    // The Mac's disk treats the two spellings as one file, so Git has to be
                    // told about the old one by hand; otherwise the other Mac keeps it.
                    if let lib = store.libraryURL { _ = Git.commitAll(lib, message: "Case rename") }
                    let folder = String(shouted.url.deletingLastPathComponent().path.dropFirst(root.canonical.path.count + 1))
                    let listed = git("ls-files", "--", folder)
                    check(listed.contains(shouted.url.lastPathComponent) && !listed.contains(oldName)
                          && shouted.url.lastPathComponent != oldName,
                          "rename: Git records the new capitals, so the other Mac doesn't keep the old name")
                    store.rename(item(shouted), to: was)
                }
                check(all().contains { $0.title == was } && all().count == count, "rename: and back again")
            } else {
                check(false, "rename: a scene to rename")
            }
        }

        // MARK: Pinned stories and linked stories (issues #13 and #14)

        do {
            store.createBook(title: "Link Novel")
            store.createBook(title: "Link Notes")
            func story(_ title: String) -> Book? { store.library?.books.first { $0.title == title } }
            func asItem(_ book: Book) -> ManuscriptItem { ManuscriptItem(url: book.url, title: book.title, order: book.order, kind: .book) }
            if let novel = story("Link Novel"), let notes = story("Link Notes") {
                store.margin.setPinned(true, for: novel.url)
                check(store.pinnedBooks.map(\.title) == ["Link Novel"], "pins: a story is pinned")
                check(store.margin.info(for: novel.url).pinned == true && store.margin.info(for: notes.url).isEmpty,
                      "pins: only that story carries the pin")
                store.margin.setPinned(false, for: novel.url)
                check(store.pinnedBooks.isEmpty && store.margin.info(for: novel.url).isEmpty, "pins: unpinning leaves no trace in the story's details")
                store.margin.setPinned(true, for: novel.url)

                store.margin.link(novel.url, to: notes.title)
                store.margin.link(novel.url, to: notes.title)
                check(store.links(from: novel).map(\.title) == ["Link Notes"], "links: a story shows the stories it links to, once")
                check(store.links(to: notes).map(\.title) == ["Link Novel"] && store.links(from: notes).isEmpty,
                      "links: the other story shows the link too, without storing one of its own")
                let stored = (try? JSONEncoder().encode(store.margin.info(for: novel.url))).flatMap { try? JSONDecoder().decode(SceneInfo.self, from: $0) }
                check(stored?.links == ["Link Notes"] && stored?.pinned == true, "links: links and pins are kept in the story's details")

                store.rename(asItem(notes), to: "Link Planning")
                check(store.links(from: novel).map(\.title) == ["Link Planning"], "links: renaming the linked story keeps the link")
                if let renamed = story("Link Planning") {
                    store.delete(asItem(renamed))
                    check(store.links(from: novel).isEmpty, "links: a link to a story that is gone shows nothing")
                }
                if let novel = story("Link Novel") { store.delete(asItem(novel)) }
            } else {
                check(false, "links: two stories to link")
            }
        }

        // MARK: Tracked names (issue #24)

        do {
            let sample = "Mara met Marathon runners. MARA nodded; Mara’s cup, Mara's cup. A mara bird. Mara Voss."
            check(NameMatch.ranges(of: "Mara", in: sample).count == 5,
                  "names: whole words only, with possessives and capitals (not Marathon, not the lower-case bird)")
            check(NameMatch.replacing("Mara", with: "Maren", in: sample)
                  == "Maren met Marathon runners. MAREN nodded; Maren’s cup, Maren's cup. A mara bird. Maren Voss.",
                  "names: a change keeps possessives, and capitals stay capitals")
            check(NameMatch.replacing("Mara Voss", with: "Maren Ode", in: "Mara  Voss and Mara Vossen") == "Maren Ode and Mara Vossen",
                  "names: a name of two words matches across spacing, and only as a whole")
            let edits = NameMatch.edits(replacing: "Mara", with: "Marguerite", in: "Mara and Mara")
            check(NameMatch.map(0, through: edits) == 0 && NameMatch.map(5, through: edits) == 5 + 6
                  && NameMatch.map(13, through: edits, end: true) == 13 + 12 && NameMatch.map(2, through: edits) == 0,
                  "names: positions in the old text map to the new, a place inside a name going to its start (or end)")
            let regexes = ["Mara"].compactMap(NameMatch.regex(for:))
            check(NameMatch.range(at: 2, in: "A Mara came" as NSString, among: regexes) == NSRange(location: 2, length: 4)
                  && NameMatch.range(at: 1, in: "A Mara came" as NSString, among: regexes) == nil
                  && NameMatch.range(at: 6, in: "A Mara came" as NSString, among: regexes) == nil,
                  "names: the pointer finds the name it is over, and not the space beside it")

            store.createBook(title: "Names Test")
            if let book = store.library?.books.first(where: { $0.title == "Names Test" }),
               let scene = book.chapters.first?.scenes.first, let lib = store.libraryURL {
                let body = "Mara walked in. “Mara,” said Tomas.\n\nLater, MARA left and Marathon began.\n"
                try? body.write(to: scene.url, atomically: true, encoding: .utf8)
                store.margin.trackName("Mara", in: book.url)
                store.margin.trackName("  Mara ", in: book.url)
                store.margin.trackName("Tomas", in: book.url)
                check(store.margin.trackedNames(of: book.url) == ["Mara", "Tomas"], "names: a name is tracked once")

                // Comment, note, synopsis and a story note that all mention her.
                let rel = LibraryStore.relativePath(scene.url, in: lib) ?? ""
                let key = (rel as NSString).deletingPathExtension
                let at = (body as NSString).range(of: "Tomas")
                let commentJSON = "{\"version\":1,\"comments\":[{\"id\":\"\(UUID().uuidString)\",\"created\":\"2026-11-20T10:00:00Z\",\"text\":\"Ask Mara about this\",\"resolved\":false,\"location\":\(at.location),\"length\":\(at.length),\"quote\":\"Tomas\",\"prefix\":\"“Mara,” said \",\"suffix\":\"\"}]}"
                let meta = lib.appendingPathComponent(".longhand")
                for (folder, ext, text) in [("comments", ".json", commentJSON), ("notes", ".md", "Mara is the ferrywoman.\n")] {
                    let file = meta.appendingPathComponent("\(folder)/\(key)\(ext)")
                    try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? text.write(to: file, atomically: true, encoding: .utf8)
                }
                store.margin.setInfo(SceneInfo(synopsis: "Mara arrives."), for: scene.url)
                let storyNote = book.url.appendingPathComponent("Notes/Cast.md")
                try? fm.createDirectory(at: storyNote.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "Mara is the ferrywoman.\n".write(to: storyNote, atomically: true, encoding: .utf8)

                let counted = await store.occurrences(of: ["Mara"], in: book)["Mara"]
                check(counted?.places == 3 && counted?.scenes == 1, "names: the tab counts the places and scenes")

                let changedBy = await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in
                    _ = store.renameName("Mara", to: "Maren", in: book) { go.resume(returning: $0) }
                }
                let after = disk(scene.url)
                check(after == "Maren walked in. “Maren,” said Tomas.\n\nLater, MAREN left and Marathon began.\n",
                      "names: changing a name changes it in every place, whole words only")
                check(changedBy, "names: the change is committed")
                let comment = store.margin.readComments(for: scene.url).first
                let now = (after as NSString).range(of: "Tomas")
                check(comment?.text == "Ask Maren about this" && comment?.location == now.location && comment?.length == now.length
                      && comment?.prefix == "“Maren,” said ",
                      "names: a comment's words change, and it stays on its passage")
                check(disk(meta.appendingPathComponent("notes/\(key).md")) == "Maren is the ferrywoman.\n"
                      && disk(storyNote) == "Maren is the ferrywoman.\n",
                      "names: scene notes and the story's notes change")
                check(store.margin.info(for: scene.url).synopsis == "Maren arrives.", "names: a synopsis changes")
                check(store.margin.trackedNames(of: book.url) == ["Maren", "Tomas"], "names: the tracked name is its new self, in its place")
                let subjects = git("log", "--format=%s")
                check(subjects.contains("Mara was changed to Maren") && subjects.contains("Before changing Mara to Maren"),
                      "names: the story is committed before, and after as “Mara was changed to Maren”")
                check(git("log", "-1", "--format=%B").contains("Longhand-Version:"), "names: the change is a version of the scene it touched")
                if let current = store.library?.books.first(where: { $0.title == "Names Test" }) {
                    store.delete(ManuscriptItem(url: current.url, title: current.title, order: current.order, kind: .book))
                }
            } else {
                check(false, "names: a story to track names in")
            }

            // One character, several names.
            store.createBook(title: "Group Test")
            if let group = store.library?.books.first(where: { $0.title == "Group Test" }), let scene = group.chapters.first?.scenes.first {
                let margin = store.margin
                margin.trackName("Mara, Mara Voss, Ms. Voss, Mara", in: group.url)
                check(margin.nameGroups(of: group.url).map(\.names) == [["Mara", "Mara Voss", "Ms. Voss"]],
                      "names: commas make one character of several names, each once")
                check(margin.trackedNames(of: group.url) == ["Mara", "Mara Voss", "Ms. Voss"], "names: the page hovers over every name of a group")
                check(!margin.trackName("Ms. Voss", in: group.url), "names: a name in a group is not tracked again on its own")
                check(NameMatch.count(ofAny: ["Mara", "Mara Voss", "Ms. Voss"], in: ["Mara Voss met Ms. Voss and Mara."]) == (3, 1),
                      "names: a character's count is its places, Mara inside Mara Voss counted once")
                margin.addNames("Maz", toGroupOf: "Mara", in: group.url)
                check(margin.nameGroups(of: group.url).first?.names.last == "Maz", "names: another name is added to a character")
                margin.untrackName("Maz", in: group.url)

                try? "Mara Voss met Ms. Voss and Mara. “Mara,” said Ms. Voss.\n".write(to: scene.url, atomically: true, encoding: .utf8)
                _ = await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in
                    _ = store.renameName("Mara", to: "Maren", in: group) { go.resume(returning: $0) }
                }
                check(disk(scene.url) == "Maren Voss met Ms. Voss and Maren. “Maren,” said Ms. Voss.\n", "names: changing a main name changes it in the text, in its longer names too")
                check(margin.nameGroups(of: group.url).map(\.names) == [["Maren", "Maren Voss", "Ms. Voss"]],
                      "names: the other names that held it follow the main name")
                margin.renameTracked("Ms. Voss", to: "Mrs. Voss", in: group.url)
                check(margin.nameGroups(of: group.url).map(\.names) == [["Maren", "Maren Voss", "Mrs. Voss"]], "names: changing one of the other names changes only that one")
                margin.untrackName("Maren", in: group.url)
                check(margin.nameGroups(of: group.url).map(\.main) == ["Maren Voss"], "names: the main name going hands that to the next")
                margin.untrackGroup("Maren Voss", in: group.url)
                check(margin.nameGroups(of: group.url).isEmpty, "names: a character stops being tracked")
                if let current = store.library?.books.first(where: { $0.title == "Group Test" }) {
                    store.delete(ManuscriptItem(url: current.url, title: current.title, order: current.order, kind: .book))
                }
            } else {
                check(false, "names: a story to group names in")
            }
        }

        // MARK: Folder keepers and notes reach Git without a scene being saved

        do {
            store.createBook(title: "Keeper Test")
            if let keeperBook = store.library?.books.first(where: { $0.title == "Keeper Test" }),
               let chapter = keeperBook.chapters.first, let lib = store.libraryURL {
                for scene in chapter.scenes { store.delete(item(scene)) }
                let chapterKeeper = chapter.url.appendingPathComponent(LibraryFolders.keeper)
                check(fm.fileExists(atPath: chapterKeeper.path),
                      "Git: an emptied chapter keeps a hidden .keep, so the folder still travels")
                _ = Git.commitAll(lib, message: "Keepers")
                let chapterPath = String(chapterKeeper.canonical.path.dropFirst(root.canonical.path.count + 1))
                check(git("ls-files").contains(chapterPath),
                      "Git: the emptied chapter's .keep is committed, so the other Mac gets the folder")
                store.delete(item(chapter))
                let storyKeeper = keeperBook.url.appendingPathComponent(LibraryFolders.keeper)
                check(fm.fileExists(atPath: storyKeeper.path),
                      "Git: an emptied story keeps a hidden .keep, so the folder still travels")
                if let folder = store.createFolder(named: "Keeper Folder") {
                    check(fm.fileExists(atPath: folder.appendingPathComponent(LibraryFolders.keeper).path),
                          "Git: a new empty folder keeps a hidden .keep, so the folder still travels")
                }
                _ = Git.commitAll(lib, message: "Keepers")
                let storyPath = String(storyKeeper.canonical.path.dropFirst(root.canonical.path.count + 1))
                check(git("ls-files").contains(storyPath),
                      "Git: the emptied story's .keep is committed, so the other Mac gets the folder")
                store.delete(ManuscriptItem(url: keeperBook.url, title: keeperBook.title, order: 1, kind: .book))
                if let folder = store.library?.folders.first(where: { $0.url.lastPathComponent == "Keeper Folder" }) {
                    store.deleteFolder(folder.url)
                }
            } else {
                check(false, "Git: a story to empty for the keeper test")
            }
        }

        do {
            let chapter = store.library?.books.flatMap(\.chapters).first { !$0.scenes.isEmpty }
            if let scene = chapter?.scenes.first, let lib = store.libraryURL {
                store.selection = .scene(scene.url)
                await settle(300)
                _ = await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in
                    store.versions.commitNow { go.resume(returning: $0) }
                }
                await settle(250)
                check(!store.versions.hasPendingCommit, "notes: nothing waits to be committed to begin with")
                store.margin.setSceneNote("A note that has to travel.")
                store.margin.saveNow()
                check(store.versions.hasPendingCommit, "notes: writing only a note asks for a commit")
                let relative = String(scene.url.path.dropFirst(root.canonical.path.count + 1).dropLast(3))
                let notePath = ".longhand/notes/\(relative).md"
                _ = Git.commitAll(lib, message: "Note")
                check(git("ls-files").contains(notePath), "notes: the note file is committed like a save")
                store.margin.setSceneNote("")
                store.margin.saveNow()
                _ = Git.commitAll(lib, message: "Note removed")
            } else {
                check(false, "notes: a scene and a library to test with")
            }
        }

        // MARK: A book note written by another app

        if let book = store.library?.books.first {
            let folder = MarginStore.notesFolder(of: book.url)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let note = folder.appendingPathComponent("Foreign.md")
            try? "Café déjà vu".data(using: .windowsCP1252)?.write(to: note)
            store.selection = .book(book.url)
            store.margin.reloadBookNotes()
            if let found = store.margin.bookNotes.first(where: { $0.title == "Foreign" }) {
                store.margin.openNote(found)
                check(store.margin.openBookNoteText == "Café déjà vu", "notes: a note in another encoding opens with its words")
                store.margin.openNote(nil)
            } else {
                check(false, "notes: the foreign note is listed")
            }
            try? fm.removeItem(at: note)
            store.margin.reloadBookNotes()
        }

        // MARK: A damaged comments file is kept, not written over

        do {
            let scenes = store.library?.books.flatMap(\.chapters).flatMap(\.scenes) ?? []
            if let scene = scenes.first {
                let relative = String(scene.url.path.dropFirst(root.canonical.path.count + 1).dropLast(3))
                let file = root.canonical.appendingPathComponent(".longhand/comments/\(relative).json")
                try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "{ \"comments\": [ { \"id\": \"cut sho".write(to: file, atomically: true, encoding: .utf8)
                let read = store.margin.readComments(for: scene.url)
                let beside = ((try? fm.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? [])
                    .filter { $0.contains(".unreadable-") }
                check(read.isEmpty && !fm.fileExists(atPath: file.path) && beside.count == 1,
                      "comments: a damaged file is moved aside, not treated as empty and overwritten")
                if let kept = beside.first {
                    let text = (try? String(contentsOf: file.deletingLastPathComponent().appendingPathComponent(kept), encoding: .utf8)) ?? ""
                    check(text.contains("cut sho"), "comments: the damaged file keeps what it held")
                    try? fm.removeItem(at: file.deletingLastPathComponent().appendingPathComponent(kept))
                }
            } else {
                check(false, "comments: a scene to test with")
            }
        }

        // MARK: Folders in the Library

        do {
            let before = store.library?.books.map(\.url) ?? []
            check(store.library?.folders.isEmpty == true && (store.library?.books.allSatisfy { $0.folder == nil } ?? false),
                  "folders: a library without folders reads as before")
            let shelf = store.createFolder(named: "Shelf")
            check(shelf != nil && store.library?.folders.map(\.title) == ["Shelf"] && store.library?.books.map(\.url) == before,
                  "folders: New Folder makes an empty folder and no story")

            store.createBook()
            if let scene = selectedSceneURL, let book = store.location(ofScene: scene)?.book, let shelf {
                store.updateText("Folder words.")
                store.saveNow()
                var info = store.margin.info(for: book.url)
                info.stage = .sketch
                store.margin.setInfo(info, for: book.url)
                store.margin.saveNow()

                store.moveBook(book.url, toFolder: shelf)
                let moved = store.library?.books.first { $0.folder == shelf }
                check(moved != nil && moved?.title == book.title && !fm.fileExists(atPath: book.url.path),
                      "folders: a story moves into a folder")
                check(selectedSceneURL.map { $0.path.hasPrefix(shelf.path + "/") } == true && disk(selectedSceneURL) == "Folder words.",
                      "folders: the open scene follows the move")
                store.updateText("Folder words. And more.")
                store.saveNow()
                check(disk(selectedSceneURL) == "Folder words. And more.", "folders: typing after the move saves to the new place")
                check(moved.map { store.margin.info(for: $0.url).stage } == .sketch, "folders: the story's details go with it")

                let relative = selectedSceneURL.map { String($0.path.dropFirst(root.canonical.path.count + 1)) } ?? ""
                check(relative.split(separator: "/").count == 4 && Git.isScene(relative), "folders: a scene in a folder counts as a scene")
                check(Git.scenesOnDisk(root.canonical).contains(relative), "folders: versions see scenes inside folders")
                check(Git.changedScenes(root.canonical).contains(relative), "folders: a new scene in a folder is waiting for a version")
                check(!Git.isScene("Shelf/Story/Notes/Idea.md") && !Git.isScene("Story/Notes/Idea.md") && Git.isScene("Story/Chapter/Scene.md"),
                      "folders: notes are still not scenes")

                // Versions, end to end, for a story in a folder.
                let lib = root.canonical
                check(Git.commitVersions(lib, scenes: Git.changedScenes(lib), note: "In a folder")
                      && !Git.changedScenes(lib).contains(relative), "folders: saving a version settles the scene")
                store.updateText("Folder words. And more. Then a revision.")
                store.saveNow()
                let revision = Git.sceneChanges(lib).changes.first { $0.path == relative }
                check(Git.changedScenes(lib).contains(relative) && revision?.wordsAdded == 3 && revision?.wordsRemoved == 0,
                      "folders: a revision shows as three words added since the version")
                store.updateText("Folder words. And more.")
                store.saveNow()
                check(!Git.changedScenes(lib).contains(relative), "folders: putting the words back clears the change")

                store.renameFolder(shelf, to: "Bookcase")
                let after = selectedSceneURL.map { String($0.path.dropFirst(lib.path.count + 1)) } ?? ""
                check(Git.commitAll(lib, message: "Folder renamed")
                      && Git.sceneHistories(lib, scenes: [after])[after]?.isEmpty == false,
                      "folders: a scene's history follows its folder's rename")
                let renamed = store.library?.folders.first
                check(renamed?.title == "Bookcase" && store.library?.books.contains { $0.folder == renamed?.url } == true
                      && disk(selectedSceneURL) == "Folder words. And more."
                      && selectedSceneURL.map { $0.path.contains("/Bookcase/") } == true,
                      "folders: renaming a folder keeps its stories and the open scene")
                check(LibraryFolders.listed(root.canonical) == ["Bookcase"], "folders: the renamed folder is remembered")
                check(moved.flatMap { _ in store.library?.books.first { $0.folder == renamed?.url } }.map { store.margin.info(for: $0.url).stage } == .sketch,
                      "folders: details survive the folder's rename")

                if let inside = store.library?.books.first(where: { $0.folder == renamed?.url }), let folder = renamed?.url {
                    store.deleteFolder(folder)
                    check(fm.fileExists(atPath: folder.path), "folders: a folder with stories in it is not removed")
                    store.errorMessage = nil
                    store.moveBook(inside.url, toFolder: nil)
                    check(store.library?.books.contains { $0.folder != nil } == false && store.library?.folders.count == 1
                          && disk(selectedSceneURL) == "Folder words. And more.",
                          "folders: a story moves back out, and the empty folder stays")
                    store.deleteFolder(folder)
                    check(store.library?.folders.isEmpty == true && LibraryFolders.listed(root.canonical).isEmpty,
                          "folders: an empty folder can be removed")
                }
            } else {
                check(false, "folders: a story to move")
            }

            // Stories put in a folder with the Finder: the shape says it's a folder.
            let finder = root.appendingPathComponent("From Finder/01 Tale/01 Opening")
            try? fm.createDirectory(at: finder, withIntermediateDirectories: true)
            try? "By hand.".write(to: finder.appendingPathComponent("01 First.md"), atomically: true, encoding: .utf8)
            store.refreshFromDisk()
            let found = store.library?.folders.first { $0.title == "From Finder" }
            check(found != nil && store.library?.books.first { $0.folder == found?.url }?.title == "Tale",
                  "folders: stories dragged into a folder in the Finder show as a folder")
            check(before.allSatisfy { url in store.library?.books.contains { $0.url == url && $0.folder == nil } == true },
                  "folders: the other stories stay where they were")
            try? fm.removeItem(at: root.appendingPathComponent("From Finder"))
            store.refreshFromDisk()
        }

        // MARK: Stories dragged in the Library

        do {
            func atTop() -> [Book] { store.library?.books(in: nil) ?? [] }
            store.createBook(title: "Drag One")
            let one = atTop().last
            store.createBook(title: "Drag Two")
            let two = atTop().last
            if let one, let two, one.url != two.url,
               let start = atTop().firstIndex(where: { $0.url == one.url }) {
                check(atTop().map(\.title).suffix(2) == [one.title, two.title],
                      "stories: two new stories at the end of the Library")
                // The second story dragged onto the first one's row: it takes its place.
                let oneOrder = one.order
                store.placeBook(two.url, at: start)
                let after = atTop()
                check(after.firstIndex { $0.title == one.title } == start + 1
                      && after.firstIndex { $0.title == two.title } == start,
                      "stories: a story dropped on another takes its place")
                check(after.first { $0.title == two.title }?.order == oneOrder,
                      "stories: its file's number follows its new place")
                // A story being edited follows the move.
                if let current = after.first(where: { $0.title == two.title }) {
                    store.selection = .book(current.url)
                    store.placeBook(current.url, at: start + 1)
                    check(store.selection.map { store.book(for: $0.url)?.title } == two.title
                          && store.selection?.url != current.url,
                          "stories: the selection follows a story that moves")
                } else {
                    check(false, "stories: the moved story")
                }
                for book in atTop().filter({ $0.title == one.title || $0.title == two.title }) {
                    store.delete(ManuscriptItem(url: book.url, title: book.title, order: book.order, kind: .book))
                }
                check(atTop().contains { $0.title == one.title || $0.title == two.title } == false,
                      "stories: the two drag stories are cleared away")

                // A story moved into a folder lands after the stories already there, so two
                // stories in one folder never share a number.
                if let tray = store.createFolder(named: "Tray") {
                    store.createBook(title: "Tray Story")
                    if let story = atTop().last {
                        store.moveBook(story.url, toFolder: tray)
                        let inside = store.library?.books(in: tray) ?? []
                        check(inside.count == 1 && inside[0].title == "Tray Story" && inside[0].folder == tray,
                              "stories: a story moved into a folder lands there")
                        store.createBook(title: "Tray Second")
                        if let second = atTop().last {
                            store.moveBook(second.url, toFolder: tray)
                            let both = store.library?.books(in: tray) ?? []
                            check(both.count == 2 && Set(both.map(\.order)).count == 2,
                                  "stories: a second story arriving in a folder is numbered after the first")
                            for book in both {
                                store.delete(ManuscriptItem(url: book.url, title: book.title, order: book.order, kind: .book))
                            }
                        } else {
                            check(false, "stories: a second story for the folder")
                        }
                        store.deleteFolder(tray)
                        check(store.library?.folders.contains { $0.url == tray } == false,
                              "stories: the folder is cleared away")
                    } else {
                        check(false, "stories: a story for the folder")
                    }
                } else {
                    check(false, "stories: a folder to move into")
                }
            } else {
                check(false, "stories: two stories to reorder")
            }
        }

        // MARK: Story shapes: one document, scenes only, chapters only; joining and splitting

        do {
            func newest() -> Book? { store.library?.books.max { $0.order < $1.order } }
            func relative(_ url: URL) -> String { String(url.canonical.path.dropFirst(root.canonical.path.count + 1)) }

            // One document: a folder with one file, named for the story.
            store.createBook(title: "Signal", form: .shortStory, shape: .document)
            let document = newest()
            check(document?.shape == .document && document?.document != nil
                  && document?.document?.url.deletingLastPathComponent().canonical == document?.url.canonical
                  && document?.document?.url.lastPathComponent == "Signal.md",
                  "shapes: a single document is one file, Signal.md, in the story's folder")
            check(selectedSceneURL == document?.document?.url && store.openBook == document?.url,
                  "shapes: a new document opens at its text, inside the story")
            check(!store.canAddScene && !store.canAddChapter, "shapes: a single document takes no new scenes or chapters")
            check(store.margin.info(for: document?.url ?? root).form == .shortStory, "shapes: the form chosen is kept")
            store.updateText("A first line.")
            store.saveNow()
            check(disk(document?.document?.url) == "A first line." && store.wordCount(of: document!) == 3,
                  "shapes: typing in a document saves and counts")
            check(store.number(ofScene: document?.document?.url ?? root) == nil, "shapes: a document has no number")
            // A one-document story's own chapter is the story itself, not a page of its own:
            // choosing it opens the document (a screenplay must stay a script, not prose).
            if let doc = document?.document, let own = document?.chapters.first(where: \.implicit) {
                store.selection = .chapter(own.url)
                await settle(200)
                check(store.selection == .scene(doc.url),
                      "shapes: choosing a document story's own chapter opens the document")
            }
            if let doc = document?.document { check(Git.isScene(relative(doc.url)) && Git.scenesOnDisk(root.canonical).contains(relative(doc.url)),
                                                   "shapes: Git counts the document as a scene") }

            // Split into Chapters: one chapter per heading.
            store.updateText("Before the first.\n\n# One\n\nFirst words.\n\n# Two\n\nSecond words.")
            store.saveNow()
            if let book = document { store.splitIntoChapters(book.url) }
            let split = store.library?.books.first { $0.url == document?.url }
            check(split?.shape == .chaptersAndScenes && split?.chapters.map(\.title) == ["Opening", "One", "Two"],
                  "shapes: Split into Chapters cuts at headings (and keeps the opening)")
            check(split?.chapters.dropFirst().first?.scenes.first.map { disk($0.url) } == "First words.\n",
                  "shapes: each chapter holds its text, without the heading")
            check(document?.document.map { !fm.fileExists(atPath: $0.url.path) } == true, "shapes: the document goes to the Trash")

            // Join into One Document, with a comment carried across.
            if let book = split, let second = book.chapters.last?.scenes.first {
                let commentFile = root.appendingPathComponent(".longhand/comments/\(relative(second.url).dropLast(3)).json")
                try? fm.createDirectory(at: commentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? #"{"version":1,"comments":[{"id":"3D6A2F1E-6C0B-4F8B-9E7A-1A2B3C4D5E6F","created":"2026-11-14T00:00:00Z","text":"Keep.","resolved":false,"location":7,"length":5,"quote":"words","prefix":"","suffix":""}]}"#
                    .write(to: commentFile, atomically: true, encoding: .utf8)
                store.joinIntoOneDocument(book.url)
                let joined = store.library?.books.first { $0.url == book.url }
                let text = disk(joined?.document?.url)
                check(joined?.shape == .document && text.contains("# One\n\nFirst words.") && text.contains("# Two\n\nSecond words."),
                      "shapes: Join into One Document puts chapters in order under their titles")
                let comment = joined?.document.map { store.margin.readComments(for: $0.url) }?.first
                let passage = comment.map { (text as NSString).substring(with: $0.range) }
                check(passage == "words" && comment?.text == "Keep.", "shapes: a comment follows its passage into the joined document")
                check(book.chapters.allSatisfy { !fm.fileExists(atPath: $0.url.path) }, "shapes: the old chapters go to the Trash")
            }

            // Scenes only: files straight in the story's folder, numbered 1, 2.
            store.createBook(title: "Fragments", form: .notebook, shape: .scenes)
            store.createSceneInContext()
            let scenesOnly = newest()
            check(scenesOnly?.shape == .scenes && scenesOnly?.looseScenes.count == 2 && scenesOnly?.chapters.count == 1,
                  "shapes: a scenes-only story keeps its scenes straight in its folder")
            check(store.canAddScene && !store.canAddChapter, "shapes: a scenes-only story takes scenes, not chapters")
            check(scenesOnly?.looseScenes.last.flatMap { store.number(ofScene: $0.url) } == "2", "shapes: its scenes are numbered 1, 2")
            // A scenes-only story's own chapter is a real page: its scenes on one.
            if let own = scenesOnly?.chapters.first(where: \.implicit) {
                store.selection = .chapter(own.url)
                await settle(200)
                check(store.selection == .chapter(own.url),
                      "shapes: a scenes-only story's own chapter is still its own page")
            }
            if let book = scenesOnly { store.splitIntoChapters(book.url) }
            let wrapped = store.library?.books.first { $0.url == scenesOnly?.url }
            check(wrapped?.shape == .chaptersAndScenes && wrapped?.chapters.count == 1 && wrapped?.chapters.first?.scenes.count == 2,
                  "shapes: Split into Chapters puts a scenes-only story's scenes in Chapter One")

            // Chapters only: each chapter folder holds one file, named for it.
            store.createBook(title: "Logbook", form: .novel, shape: .chapters)
            store.createChapterInContext()
            let chaptersOnly = newest()
            check(chaptersOnly?.shape == .chapters && chaptersOnly?.chapters.count == 2
                  && chaptersOnly?.chapters.allSatisfy { $0.scenes.count == 1 } == true,
                  "shapes: a chapters-only story's chapters each hold one file")
            check(!store.canAddScene && store.canAddChapter, "shapes: a chapters-only story takes chapters, not scenes")
            if let chapter = chaptersOnly?.chapters.last {
                // Its note goes with it (the folder's move once sent the file's note to the Trash).
                if let file = chapter.scenes.first {
                    store.selection = .scene(file.url)
                    store.margin.setSceneNote("Keep me")
                    store.margin.saveNow()
                }
                store.rename(ManuscriptItem(url: chapter.url, title: chapter.title, order: chapter.order, kind: .chapter), to: "Day Two")
                let renamed = store.library?.books.first { $0.url == chaptersOnly?.url }?.chapters.last
                check(renamed?.title == "Day Two" && renamed?.scenes.first?.url.lastPathComponent == "Day Two.md",
                      "shapes: renaming a chapters-only chapter renames its file too")
                if let file = renamed?.scenes.first {
                    store.selection = .book(chaptersOnly?.url ?? file.url)
                    store.selection = .scene(file.url)
                    check(store.margin.sceneNote == "Keep me", "shapes: a renamed chapters-only chapter keeps its note (\(store.margin.sceneNote))")
                }
            }
            check(Git.isScene("Story/Document.md") && Git.isScene("Shelf/Story/Document.md") && !Git.isScene("Document.md"),
                  "shapes: Git counts files straight in a story's folder as scenes")
            check(LibraryStore.chapterParts(of: "No headings here.").map(\.title) == ["Chapter One"],
                  "shapes: a document without headings splits into Chapter One")
            // A collection of short stories: one chapter per story, called stories; its author
            // set from the profile chosen in New Document.
            let storyteller = AuthorProfiles.shared.add(AuthorProfile(name: "Tess Teller"))
            store.createBook(title: "Tales", form: .shortStory, shape: .chapters, collection: true, author: storyteller)
            let tales = newest()
            let talesInfo = tales.map { store.margin.info(for: $0.url) }
            check(tales?.shape == .chapters && tales?.chapters.first?.title == "Story One" && talesInfo?.collection == true
                  && store.names(of: tales?.url).chapters == "Stories" && talesInfo?.authorName == "Tess Teller"
                  && talesInfo?.authorProfile == storyteller.id,
                  "new document: a short story collection has stories for chapters, and the chosen author")
            // Poems: a collection by default (not stored), one poem when unticked.
            store.createBook(title: "", form: .poetry, shape: .scenes)
            let poems = newest()
            check(poems?.title == "Untitled Collection" && poems?.looseScenes.first?.title == "Untitled Poem"
                  && poems.map { store.margin.info(for: $0.url).collection } == .some(nil),
                  "new document: a poetry collection holds poems, and keeps no setting for its default")
            store.createBook(title: "", form: .poetry, shape: .document, collection: false)
            let poem = newest()
            check(poem?.title == "Untitled Poem" && poem?.shape == .document
                  && poem.map { store.margin.info(for: $0.url).collection } == .some(false),
                  "new document: a single poem is one document")
            AuthorProfiles.shared.remove(storyteller.id)

            // A notebook says folders and notes.
            store.createBook(title: "Ideas", form: .notebook, shape: .chaptersAndScenes)
            let notebook = newest()
            check(store.contextNames == .notebook && notebook?.chapters.first?.title == "Folder One"
                  && notebook?.chapters.first?.scenes.first?.title == "Untitled Note",
                  "names: a notebook's parts are folders and notes, from its first ones on")
            store.createSceneInContext()
            check(newest()?.chapters.first?.scenes.last?.title == "Untitled Note" && store.names(of: document?.url) == .story,
                  "names: a new note in a notebook is a note; other stories keep chapters and scenes")
            let outline = OutlineHeading.all(in: "# Part\n\nText.\n\n## A scene\n```\n# not a heading\n```\n### Detail\n#nospace")
            check(outline.map(\.title) == ["Part", "A scene", "Detail"] && outline.map(\.level) == [1, 2, 3],
                  "shapes: a document's outline is its headings, by level (not code, not #words)")
        }

        // MARK: Screenplays: Fountain on disk, keys, styling, pages, Final Draft (2026-11-14)

        do {
            func newest() -> Book? { store.library?.books.max { $0.order < $1.order } }
            store.createBook(title: "Night Ferry", form: .screenplay, shape: .document)
            let script = newest()
            let url = script?.document?.url
            check(script?.isScreenplay == true && url?.lastPathComponent == "Night Ferry.fountain"
                  && url?.deletingLastPathComponent().canonical == script?.url.canonical,
                  "screenplay: a new one is one Fountain file, Night Ferry.fountain, in its story's folder")
            check(!store.canAddScene && !store.canAddChapter && selectedSceneURL == url, "screenplay: it opens at its text and takes no scenes or chapters")
            if let doc = script?.document {
                check(Git.isScene(String(doc.url.canonical.path.dropFirst(root.canonical.path.count + 1))),
                      "screenplay: Git counts the .fountain file as a scene")
            }
            let sample = """
            FADE IN:

            EXT. FERRY TERMINAL - NIGHT

            Rain. One *sodium* lamp.

            MARA
            One for the last crossing.

            TOMAS
            (not unkindly)
            There's no last crossing.

            CUT TO:

            INT. TICKET BOOTH - CONTINUOUS

            A kettle.
            """
            store.updateText(sample)
            store.saveNow()
            await settle(300)
            check(disk(url) == sample, "screenplay: typing saves to the .fountain file")
            // Pages are counted off the main thread: wait for the count (up to three seconds).
            for _ in 0..<30 where script.flatMap({ $0.document }).map({ store.pages(of: $0) }) != 1 { await settle(100) }
            check(script.flatMap { $0.document }.map { store.pages(of: $0) } == 1, "screenplay: its length is counted in pages")
            if let book = script {
                var info = store.margin.info(for: book.url)
                info.target = 110
                store.margin.setInfo(info, for: book.url)
                let novel = store.library?.books.first { !$0.isScreenplay }
                let mine = store.targetProgress(of: book), theirs = novel.map(store.targetProgress(of:))
                check(mine == (1, "pages") && theirs?.unit == "words",
                      "screenplay: its target counts pages; other stories' count words (\(mine), \(String(describing: theirs)))")
            }
            let doc = Fountain.document(sample)
            check(doc.titlePage.isEmpty && doc.elements.map(\.kind) == [.action, .sceneHeading, .action, .character, .dialogue, .character,
                                                                     .parenthetical, .dialogue, .transition, .sceneHeading, .action],
                  "screenplay: Fountain reads each element (FADE IN: is not a title page)")
            check(Fountain.headings(in: sample).map(\.title) == ["EXT. FERRY TERMINAL - NIGHT", "INT. TICKET BOOTH - CONTINUOUS"]
                  && OutlineHeading.screenplay(in: sample).map(\.number) == ["1", "2"],
                  "screenplay: the contents lists its scene headings, numbered")
            let forced = Fountain.document("Title: X\n\n.OVER BLACK #4A#\n\n@McKENNA\nHi.\n\n> FADE OUT.\n\n>THE END<\n\n!LOUD NOISES\nAnd more.\n\nBRICK\nNo.\n\nSTEEL ^\nNo.")
            check(forced.title("Title") == ["X"] && forced.elements.map(\.kind) == [.sceneHeading, .character, .dialogue, .transition, .centered, .action, .character, .dialogue, .character, .dialogue]
                  && forced.elements[0].sceneNumber == "4A" && forced.elements[1].text == "McKENNA" && forced.elements.last(where: { $0.kind == .character })?.dual == true,
                  "screenplay: forced elements, scene numbers, dual dialogue and a title page are read")
            check(Fountain.runs("a *b* **c** _d_ \\*e\\*") == [Fountain.Run(text: "a "), Fountain.Run(text: "b", style: .italic), Fountain.Run(text: " "),
                                                            Fountain.Run(text: "c", style: .bold), Fountain.Run(text: " "),
                                                            Fountain.Run(text: "d", style: .underline), Fountain.Run(text: " *e*")],
                  "screenplay: emphasis and escapes")

            // The page: Courier Prime, elements at their places.
            if let page = margin.textView {
                let string = page.string as NSString
                func style(of text: String) -> NSParagraphStyle? {
                    let at = string.range(of: text).location
                    return at == NSNotFound ? nil : page.textStorage?.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
                }
                let font = page.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                check(font?.fontName.hasPrefix("CourierPrime") == true, "screenplay: the page is set in Courier Prime")
                let action = style(of: "Rain.")?.headIndent ?? 0
                let name = style(of: "MARA")?.headIndent ?? 0
                let speech = style(of: "One for the last")?.headIndent ?? 0
                let paren = style(of: "(not unkindly)")?.headIndent ?? 0
                check(action < speech && speech < paren && paren < name, "screenplay: action, dialogue, parenthetical and name sit at their indents")
                check(style(of: "CUT TO:")?.alignment == .right, "screenplay: a transition is set to the right")

                // Keys: Return after a name goes to dialogue; after dialogue, to a new element.
                page.window?.makeFirstResponder(page)
                func caretToEnd() { page.setSelectedRange(NSRange(location: (page.string as NSString).length, length: 0)) }
                caretToEnd()
                page.insertText("\n\nINT. ", replacementRange: page.selectedRange())
                for c in "kitchen - day" { page.insertText(String(c), replacementRange: page.selectedRange()) }
                check(page.string.hasSuffix("INT. KITCHEN - DAY"), "screenplay: a scene heading is typed in capitals")
                page.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                check(page.string.hasSuffix("DAY\n\n"), "screenplay: Return after a heading starts a new element")
                page.doCommand(by: #selector(NSResponder.insertTab(_:)))
                for c in "mara" { page.insertText(String(c), replacementRange: page.selectedRange()) }
                check(page.string.hasSuffix("\n\nMARA") && !page.string.contains("\t"), "screenplay: Tab starts a name, typed in capitals, no tab character")
                page.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                check(page.string.hasSuffix("MARA\n"), "screenplay: Return after a name goes on to dialogue")
                page.doCommand(by: #selector(NSResponder.insertTab(_:)))
                check(page.string.hasSuffix("MARA\n()") && page.selectedRange().location == (page.string as NSString).length - 1,
                      "screenplay: Tab in a speech starts a parenthetical")
                page.insertText("quietly", replacementRange: page.selectedRange())
                caretToEnd()
                page.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                page.insertText("Hello.", replacementRange: page.selectedRange())
                page.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                check(page.string.hasSuffix("MARA\n(quietly)\nHello.\n\n"), "screenplay: Return after dialogue starts a new element")
                await settle(200)
                check(store.live.element == "Action", "screenplay: the status bar names the element the caret is in")
                let typed = Fountain.document(page.string).elements.suffix(4).map(\.kind)
                check(typed == [.sceneHeading, .character, .parenthetical, .dialogue], "screenplay: what was typed reads back as heading, name, parenthetical, dialogue")
            } else {
                check(false, "screenplay: the page is on screen")
            }

            // Pages: a long speech breaks with (MORE) and (CONT'D).
            var long = "INT. ROOM - DAY\n\n"
            for i in 0..<30 { long += "Action paragraph \(i) goes on for a while so that it wraps onto a second line.\n\n" }
            long += "MARA\n" + (0..<40).map { "Sentence \($0) of a long speech." }.joined(separator: " ") + "\n"
            let laid = ScreenplayLayout.paginate(Fountain.document(long))
            let rows = laid.pages.flatMap { $0.rows.map { $0.map(\.text).joined() } }
            check(laid.pages.count >= 2 && rows.contains("(MORE)") && rows.contains("MARA (CONT'D)")
                  && laid.pages.allSatisfy { $0.rows.count <= ScreenplayLayout.Paper.letter.lines },
                  "screenplay: a speech across a page break gets (MORE) and (CONT'D); pages hold 54 lines")
            check(laid.pages.allSatisfy { $0.rows.first?.isEmpty == false }, "screenplay: no page starts with a blank line")

            // Export: PDF, Final Draft, Fountain.
            if let book = script {
                store.margin.setInfo({ var i = store.margin.info(for: book.url); i.authorName = "Ruth Calder"; return i }(), for: book.url)
                let out = root.appendingPathComponent("exports", isDirectory: true)
                try? fm.createDirectory(at: out, withIntermediateDirectories: true)
                var choices = ScreenplayChoices()
                let pdfURL = out.appendingPathComponent("s.pdf")
                try? Exporter.exportScreenplay(book, store: store, choices: choices, to: pdfURL)
                let pdf = PDFDocument(url: pdfURL)
                check((pdf?.pageCount ?? 0) >= 2 && pdf?.page(at: 0)?.string?.contains("NIGHT FERRY") == true
                      && pdf?.page(at: 0)?.string?.contains("Ruth Calder") == true && pdf?.page(at: 1)?.string?.contains("EXT. FERRY TERMINAL") == true,
                      "screenplay: the PDF has a title page (title, author) and then the script")
                choices.format = .finalDraft
                choices.sceneNumbers = true
                let fdxURL = out.appendingPathComponent("s.fdx")
                try? Exporter.exportScreenplay(book, store: store, choices: choices, to: fdxURL)
                let read = (try? Data(contentsOf: fdxURL)).flatMap(FinalDraft.read)
                let types = read?.paragraphs.map(\.type) ?? []
                check(types.prefix(5) == ["Action", "Scene Heading", "Action", "Character", "Dialogue"] && read?.paragraphs[1].number == "1"
                      && read?.titlePage.contains(where: { $0.text == "Ruth Calder" }) == true,
                      "screenplay: the Final Draft file has each element as its own paragraph, numbers and a title page")
                let styledTitle = Fountain.document("Title: **NIGHT** _FERRY_\n\nINT. A - DAY\n")
                let titleXML = FinalDraft.fdx(styledTitle, titlePage: ScreenplayTitlePage.make(document: styledTitle, storyTitle: "x", author: nil, contact: [], draft: []))
                check(titleXML.contains("<Text Style=\"Bold\">NIGHT</Text>") && titleXML.contains("<Text Style=\"Underline\">FERRY</Text>") && !titleXML.contains("**"),
                      "screenplay: a Final Draft title page carries styles, not Fountain's symbols")
                let dualRows = ScreenplayLayout.paginate(Fountain.document("BRICK\nNo.\nNot again.\n\nSTEEL ^\nYes.\n")).pages[0].rows
                check(dualRows.count == 3 && dualRows[1].map(\.text) == ["No.", "Yes."] && dualRows[2].map(\.text) == ["Not again."],
                      "screenplay: dual dialogue sits side by side, keeping each speech's own lines")
                func plain(_ elements: [Fountain.Element]) -> [String] { elements.map { "\($0.kind)|\($0.text)|\($0.dual)" } }
                let again = read.map { plain(Fountain.document(FinalDraft.fountain($0)).elements) }
                check(again == plain(Fountain.document(store.fileText(at: book.document!.url)).elements),
                      "screenplay: Final Draft and back gives the same script")
                choices.format = .fountain
                let fountainURL = out.appendingPathComponent("s.fountain")
                try? Exporter.exportScreenplay(book, store: store, choices: choices, to: fountainURL)
                check(disk(fountainURL).hasPrefix("Title: NIGHT FERRY\nCredit: Written by\nAuthor: Ruth Calder\n")
                      && disk(fountainURL).hasSuffix(store.fileText(at: book.document!.url)),
                      "screenplay: the Fountain export is the file with a title page at its head")

                // Import: a Final Draft file becomes a new screenplay story.
                let fdx = """
                <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
                <FinalDraft DocumentType="Script" Template="No" Version="4">
                <Content>
                <Paragraph Type="Scene Heading" Number="1"><SceneProperties Length="1/8" Page="1" Title=""/><Text>INT. HOUSE - DAY</Text></Paragraph>
                <Paragraph Type="Action"><Text>A door </Text><Text Style="Bold">slams</Text><Text>.</Text></Paragraph>
                <Paragraph Number="1A" Type="Scene Heading"><Text Style="Bold">EXT. YARD - DAY</Text><Text></Text></Paragraph>
                <Paragraph Type="Action"><Text>A line wrapped by an old
                </Text><Text>import.</Text></Paragraph>
                <Paragraph Type="Character"><Text>Anna</Text></Paragraph>
                <Paragraph Type="Parenthetical"><Text>(to herself)</Text></Paragraph>
                <Paragraph Type="Dialogue"><Text>Not again.</Text><ScriptNote><Paragraph><Text>a note</Text></Paragraph></ScriptNote></Paragraph>
                <Paragraph Type="Transition"><Text>Dissolve</Text></Paragraph>
                <Paragraph Type="Shot"><Text>ANGLE ON THE DOOR</Text></Paragraph>
                <Paragraph><DualDialogue>
                <Paragraph Type="Character"><Text>BRICK</Text></Paragraph><Paragraph Type="Dialogue"><Text>No.</Text></Paragraph>
                <Paragraph Type="Character"><Text>STEEL</Text></Paragraph><Paragraph Type="Dialogue"><Text>No.</Text></Paragraph>
                </DualDialogue></Paragraph>
                <Paragraph Type="Action" StartsNewPage="Yes"><Text>Later.</Text></Paragraph>
                </Content>
                <TitlePage><Content>
                <Paragraph Alignment="Center"><Text>THE HOUSE</Text></Paragraph>
                <Paragraph Alignment="Center"><Text>Written by</Text></Paragraph>
                <Paragraph Alignment="Center"><Text>A. Writer</Text></Paragraph>
                <Paragraph Alignment="Left"><Text>a@example.com</Text></Paragraph>
                </Content></TitlePage>
                </FinalDraft>
                """
                let fdxIn = out.appendingPathComponent("The House.fdx")
                try? fdx.write(to: fdxIn, atomically: true, encoding: .utf8)
                let imported = store.importFinalDraft(from: fdxIn)
                let importedText = disk(imported)
                let importedDoc = Fountain.document(importedText)
                check(imported?.pathExtension == "fountain" && newest()?.title == "The House" && newest()?.isScreenplay == true,
                      "import: a Final Draft file becomes a new screenplay story")
                check(importedDoc.elements.map(\.kind) == [.sceneHeading, .action, .sceneHeading, .action, .character, .parenthetical, .dialogue, .transition, .action,
                                                          .character, .dialogue, .character, .dialogue, .pageBreak, .action]
                      && importedDoc.elements[0].sceneNumber == "1" && importedDoc.elements[1].text == "A door **slams**."
                      && importedDoc.elements[4].text == "ANNA" && importedDoc.elements[7].text == "DISSOLVE"
                      && importedDoc.elements[11].dual && !importedText.contains("a note"),
                      "import: headings, numbers, styles, names, transitions, shots, dual dialogue and page breaks come across; notes don't")
                check(importedDoc.elements[2].sceneNumber == "1A" && Fountain.headings(in: importedText).map(\.title)[1] == "EXT. YARD - DAY"
                      && Fountain.headings(in: importedText).map(\.number) == ["1", "1A"],
                      "import: a heading set in bold stays a heading, with its number (owner's script, 2026-11-14)")
                check(importedDoc.elements[3].text == "A line wrapped by an old import.",
                      "import: a line break inside a Final Draft paragraph becomes a space")
                check(importedDoc.title("Title") == ["THE HOUSE"] && importedDoc.title("Author") == ["A. Writer"] && importedDoc.title("Contact") == ["a@example.com"],
                      "import: the title page comes across as Fountain keys")
                check(store.importFinalDraft(from: out.appendingPathComponent("s.pdf")) == nil, "import: a file that isn't Final Draft's is refused")

                // Renaming keeps it a screenplay.
                store.rename(ManuscriptItem(url: book.url, title: book.title, order: book.order, kind: .book), to: "Night Boat")
                let renamed = store.library?.books.first { $0.title == "Night Boat" }
                check(renamed?.document?.url.lastPathComponent == "Night Boat.fountain" && renamed?.isScreenplay == true,
                      "screenplay: renaming the story renames its .fountain file")

                // The story's page lists its contents; for a screenplay that line is the
                // story itself. Choosing it must open the script, not the text as prose
                // (owner, 2026-11-16: "it reverts to normal prose when I start writing").
                if let script = renamed?.document, let own = renamed?.chapters.first(where: \.implicit) {
                    store.selection = .chapter(own.url)
                    await settle(400)
                    let font = (margin.textView?.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                    check(store.selection == .scene(script.url)
                          && font?.fontName.hasPrefix("CourierPrime") == true,
                          "screenplay: choosing the story's own contents opens the script, in Courier Prime (\(font?.fontName ?? "none"))")
                }
            }

            // A scene with comments, then a screenplay: no highlights carried over.
            if let commented = store.library?.books.flatMap({ $0.chapters.flatMap(\.scenes) }).first(where: { margin.readComments(for: $0.url).contains { !$0.resolved } }),
               let other = store.library?.books.first(where: \.isScreenplay)?.document {
                store.selection = .scene(commented.url)
                await settle()
                let before = (margin.textView as? HighlightTextView)?.highlights.count ?? 0
                store.selection = .scene(other.url)
                await settle()
                let after = (margin.textView as? HighlightTextView)?.highlights.count ?? -1
                if let plainScene = store.library?.books.flatMap({ $0.chapters.flatMap(\.scenes) })
                    .first(where: { !$0.isScreenplay && margin.readComments(for: $0.url).isEmpty }) {
                    store.selection = .scene(commented.url)
                    await settle()
                    store.selection = .scene(plainScene.url)
                    await settle()
                    check((margin.textView as? HighlightTextView)?.highlights.isEmpty == true,
                          "comments: leaving a scene with comments for one without leaves no highlights behind")
                }
                check(before > 0 && after == 0, "screenplay: leaving a scene with comments leaves no highlights on the next page (\(before) → \(after))")
            }
            // ⌘R keeps your place: Write → Read shows the same part of the script; Read → Write
            // comes back to it.
            if let story = store.library?.books.first(where: \.isScreenplay), let doc = story.document {
                var long = "FADE IN:\n\n"
                for n in 1...40 { long += "INT. ROOM \(n) - DAY\n\nAction in room \(n) runs on for a line or two of text, enough to fill a page.\n\nMARA\nLine \(n).\n\n" }
                store.selection = .scene(doc.url)
                await settle(300)
                store.updateText(long)
                store.saveNow()
                await settle(400)
                if let page = margin.textView {
                    let target = (page.string as NSString).range(of: "INT. ROOM 30 - DAY")
                    page.setSelectedRange(NSRange(location: target.location, length: 0))
                    page.restore(Places.Place(caret: target.location, top: target.location))
                    await settle(200)
                    func sheets(in view: NSView?) -> SheetsView? {
                        guard let view else { return nil }
                        if let found = view as? SheetsView { return found }
                        for sub in view.subviews { if let found = sheets(in: sub) { return found } }
                        return nil
                    }
                    // The screenplay's own Read and Write pages.
                    store.setViewMode(.read)
                    await settle(600)
                    let window = NSApp.windows.first { sheets(in: $0.contentView) != nil }
                    let reading = sheets(in: window?.contentView)
                    let shown = reading?.topSource()
                    check(shown.map { abs($0 - target.location) < 200 } == true,
                          "⌘R: Read opens at the part of the script Write was showing (\(shown ?? -1) for \(target.location))")
                    reading?.show(source: (page.string as NSString).range(of: "INT. ROOM 10 - DAY").location)
                    await settle(200)
                    store.setViewMode(.write)
                    await settle(600)
                    let back = margin.textView.map { $0.currentPlace.top } ?? -1
                    let ten = (store.text as NSString).range(of: "INT. ROOM 10 - DAY").location
                    // At the top, perhaps with the end of the paragraph before it above.
                    let visible = margin.textView.map { page -> Bool in
                        guard let clip = page.enclosingScrollView?.contentView,
                              let line = page.lineRects(of: NSRange(location: ten, length: 0)).first else { return false }
                        return line.minY >= clip.bounds.minY - 1 && line.minY <= clip.bounds.minY + 120
                    } ?? false
                    check(visible && back <= ten, "⌘R: Write comes back at the part of the script Read was showing (\(back) for \(ten))")
                }
                store.selection = .scene(doc.url)
                await settle(200)
                store.showLibrary()
                check(store.openBook == nil && store.selection == .book(story.url),
                      "library: going back to the Library chooses the story you were in (its page, not its text)")
                store.selection = .scene(doc.url)
                store.places.opened(store.selection)
                await settle(200)
                store.openOnLibrary()
                check(store.openBook == nil && store.selection == .book(story.url),
                      "library: opening a library shows the Library, the story last open chosen")
            }
        }

        // MARK: The Boneyard (2026-11-14)

        do {
            func newest() -> Book? { store.library?.books.max { $0.order < $1.order } }
            store.createBook(title: "Bones", form: .novel, shape: .chaptersAndScenes)
            store.createSceneInContext()
            store.createSceneInContext()
            store.createChapterInContext()
            guard let book = newest(), book.chapters.count == 2, book.chapters[0].scenes.count == 3 else {
                check(false, "boneyard: a story with two chapters to cut from")
                write(lines, failures: failures, to: reportPath)
                return finish()
            }
            let chapter = book.chapters[0]
            let middle = chapter.scenes[1]
            store.selection = .scene(middle.url)
            await settle(300)
            store.updateText("A scene that will be cut.")
            store.saveNow()
            await settle(300)   // the page takes the new text
            if let page = margin.textView {
                page.setSelectedRange((page.string as NSString).range(of: "will be"))
                let made = margin.addCommentOnSelection()
                if let made { margin.setText("Keep this?", of: made.id); margin.focused = nil }
                margin.saveNow()
                check(made != nil, "boneyard: a comment on the scene to cut")
            }
            let wordsBefore = store.wordCount(of: book)
            store.moveToBoneyard(middle.url)
            await settle(300)
            let after = newest()
            let cut = after?.boneyard?.scenes.first
            check(cut?.url.deletingLastPathComponent().lastPathComponent == "Boneyard" && after?.chapters[0].scenes.count == 2
                  && disk(cut?.url) == "A scene that will be cut.",
                  "boneyard: Move to Boneyard puts the scene's file in the story's Boneyard folder, out of its chapter")
            check(after.map { store.wordCount(of: $0) } == wordsBefore - 6, "boneyard: a cut scene's words leave the story's count")
            check(cut.map { store.margin.info(for: $0.url).cut?.number } == "1.2" && cut.map { store.isCut($0.url) } == true
                  && cut.map { store.number(ofScene: $0.url) } == .some(nil),
                  "boneyard: it remembers it was 1.2, and has no number of its own")
            check(cut.map { margin.readComments(for: $0.url).first?.text } == "Keep this?", "boneyard: its comments go with it")
            check(selectedSceneURL == after?.chapters[0].scenes[1].url && store.contentsTab == .contents,
                  "boneyard: the scene beside it opens in its place, on the Contents tab")
            if let cutURL = cut?.url, let other = after?.chapters[0].scenes.first?.url {
                store.selection = .scene(cutURL)
                let onBoneyard = store.contentsTab == .boneyard
                store.selection = .scene(other)
                check(onBoneyard && store.contentsTab == .contents, "boneyard: the contents column shows the tab holding what's open")
            }
            if let cut, let root = store.libraryURL {
                check(!Git.isScene(String(cut.url.canonical.path.dropFirst(root.canonical.path.count + 1))),
                      "boneyard: Git's changes leave cut scenes out")
                let manuscript = Exporter.manuscript(of: after!, store: store)
                check(!manuscript.chapters.flatMap(\.blocks).contains { "\($0)".contains("will be cut") },
                      "boneyard: a cut scene is left out of export")
                store.restore(cut.url)
                await settle(300)
                let back = newest()
                check(back?.boneyard == nil && back?.chapters[0].scenes.count == 3 && back?.chapters[0].scenes[1].title == middle.title
                      && back.map { disk($0.chapters[0].scenes[1].url) } == "A scene that will be cut.",
                      "boneyard: Restore puts it back where it was (1.2)")
                if let returned = back?.chapters[0].scenes[1] {
                    check(store.margin.info(for: returned.url).cut == nil && margin.readComments(for: returned.url).first?.text == "Keep this?"
                          && selectedSceneURL == returned.url,
                          "boneyard: back in its chapter it is no longer marked as cut, keeps its comments, and opens")
                    store.moveToBoneyard(returned.url)
                    await settle(200)
                    if let again = newest()?.boneyard?.scenes.first, let second = newest()?.chapters[1] {
                        store.restore(again.url, into: second.url)
                        await settle(200)
                        check(newest()?.chapters[1].scenes.last?.title == middle.title && newest()?.chapters[0].scenes.count == 2,
                              "boneyard: Restore To puts it at the end of the chapter chosen")
                    }
                }
            }

            // A single document: a passage.
            store.createBook(title: "Lighthouse", form: .shortStory, shape: .document)
            guard let doc = newest(), let file = doc.document else { return finish() }
            store.updateText("First paragraph.\n\nThe radio had been dead since October.\n\nLast paragraph.")
            store.saveNow()
            await settle(200)
            let piece = store.addToBoneyard("The radio had been dead since October.", from: doc, before: "First paragraph.\n\n")
            store.updateText("First paragraph.\n\nLast paragraph.")
            store.saveNow()
            check(piece?.lastPathComponent == "The radio had been dead since.md" && newest()?.boneyard?.scenes.count == 1,
                  "boneyard: a passage cut from a document is kept there, named by its first words")
            if let piece {
                store.restore(piece)
                await settle(200)
                check(disk(file.url) == "First paragraph.\n\nThe radio had been dead since October.\n\nLast paragraph."
                      && newest()?.boneyard == nil,
                      "boneyard: Restore puts a passage back after the text it followed, and empties the Boneyard")
            }
        }

        // MARK: The Boneyard: a chapter in it, and the view each document keeps (2026-11-15)

        do {
            func newest() -> Book? { store.library?.books.max { $0.order < $1.order } }
            store.createBook(title: "Marram", form: .novel, shape: .chaptersAndScenes)
            store.createChapterInContext()
            store.createChapterInContext()
            guard let book = newest(), book.chapters.count == 3 else {
                check(false, "boneyard: a story with three chapters to cut from")
                write(lines, failures: failures, to: reportPath)
                return finish()
            }
            let titles = book.chapters.map(\.title)
            let second = book.chapters[1]
            let words = store.wordCount(of: second)
            let whole = store.wordCount(of: book)
            store.selection = .chapter(second.url)
            await settle(200)
            store.moveChapterToBoneyard(second.url)
            await settle(400)
            let after = newest()
            let cut = after?.boneyardChapters.first
            check(cut?.url.deletingLastPathComponent().lastPathComponent == "Boneyard"
                  && after?.chapters.count == 2
                  && after?.chapters.map(\.title) == [titles[0], titles[2]],
                  "boneyard: a chapter cut from the story is kept whole in its Boneyard, out of the manuscript")
            check(after.map { store.wordCount(of: $0) } == whole - words,
                  "boneyard: a cut chapter's words leave the story's count")
            check(cut.map { store.margin.info(for: $0.url).cut?.number } == "2"
                  && after?.chapters.first?.url.lastPathComponent == FileNaming.name(order: 1, title: titles[0]),
                  "boneyard: it remembers it was chapter 2, and the chapters that stay are numbered as they stand")
            if let cut {
                store.restoreChapter(cut.url)
                await settle(400)
                let back = newest()
                check(back?.boneyardChapters.isEmpty == true
                      && back?.chapters.count == 3
                      && back?.chapters.map(\.title) == titles
                      && back?.chapters.map { $0.url.lastPathComponent } == titles.enumerated().map { FileNaming.name(order: $0.offset + 1, title: $0.element) },
                      "boneyard: Restore puts the chapter back where it was, and numbers the chapters as they stand")
            }
        }

        do {
            // The view each document is shown in is remembered for that document.
            func newest() -> Book? { store.library?.books.max { $0.order < $1.order } }
            let forced = ViewModes.forcedChapter
            ViewModes.forcedChapter = nil
            defer { ViewModes.forcedChapter = forced }
            if let book = newest(), book.chapters.count >= 2 {
                let first = book.chapters[0], second = book.chapters[1]
                store.selection = .chapter(first.url)
                await settle(200)
                check(store.viewMode == .read, "view: a chapter opens to read")
                store.setViewMode(.write)
                check(store.viewMode == .write, "view: the chapter can be shown for writing")
                store.selection = .chapter(second.url)
                await settle(200)
                check(store.viewMode == .read, "view: another chapter keeps its own view")
                store.selection = .chapter(first.url)
                await settle(200)
                check(store.viewMode == .write, "view: the chapter is shown the way it was left")
                store.toggleCards()
                check(store.viewMode == .cards, "view: the cards are a view of their own")
                store.toggleCards()
                check(store.viewMode == .write, "view: the cards give back the page they came from")
                // A story: its contents page, its whole story, its cards.
                store.selection = .book(book.url)
                store.openBook = book.url
                await settle(200)
                check(store.viewMode == .contents, "view: a story opens on its contents page")
                store.setViewMode(.page)
                store.selection = .chapter(first.url)
                await settle(200)
                store.selection = .book(book.url)
                await settle(200)
                check(store.viewMode == .page, "view: the story is shown the way it was left")
            } else {
                check(false, "view: a story with two chapters")
            }
        }

        do {
            // ⇧⌘⌫ sends what is chosen to the Boneyard.
            func newest() -> Book? { store.library?.books.max { $0.order < $1.order } }
            if let book = newest(), let scene = book.chapters.first?.scenes.first {
                let count = book.chapters.first?.scenes.count ?? 0
                store.selection = .scene(scene.url)
                await settle(200)
                check(store.canMoveSelectionToBoneyard, "boneyard: the chosen scene can be sent to the Boneyard")
                store.moveSelectionToBoneyard()
                await settle(300)
                let cut = newest()?.boneyard?.scenes.first { $0.title == scene.title }
                check(cut?.url.deletingLastPathComponent().lastPathComponent == "Boneyard"
                      && newest()?.chapters.first?.scenes.count == count - 1,
                      "boneyard: ⇧⌘⌫ sends the chosen scene to the Boneyard")
            } else {
                check(false, "boneyard: a scene to send to the Boneyard")
            }
        }

        // MARK: Cards (2026-11-14)

        do {
            let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")
            let other = URL(fileURLWithPath: "/x")
            check(CardDrag.index(dropping: a, on: b, in: [a, b, c]) == 1,
                  "cards: a card dropped on the next one moves one place on")
            check(CardDrag.index(dropping: c, on: a, in: [a, b, c]) == 0 && CardDrag.index(dropping: c, on: b, in: [a, b, c]) == 1,
                  "cards: a card dropped on an earlier one takes its place, before it")
            check(CardDrag.index(dropping: other, on: b, in: [a, b, c]) == 1 && CardDrag.index(dropping: a, on: a, in: [a, b, c]) == nil,
                  "cards: from another chapter a card lands before the one it is dropped on; on itself, nowhere")
            check(CardDrag.neighbour(of: a, dx: 0, dy: 1, lists: [[a, b, c]], gridColumns: 2) == c
                  && CardDrag.neighbour(of: b, dx: 1, dy: 0, lists: [[a, b, c]], gridColumns: 2) == c
                  && CardDrag.neighbour(of: c, dx: 0, dy: 1, lists: [[a, b, c]], gridColumns: 2) == nil,
                  "cards: arrow keys move across and down a grid")
            check(CardDrag.neighbour(of: b, dx: 1, dy: 0, lists: [[a, b], [], [c]], gridColumns: nil) == c
                  && CardDrag.neighbour(of: nil, dx: 1, dy: 0, lists: [[], [c]], gridColumns: nil) == c,
                  "cards: on a story's board, across skips empty chapters; with none chosen, the first card")
            let path = CardDrag.payload(scene: a)
            check(CardDrag.scene(in: path) == a.canonical && CardDrag.scene(in: CardDrag.payload(chapter: a)) == nil
                  && CardDrag.chapter(in: CardDrag.payload(chapter: a)) == a.canonical,
                  "cards: a dragged scene and a dragged chapter are told apart (the Boneyard tab takes only scenes)")
            check(CardSize.allCases.map(\.title) == ["Small", "Medium", "Large"] && CardSize.small.gridMin < CardSize.large.gridMin,
                  "cards: three sizes")
        }

        do {
            func newest() -> Book? { store.library?.books.max { $0.order < $1.order } }
            store.createBook(title: "Docks", form: .novel, shape: .chapters)
            store.createChapterInContext()
            store.createChapterInContext()
            if let book = newest(), book.shape == .chapters, book.chapters.count == 3,
               book.chapters.allSatisfy({ $0.scenes.count == 1 }) {
                let titles = book.chapters.map(\.title)
                let files = book.chapters.map { $0.scenes[0].url }
                check(store.number(ofScene: files[1]) == "2", "cards: a chapters-only story's cards are numbered 1, 2, 3")
                check(!store.canMoveToBoneyard(files[0]), "cards: a chapters-only chapter can't be dropped on the Boneyard")
                // Dropping the first chapter's card on the third's: it takes the third's place.
                let urls = book.chapters.map(\.url)
                if let index = CardDrag.index(dropping: urls[0], on: urls[2], in: urls) {
                    store.placeChapter(urls[0], at: index)
                }
                let after = newest()
                check(after?.chapters.map(\.title) == [titles[1], titles[2], titles[0]]
                      && after?.chapters.allSatisfy({ $0.scenes.count == 1 }) == true,
                      "cards: dropping a chapter's card moves the whole chapter, each keeping its one file")
                if let moved = after?.chapters.last?.scenes.first {
                    var info = margin.info(for: moved.url)
                    info.label = .purple
                    margin.setInfo(info, for: moved.url)
                    margin.saveNow()
                    let relative = String(moved.url.deletingPathExtension().path.dropFirst(store.library!.url.canonical.path.count + 1))
                    let file = store.library!.url.appendingPathComponent(".longhand/scenes/\(relative).json")
                    let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SceneInfo.self, from: $0) }
                    check(read?.label == .purple, "cards: a card's label is kept with the scene's details")
                    info.label = nil
                    margin.setInfo(info, for: moved.url)
                }
            } else {
                check(false, "cards: a chapters-only story with three chapters")
            }

            store.createBook(title: "Gulls", form: .shortStory, shape: .scenes)
            if let book = newest(), let loose = book.chapters.first {
                let before = store.selection
                let made = store.createScene(inChapter: loose.url, open: false)
                check(made != nil && store.selection == before && newest()?.chapters.first?.scenes.contains { $0.url == made } == true,
                      "cards: New Scene on the cards adds a scene without leaving them")
            } else {
                check(false, "cards: a scenes-only story")
            }
        }

        // MARK: Author profiles

        if let book = store.library?.books.first {
            let authors = AuthorProfiles()
            check(authors.all.isEmpty, "authors: a hidden run starts with none and never reads the owner's")
            var info = SceneInfo()
            info.authorName = "Ada Writer"
            info.authorEmail = "ada@example.com"
            let adopted = authors.settle(info)
            check(authors.all.count == 1 && adopted.authorProfile == authors.all.first?.id && adopted.authorName == "Ada Writer",
                  "authors: a story's own details become a profile")
            check(authors.settle(info).authorProfile == adopted.authorProfile && authors.all.count == 1,
                  "authors: the same details reuse the profile")
            var changed = authors.all[0]
            changed.penName = "A. W. Pen"
            authors.update(changed)
            let refreshed = authors.settle(adopted)
            check(refreshed.authorPenName == "A. W. Pen" && refreshed.authorName == "Ada Writer",
                  "authors: changing a profile changes the story's details")
            let gone = authors.all[0].id
            authors.remove(gone)
            let kept = authors.settle(refreshed)
            check(authors.all.isEmpty && kept.authorName == "Ada Writer" && kept.authorProfile == AuthorProfiles.detached
                  && authors.settle(kept) == kept,
                  "authors: removing an author leaves stories their details and doesn't bring the author back")
            var none = refreshed
            none.setAuthor(nil)
            check(none.hasNoAuthor && none.authorProfile == nil, "authors: choosing None clears the details")
            store.margin.setInfo(refreshed, for: book.url)
            store.margin.saveNow()
            check(store.margin.info(for: book.url).authorProfile == adopted.authorProfile, "authors: the story remembers its profile")
            var cleared = store.margin.info(for: book.url)
            cleared.setAuthor(nil)
            store.margin.setInfo(cleared, for: book.url)
        }

        // MARK: Cropping a cover

        if let book = store.library?.books.first {
            // A picture 300 wide and 200 tall: left half red, right half blue.
            let file = fm.temporaryDirectory.appendingPathComponent("LonghandCover-\(UUID().uuidString).png")
            if let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
                context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
                context.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
                if let made = context.makeImage() {
                    try? NSBitmapImageRep(cgImage: made).representation(using: .png, properties: [:])?.write(to: file)
                }
            }
            // The picture's average colour, by drawing it into one known RGBA pixel.
            func middle(_ image: NSImage?) -> (red: CGFloat, blue: CGFloat) {
                guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (0, 0) }
                var pixel = [UInt8](repeating: 0, count: 4)
                guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (0, 0) }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return (CGFloat(pixel[0]) / 255, CGFloat(pixel[2]) / 255)
            }
            check(store.margin.setCover(of: book.url, from: file), "cover: a picture becomes the cover")
            let whole = store.margin.coverSource(of: book.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            check(whole?.width == 300 && whole?.height == 200, "cover: the whole picture is kept")
            let cover = store.margin.cover(of: book.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            check(cover.map { abs(Double($0.height) / Double($0.width) - 1.6) < 0.02 } == true, "cover: it has the cover's shape")
            // The left end of the picture: red in the middle of the cover. Then the right: blue.
            store.margin.cropCover(of: book.url, to: CGRect(x: 0, y: 0, width: 125.0 / 300, height: 1))
            check(middle(store.margin.cover(of: book.url)).red > 0.8, "cover: cropping to the left shows the left")
            store.margin.cropCover(of: book.url, to: CGRect(x: 175.0 / 300, y: 0, width: 125.0 / 300, height: 1))
            check(middle(store.margin.cover(of: book.url)).blue > 0.8, "cover: cropping again uses the whole picture")
            let unit = CoverCropSheet.unit(window: CGSize(width: 100, height: 160), shown: CGSize(width: 240, height: 160),
                                           offset: CGSize(width: 70, height: 0))
            check(abs(unit.minX) < 0.001 && abs(unit.width - 100.0 / 240) < 0.001 && abs(unit.height - 1) < 0.001,
                  "cover: dragging the picture right shows its left edge")
            store.margin.removeCover(of: book.url)
            check(store.margin.cover(of: book.url) == nil && store.margin.coverSource(of: book.url) == nil,
                  "cover: removing it removes the kept picture too")
            store.margin.setCover(of: book.url, from: file, cropTo: CGRect(x: 0, y: 0, width: 125.0 / 300, height: 1))
            check(middle(store.margin.cover(of: book.url)).red > 0.8, "cover: setting with cropTo crops on initial set")
            store.margin.removeCover(of: book.url)
            // A photograph's worth of pixels is kept at a cover's worth.
            if let context = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
               let image = context.makeImage(),
               let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]) {
                let big = fm.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).jpg")
                try? jpeg.write(to: big)
                store.margin.setCover(of: book.url, from: big)
                let kept = store.margin.coverSource(of: book.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let cut = store.margin.cover(of: book.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                check(kept?.width == 2400 && kept?.height == 1600, "cover: a large picture is kept at 2400 pixels on its longer side")
                check((cut?.width ?? 9999) <= 1600, "cover: the cover itself is never wider than 1600 pixels")
                store.margin.removeCover(of: book.url)
                try? fm.removeItem(at: big)
            }
            try? fm.removeItem(at: file)
        }

        // MARK: Getting a library from a backup (a local one; never GitHub)

        do {
            let origin = fm.temporaryDirectory.appendingPathComponent("LonghandFetch-\(UUID().uuidString)")
            let source = origin.appendingPathComponent("source"), bare = origin.appendingPathComponent("kept.git")
            let place = origin.appendingPathComponent("place")
            try? fm.createDirectory(at: source.appendingPathComponent("01 Story/01 One"), withIntermediateDirectories: true)
            try? fm.createDirectory(at: place, withIntermediateDirectories: true)
            try? "Fetched words.".write(to: source.appendingPathComponent("01 Story/01 One/01 Scene.md"), atomically: true, encoding: .utf8)
            Git.run(["init", "-q"], in: source)
            Git.run(["add", "-A"], in: source)
            Git.run(["-c", "user.name=Test", "-c", "user.email=test@longhand.local", "commit", "-q", "-m", "v1"], in: source)
            Git.run(["clone", "-q", "--bare", source.path, bare.path], in: origin)
            let fetched = Git.fetchLibrary(from: bare.path, named: "My Library", into: place)
            let scene = fetched.folder?.appendingPathComponent("01 Story/01 One/01 Scene.md")
            check(disk(scene) == "Fetched words.", "get library: the scenes arrive")
            check(fetched.folder.map { fm.fileExists(atPath: $0.appendingPathComponent(".longhand").path) } == true,
                  "get library: it opens as a library without asking")
            check(fetched.folder.flatMap(Git.remoteURL) == bare.path, "get library: it stays connected to its backup")
            let again = Git.fetchLibrary(from: bare.path, named: "My Library", into: place)
            check(again.folder == nil && again.problem != nil && disk(scene) == "Fetched words.",
                  "get library: never writes into a folder that is already there")
            let missing = Git.fetchLibrary(from: origin.appendingPathComponent("nothing.git").path, named: "Other", into: place)
            check(missing.folder == nil && !fm.fileExists(atPath: place.appendingPathComponent("Other").path),
                  "get library: a failed fetch leaves nothing behind")
            try? fm.removeItem(at: origin)
        }

        // MARK: A scene saved by another app in an older encoding

        // It used to open blank, and the first words typed then replaced the file.
        // The tests above can leave the first book without scenes; these last two need some.
        func anyScenes() -> [Scene] { store.library?.books.flatMap(\.chapters).flatMap(\.scenes) ?? [] }
        if anyScenes().count < 2 {
            store.createBook()
            store.createSceneInContext()
        }
        check(anyScenes().count >= 2, "there are scenes left for the last checks")
        if let scene = anyScenes().last, let other = anyScenes().first, scene.url != other.url {
            store.selection = .scene(other.url)
            let foreign = "Café at the déjà vu, where the naïve façade fell."
            try? foreign.data(using: .windowsCP1252)?.write(to: scene.url)
            check((try? String(contentsOf: scene.url, encoding: .utf8)) == nil, "foreign file: not UTF-8 on disk")
            store.selection = .scene(scene.url)
            check(store.text == foreign, "foreign file: opens with its words, not blank")
            store.updateText(foreign + " More.")
            store.saveNow()
            check(disk(scene.url) == foreign + " More.", "foreign file: saved with its words kept")
            try? Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00]).write(to: other.url)
            check(String.prose(at: other.url) == "Hi", "foreign file: UTF-16 is read")
        }

        // MARK: Quitting straight after typing saves

        if let scene = anyScenes().last {
            store.selection = .scene(scene.url)
            store.updateText("last words before quitting")
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            check(disk(scene.url) == "last words before quitting", "quitting straight after typing saves")

        }

        // MARK: Refinements of 2026-11-12

        do {
            // Scene numbers follow position.
            if let chapter = chapters().first, let last = chapter.scenes.last, chapter.scenes.count >= 2 {
                check(store.number(ofScene: chapter.scenes[0].url) == "1.1"
                      && store.number(ofScene: last.url) == "1.\(chapter.scenes.count)", "scenes are numbered by chapter and place")
                store.move(ManuscriptItem(url: last.url, title: last.title, order: last.order, kind: .scene), by: -1)
                let moved = chapters().first?.scenes.first { $0.title == last.title }
                check(moved.flatMap { store.number(ofScene: $0.url) } == "1.\(chapter.scenes.count - 1)",
                      "a moved scene takes the number of its new place")
            }

            // Numbers off on the story's page hides scene numbers everywhere.
            if let book = store.library?.books.first(where: { $0.chapters.contains { !$0.scenes.isEmpty && !$0.implicit } }),
               let chapter = book.chapters.first(where: { !$0.scenes.isEmpty }), let scene = chapter.scenes.first {
                let shown = store.number(ofScene: scene.url)
                var info = store.margin.info(for: book.url)
                info.hideChapterNumbers = true
                store.margin.setInfo(info, for: book.url)
                check(shown != nil && store.number(ofScene: scene.url) == nil && store.shownNumber(ofChapter: chapter.url) == nil,
                      "with Numbers off, scenes and chapters carry no number")
                info.hideChapterNumbers = nil
                store.margin.setInfo(info, for: book.url)
                check(store.number(ofScene: scene.url) == shown, "and they come back with Numbers on")
            } else {
                check(false, "there is a scene to number")
            }

            // Inside a story, New Scene and New Chapter never make a story; with nothing
            // chosen they use the story the contents is inside.
            let stories = store.library?.books.count ?? 0
            if let book = store.library?.books.first {
                store.selection = nil
                store.openBook = book.url
                let before = book.chapters.count
                store.createChapterInContext()
                check(store.library?.books.count == stories && store.library?.books.first?.chapters.count == before + 1,
                      "New Chapter adds a chapter to the open story, never a story")
                check(store.openBook == book.url, "choosing a scene keeps the contents inside its story")
            }
            store.selection = nil
            store.openBook = nil
            store.createSceneInContext()
            store.createChapterInContext()
            check(store.library?.books.count == stories, "in the Library, New Scene and New Chapter do nothing")

            // Chapters can be put anywhere among their story's chapters (dragging in the contents).
            if let only = store.library?.books.first, only.chapters.count < 2, let scene = only.chapters.first?.scenes.first {
                store.selection = .scene(scene.url)
                store.createChapterInContext()
                store.rename(ManuscriptItem(url: store.library?.books.first?.chapters.last?.url ?? only.url, title: "Untitled Chapter", order: 2, kind: .chapter), to: "Second")
            }
            check((store.library?.books.first?.chapters.count ?? 0) >= 2, "there are two chapters to reorder")
            if let book = store.library?.books.first, book.chapters.count >= 2 {
                let names = book.chapters.map(\.title)
                let bookURL = book.url
                store.placeChapter(book.chapters[book.chapters.count - 1].url, at: 0)
                let after = store.book(for: bookURL)?.chapters.map(\.title) ?? []
                check(after == [names[names.count - 1]] + names.dropLast(), "a chapter dragged to the top lands first, the rest in order")
                if let moved = store.book(for: bookURL)?.chapters.first {
                    store.placeChapter(moved.url, at: names.count - 1)
                    check(store.book(for: bookURL)?.chapters.map(\.title) == names, "and back to the end")
                }
            }

            // The reading view: symbols gone, breaks as asterisks, the scene's own name not repeated.
            let read = ChapterReader.readable("# Arrival\n\nShe walked.\n\n---\n\nShe stopped.\n\n***\n", sceneTitle: "arrival")
            check(read == "She walked.\n* * *\nShe stopped.", "reading view: breaks are * * *, blank lines and the repeated title are left out")
            let pageText = ChapterReader.page(title: "Low Water", number: 1, scenes: [
                ChapterSceneText(id: 0, url: URL(fileURLWithPath: "/a.md"), title: "A", text: "One **bold** word."),
                ChapterSceneText(id: 1, url: URL(fileURLWithPath: "/b.md"), title: "B", text: ""),
                ChapterSceneText(id: 2, url: URL(fileURLWithPath: "/c.md"), title: "C", text: "> Quoted.")
            ]).string
            check(pageText.contains("One bold word.\n* * *\nQuoted.") && !pageText.contains("**"),
                  "reading view: Markdown symbols are gone and one break sits between scenes with text")

            // Comments on the reading page: a place in a scene's Markdown is found on the page and back.
            let markdownA = "# A\n\nOne **bold** word.\n\n---\n\nTwo _soft_ lines." as NSString
            let urlA = URL(fileURLWithPath: "/a.md"), urlB = URL(fileURLWithPath: "/b.md")
            let reading = ChapterReader.reading(title: "Low Water", number: 1, scenes: [
                ChapterSceneText(id: 0, url: urlB, title: "B", text: "First scene."),
                ChapterSceneText(id: 1, url: urlA, title: "A", text: markdownA as String)
            ])
            let readText = reading.page.string as NSString
            func shown(_ word: String, _ url: URL) -> String? {
                reading.maps[url]?.page(markdownA.range(of: word)).map { readText.substring(with: $0) }
            }
            check(shown("bold", urlA) == "bold" && shown("**bold**", urlA) == "bold" && shown("soft_ lines", urlA) == "soft lines",
                  "reading view: a comment's passage is found on the page, its symbols left out")
            if let map = reading.maps[urlA] {
                let picked = map.source(readText.range(of: "soft lines"))
                check(markdownA.substring(with: picked) == "soft_ lines",
                      "reading view: a passage chosen on the page is found in the scene's Markdown")
                check(!map.covers(readText.range(of: "First scene")) && reading.maps[urlB]?.covers(readText.range(of: "First scene")) == true,
                      "reading view: a selection belongs to the scene it lies in")
            } else {
                check(false, "reading view: each scene with text has a map")
            }

            // No window tabs, so no Show Tab Bar or Show All Tabs in the menus.
            check(!NSWindow.allowsAutomaticWindowTabbing, "menus: no window-tab commands (Longhand has no tabs)")
            // ⌘W closes the window (Longhand's File menu had replaced the system's Close).
            func items(_ menu: NSMenu?) -> [NSMenuItem] { (menu?.items ?? []).flatMap { [$0] + items($0.submenu) } }
            let close = items(NSApp.mainMenu).first { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command }
            check(close?.title == "Close Window", "menus: ⌘W is Close Window")
            let find = items(NSApp.mainMenu).first { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == .command }
            check(find?.title == "Find…", "menus: ⌘F is Find…")
            let findNext = items(NSApp.mainMenu).first { $0.keyEquivalent == "g" && $0.keyEquivalentModifierMask == .command }
            check(findNext?.title == "Find Next", "menus: ⌘G is Find Next")
            let findPrev = items(NSApp.mainMenu).first { $0.keyEquivalent == "g" && $0.keyEquivalentModifierMask == [.command, .shift] }
            check(findPrev?.title == "Find Previous", "menus: ⇧⌘G is Find Previous")
            // A hidden run never puts Longhand in the owner's menu bar.
            let barItems = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") && $0.frame.height > 0 }
            check(Updates.version(of: "v0.9.5-beta") == "0.9.5" && Updates.version(of: "v0.9.7a-beta") == "0.9.7a"
                  && Updates.isNewer("0.9.5", than: "0.9.4")
                  && Updates.isNewer("0.10.0", than: "0.9.4") && Updates.isNewer("1.0", than: "0.9.9")
                  && !Updates.isNewer("0.9.4", than: "0.9.4") && !Updates.isNewer("0.9.3", than: "0.9.4")
                  && !Updates.isNewer("0.9.7", than: "0.9.7a")
                  && Updates.isNewer("0.9.7a", than: "0.9.7") && Updates.isNewer("0.9.8", than: "0.9.7a")
                  && !Updates.isNewer("0.9.7a", than: "0.9.7a"),
                  "updates: release tags are read and versions compared number by number, a letter after")
            let sampleRelease = #"{"tag_name":"v0.9.5-beta","html_url":"https://github.com/spec-proj/longhand/releases/tag/v0.9.5-beta","assets":[{"name":"Longhand.zip","browser_download_url":"https://github.com/spec-proj/longhand/releases/download/v0.9.5-beta/Longhand.zip"}]}"#
            let parsed = Updates.release(from: Data(sampleRelease.utf8))
            check(parsed?.version == "0.9.5" && parsed?.download?.lastPathComponent == "Longhand.zip" && parsed?.page.lastPathComponent == "v0.9.5-beta",
                  "updates: GitHub's answer gives the version, its page and the zip")
            check(Updates.shared.available == nil, "updates: a hidden run never asks GitHub")
            check(barItems.isEmpty, "menu bar: a hidden run shows no menu bar item"
                  + (barItems.isEmpty ? "" : " (\(barItems.map { "\(type(of: $0)) visible=\($0.isVisible) frame=\($0.frame)" }))"))
            check(BookForm.allCases.map(\.title) == ["Novel", "Novella", "Short Story", "Poetry", "Lyrics", "Essay", "Screenplay", "Notebook"],
                  "story: the forms are Novel, Novella, Short Story, Poetry, Lyrics, Essay, Screenplay, Notebook")
            check(NewDocumentSheet.forms == BookForm.allCases, "new document: the list has every form, in order")
            check(Set(BookForm.allCases.map { CoverColours.of($0).fill.description }).count == BookForm.allCases.count,
                  "covers: every form has a colour of its own")
            check(CoverColours.of(.screenplay).brads && !CoverColours.of(.novel).brads, "covers: only a screenplay has fasteners")
            check(NewDocumentSheet.suggestedShape(for: .shortStory, collection: false) == .document
                  && NewDocumentSheet.suggestedShape(for: .shortStory, collection: true) == .chapters
                  && NewDocumentSheet.suggestedShape(for: .poetry, collection: true) == .scenes
                  && NewDocumentSheet.suggestedShape(for: .poetry, collection: false) == .document
                  && NewDocumentSheet.suggestedShape(for: .essay, collection: true) == .chapters,
                  "new document: a collection of stories or essays has a chapter each, of poems a file each; one piece is one document")
            check(PartNames.of(.shortStory, collection: true).chapters == "Stories" && PartNames.of(.shortStory).chapters == "Chapters"
                  && PartNames.of(.poetry).scenes == "Poems" && PartNames.of(.lyrics).scenes == "Songs"
                  && PartNames.of(.essay, collection: true).chapter == "Essay",
                  "new document: a collection names its parts after its pieces")
            check(BookForm.shortStory.title(collection: true) == "Short Story Collection" && BookForm.poetry.title(collection: false) == "Poem"
                  && BookForm.novel.title(collection: true) == "Novel",
                  "story: the Form menu names a collection, or one poem")
            // Verse (owner, 2026-11-14): lines kept as written, stanzas apart, a song's labels.
            let poemText = "# Low Water\n\nThe sea goes out\n    the way a guest leaves,\n\n[Chorus]\nWhat it *leaves*: a boot.\n"
            let verseBook = ManuscriptBuilder.make(title: "Tide Tables", chapters: [(title: "Estuary", scenes: [
                (title: "Low Water", text: poemText), (title: "Mudlark", text: "Knees in the silt.\n")])],
                words: 20, verse: true, poemPerPage: true)
            let verseBlocks = verseBook.chapters.first?.blocks ?? []
            let stanzas = verseBlocks.compactMap { block -> [ManuscriptBook.VerseLine]? in
                if case .stanza(let lines) = block { return lines }
                return nil
            }
            check(stanzas.count == 3 && stanzas[0].count == 2 && stanzas[0][1].indent == 4
                  && stanzas[1].first?.label == true && stanzas[1].first?.runs.first?.text == "Chorus",
                  "verse: export keeps each line, its indent, and a song's label")
            check(verseBlocks.first == .heading([ManuscriptBook.Run(text: "Low Water")]) && verseBlocks.contains(.pageBreak)
                  && !verseBlocks.contains(.sceneBreak),
                  "verse: each poem under its title, on a new page, with no scene breaks")
            check(verseBook.lineCount == 4 && verseBook.lengthLine == "4 lines", "verse: a poetry manuscript counts lines, not words")
            var verseNotes: [[ManuscriptBook.Run]] = []
            let verseXML = DocxWriter.document(verseBook, ExportSettings(), notes: &verseNotes)
            check(verseXML.contains("w:hanging=\"720\"") && verseXML.contains("<w:pageBreakBefore/>") && verseXML.contains("4 lines"),
                  "verse: the Word file sets lines single, hanging, a poem to a page")
            let prose = ManuscriptBuilder.blocks(from: "One line\nand the next.", sceneTitle: "X")
            check(prose == [.paragraph([ManuscriptBook.Run(text: "One line and the next.")], opening: false)],
                  "verse: prose still joins its lines into paragraphs")
            check(LiveCount.verseLines(in: poemText) == 3, "verse: the status bar counts a poem's lines, not its title or labels")
            let versePage = ChapterReader.reading(chapters: [ReadingChapter(title: "Estuary", number: 1, scenes: [
                ChapterSceneText(id: 0, url: URL(fileURLWithPath: "/p1.md"), title: "Low Water", text: poemText),
                ChapterSceneText(id: 1, url: URL(fileURLWithPath: "/p2.md"), title: "Mudlark", text: "Knees in the silt.\n")], verse: true)],
                heading: nil).page.string
            check(versePage.contains("Low Water\nThe sea goes out\n    the way a guest leaves,\nChorus\nWhat it leaves: a boot.\n·\nMudlark\nKnees")
                  && !versePage.contains(SceneBreak.ornament),
                  "verse: Read keeps every line, drops the label's brackets, and sets each poem under its title")
            let verseStorage = NSTextStorage(string: "First line of a poem\nsecond line")
            MarkdownStyler.apply(to: verseStorage, verse: true)
            let secondStyle = verseStorage.attribute(.paragraphStyle, at: 21, effectiveRange: nil) as? NSParagraphStyle
            check(secondStyle.map { $0.firstLineHeadIndent == Layout.hang && $0.headIndent > Layout.hang } == true,
                  "verse: the editor gives a line no paragraph indent, and hangs a wrapped line")
            check(NewDocumentSheet.untitled(.poetry, collection: nil) == "Untitled Collection"
                  && NewDocumentSheet.untitled(.poetry, collection: false) == "Untitled Poem"
                  && NewDocumentSheet.untitled(.novel, collection: nil) == "Untitled Novel",
                  "new document: an untitled story is named for its form")

            // A comment's excerpt in the margin reads as the page does.
            check(CommentContext.plain("did not **understand** it[^why]. See [the card](card.md), _twice_ in snake_case") ==
                  "did not understand it. See the card, twice in snake_case",
                  "margin: a comment's excerpt leaves out Markdown's symbols")
            check(CommentContext.plain("half a call [^wh") == "half a call ", "margin: half a footnote call cut off at the edge goes too")

            // Previous works belong to the author: an older authors file still reads, and a
            // story's own list moves to its author, added to theirs, never lost.
            let oldFile = #"[{"id":"x1","name":"Old Hand","penName":"","address":"","email":"","phone":""}]"#
            check((try? JSONDecoder().decode([AuthorProfile].self, from: Data(oldFile.utf8)))?.first?.previousWorks == "",
                  "authors: a file from before previous works still reads")
            let authorsStore = AuthorProfiles.shared
            let writer = authorsStore.add(AuthorProfile(name: "Test Writer", previousWorks: "First Book (2010)"))
            var story = SceneInfo()
            story.setAuthor(writer)
            story.previousWorks = "Second Book (2015)"
            let settledStory = authorsStore.settle(story)
            check(settledStory.previousWorks == nil
                  && authorsStore.profile(writer.id)?.previousWorks == "First Book (2010)\nSecond Book (2015)",
                  "authors: a story's previous works move to its author, added to theirs")
            check(authorsStore.settle(settledStory) == settledStory && authorsStore.profile(writer.id)?.previousWorks == "First Book (2010)\nSecond Book (2015)",
                  "authors: settling again changes nothing")
            authorsStore.remove(writer.id)

            // A story's Page: its title page, then each chapter with its opener and its own notes.
            let storyRead = ChapterReader.reading(chapters: [
                ReadingChapter(title: "Low Water", number: 1, scenes: [
                    ChapterSceneText(id: 0, url: URL(fileURLWithPath: "/s1.md"), title: "A", text: "One[^n].\n\n[^n]: First note.")]),
                ReadingChapter(title: "The Crossing", number: 2, scenes: [
                    ChapterSceneText(id: 1, url: URL(fileURLWithPath: "/s2.md"), title: "B", text: "Two[^m].\n\n[^m]: Second note.")])
            ], heading: StoryHeading(title: "The Salt Road", byline: "A. N. Author"))
            let storyText = storyRead.page.string
            check(storyText.hasPrefix("The Salt Road\nA. N. Author\nChapter 1\nLow Water\nOne1.") && storyText.contains("Chapter 2\nThe Crossing\nTwo1."),
                  "story page: the title page, then every chapter, footnotes counted from 1 in each")
            check(storyText.contains("1\tFirst note.") && storyText.contains("1\tSecond note.") && storyRead.maps.count == 2,
                  "story page: each chapter's notes follow it, and every scene is on the map for comments")

            // Tables and footnotes on the reading page, set as export sets them.
            let marked = "Tide[^a] tables:\n\n| Name | Height |\n| --- | --- |\n| Spring | **5.2** m |\n| Neap | 3.1 m |\n\nAfter the table[^b], the end.\n\n[^a]: Twice a day.\n[^b]: See *Almanac*.\n    Page 4." as NSString
            let urlT = URL(fileURLWithPath: "/t.md")
            let set = ChapterReader.reading(title: "Low Water", number: 1, scenes: [
                ChapterSceneText(id: 0, url: urlT, title: "T", text: marked as String)])
            let shownText = set.page.string as NSString
            check(shownText.contains("Tide1 tables:") && shownText.contains("After the table2, the end."),
                  "reading view: footnote calls are numbers, counted through the chapter")
            check(shownText.contains("Name\tHeight\nSpring\t5.2 m\nNeap\t3.1 m") && !shownText.contains("|") && !shownText.contains("---"),
                  "reading view: a table is set in columns, without its bars or rule")
            check(shownText.contains("Notes\n1\tTwice a day.\n2\tSee Almanac. Page 4.") && !shownText.contains("[^"),
                  "reading view: the notes follow the chapter, numbered, in reading order")
            if let map = set.maps[urlT] {
                func onPage(_ word: String) -> String? { map.page(marked.range(of: word)).map { shownText.substring(with: $0) } }
                check(onPage("Neap") == "Neap" && onPage("the end") == "the end" && onPage("5.2") == "5.2",
                      "reading view: comments in and after a table land on their words")
                let tabStops = (set.page.attribute(.paragraphStyle, at: shownText.range(of: "Spring").location, effectiveRange: nil) as? NSParagraphStyle)?.tabStops.count
                check(tabStops == 1, "reading view: a table's columns line up on tab stops")
            } else {
                check(false, "reading view: a scene with a table has a map")
            }

            // Clear Desk fades everything but the page, and the page doesn't move by a point.
            if let sceneURL = chapters().first?.scenes.first?.url {
                store.selection = .scene(sceneURL)
                await settle(300)
                let before = margin.textView
                let text = before?.string
                func pageFrame() -> NSRect? {
                    guard let page = before, let content = page.window?.contentView else { return nil }
                    return page.convert(page.bounds, to: content)
                }
                func firstLine() -> NSRect? {
                    guard let page = before as? HighlightTextView else { return nil }
                    return page.lineRects(of: NSRange(location: 0, length: 1)).first.map { page.convert($0, to: page.window?.contentView) }
                }
                let shownFrame = pageFrame(), shownLine = firstLine()
                store.deskCleared = true
                await settle(500)
                check(before != nil && margin.textView === before && margin.textView?.string == text,
                      "clear desk: the page stays as it was (not rebuilt, nothing lost)")
                check(shownFrame != nil && pageFrame() == shownFrame && firstLine() == shownLine,
                      "clear desk: the text doesn't move when the desk is cleared")
                store.deskCleared = false
                await settle(500)
                check(margin.textView === before && pageFrame() == shownFrame && firstLine() == shownLine,
                      "clear desk: nor when it comes back")
            }

            // A scene that ends with a break doesn't get two in the exported book.
            let made = ManuscriptBuilder.make(title: "T", chapters: [(title: "C", scenes: [
                (title: "A", text: "One.\n\n---\n"), (title: "B", text: "***\n\nTwo.")])], words: 2)
            check(made.chapters.first?.blocks.filter { $0 == .sceneBreak }.count == 1,
                  "export: a break typed at the end of a scene isn't doubled")

            // A typed --- is drawn as asterisks; the text itself is untouched.
            let typed = NSAttributedString(string: "one\n---\n- - -\n- item\n--\n")
            check(HighlightTextView.asterisks(in: typed, range: NSRange(location: 4, length: 4))?.string == "***\n"
                  && HighlightTextView.asterisks(in: typed, range: NSRange(location: 8, length: 6))?.string == "* * *\n",
                  "a break typed with dashes is drawn as asterisks, symbol for symbol")
            check(HighlightTextView.asterisks(in: typed, range: NSRange(location: 14, length: 7)) == nil
                  && HighlightTextView.asterisks(in: typed, range: NSRange(location: 21, length: 3)) == nil
                  && HighlightTextView.asterisks(in: typed, range: NSRange(location: 0, length: 4)) == nil,
                  "list items, two dashes and prose are drawn as typed")

            // Covers are committed (they were ignored, so they never synced).
            if let root = store.libraryURL {
                let ignore = (try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
                check(!ignore.contains(".longhand/covers"), "covers are not left out of Git")
                let old = ignore + "# Book covers: replaced, never versioned.\n.longhand/covers/\n"
                try? old.write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
                Git.prepare(root)
                let fixed = (try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
                check(!fixed.contains(".longhand/covers") && fixed.contains(".longhand/history/"),
                      "a library that ignored covers stops ignoring them, and keeps its other rules")
            }

            // Emphasis hugs its words.
            func styled(_ text: String) -> NSTextStorage {
                let storage = NSTextStorage(string: text)
                MarkdownStyler.apply(to: storage)
                return storage
            }
            func italic(_ storage: NSTextStorage, at index: Int) -> Bool {
                (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true
            }
            func bold(_ storage: NSTextStorage, at index: Int) -> Bool {
                (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
            }
            check(!italic(styled("2 * 3 * 4"), at: 4), "stars with spaces inside are not italics")
            check(!italic(styled("* one *two*"), at: 3) && italic(styled("* one *two*"), at: 8), "a bullet's star doesn't open italics")
            check(!italic(styled("my_file_name"), at: 4), "underscores inside a word are not italics")
            check(italic(styled("an _aside_ here"), at: 5), "underscores around a word are italics")
            let both = styled("so ***very*** much")
            check(italic(both, at: 7) && bold(both, at: 7), "three stars are bold italics")
            let ruled = styled("one\n\n---\n\ntwo")
            check((ruled.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center,
                  "a break inside a scene is centred")

            // Dashes at the start of a line stay as typed, so --- can be typed.
            let line = "He said--no.\n--" as NSString
            let mid = NSTextCheckingResult.dashCheckingResult(range: NSRange(location: 7, length: 2), replacementString: "—")
            let start = NSTextCheckingResult.dashCheckingResult(range: NSRange(location: 13, length: 2), replacementString: "—")
            let kept = ProofingFilter.filter([mid, start], in: line)
            check(kept.count == 1 && kept.first?.range.location == 7, "dashes that start a line are not turned into an em dash")
            let speech = "--Hello, she said." as NSString
            let opening = NSTextCheckingResult.dashCheckingResult(range: NSRange(location: 0, length: 2), replacementString: "—")
            check(ProofingFilter.filter([opening], in: speech).count == 1, "dashes that open a line of prose still become an em dash")

            // Return carries a list on, and ends it on an empty item.
            let scratch = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scratch.string = "- one"
            scratch.setSelectedRange(NSRange(location: 5, length: 0))
            check(MarkdownFormat.continueBlock(in: scratch) && scratch.string == "- one\n- ", "Return in a list starts the next item")
            check(MarkdownFormat.continueBlock(in: scratch) && scratch.string == "- one\n", "Return on an empty item ends the list")
            scratch.string = "3. three"
            scratch.setSelectedRange(NSRange(location: 8, length: 0))
            check(MarkdownFormat.continueBlock(in: scratch) && scratch.string == "3. three\n4. ", "a numbered list counts on")
            scratch.string = "1984."
            scratch.setSelectedRange(NSRange(location: 5, length: 0))
            check(!MarkdownFormat.continueBlock(in: scratch) && scratch.string == "1984.", "a line that is only a year is not an empty list item")
            scratch.string = "1984. Winston"
            scratch.setSelectedRange(NSRange(location: 13, length: 0))
            check(!MarkdownFormat.continueBlock(in: scratch), "a sentence that starts with a year is not a numbered list")
            scratch.string = "Plain prose"
            scratch.setSelectedRange(NSRange(location: 11, length: 0))
            check(!MarkdownFormat.continueBlock(in: scratch), "Return in prose is left alone")
            scratch.string = "---"
            scratch.setSelectedRange(NSRange(location: 3, length: 0))
            check(!MarkdownFormat.continueBlock(in: scratch), "Return after a break is left alone")

            // Trashing the story the contents is inside goes back to the Library.
            store.createBook()
            if let made = store.library?.books.last, store.openBook == made.url {
                store.delete(ManuscriptItem(url: made.url, title: made.title, order: made.order, kind: .book))
                check(store.openBook == nil, "trashing the story you are inside returns the contents to the Library")
            } else {
                check(false, "a new story is entered when it is made")
            }

            // ⌘K: the palette's field has the keyboard, and gives it back.
            if let scene = store.library?.books.first?.chapters.first?.scenes.first {
                store.selection = .scene(scene.url)
                try? await Task.sleep(for: .milliseconds(400))
                let window = NSApp.windows.first { $0.contentView.map { findEditor(in: $0) != nil } ?? false }
                if let window, let editor = window.contentView.flatMap({ findEditor(in: $0) }) {
                    window.makeFirstResponder(editor)
                    store.quickOpenShown = true
                    try? await Task.sleep(for: .milliseconds(400))
                    let holder = window.firstResponder as? NSTextView
                    check(holder?.isFieldEditor == true && holder?.delegate is KeyField.Field,
                          "the command palette takes the keyboard when it opens")
                    store.quickOpenShown = false
                    try? await Task.sleep(for: .milliseconds(300))
                    check(window.firstResponder === editor, "closing the palette gives the keyboard back to the page")

                    // The keyboard from pane to pane, without the mouse. (An alert left up by an
                    // earlier check would keep the keyboard, as it should.)
                    store.errorMessage = nil
                    try? await Task.sleep(for: .milliseconds(600))
                    if let book = store.library?.books.first, let chapter = book.chapters.first {
                        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], characters: String = "") {
                            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
                            window.firstResponder?.keyDown(with: event)
                        }
                        func pane() -> Pane? { (window.firstResponder as? PaneKeys.KeysView)?.pane }
                        window.makeFirstResponder(editor)

                        Panes.focus(.contents, in: store)
                        check(pane() == .contents, "Go › Contents gives the contents the keyboard")
                        if book.shape == .chaptersAndScenes {
                            press(123)
                            check(store.selection == .chapter(chapter.url), "contents: ← goes up to the scene's chapter")
                            press(123)
                            press(125)
                            check(store.selection != .scene(scene.url), "contents: ← closes a chapter, and ↓ then passes its scenes by")
                            store.selection = .chapter(chapter.url)
                            press(124); press(124)
                            check(store.selection == .scene(scene.url), "contents: → opens a chapter and goes into it")
                            press(126)
                            check(store.selection == .chapter(chapter.url), "contents: ↑ chooses the row above")
                            press(125)
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                        check(pane() == .contents, "contents: it keeps the keyboard while the choice moves")

                        // The palette, opened from the contents, gives the keyboard back to it.
                        store.togglePalette()
                        try? await Task.sleep(for: .milliseconds(400))
                        check((window.firstResponder as? NSTextView)?.delegate is KeyField.Field, "palette: it takes the keyboard from the contents")
                        store.togglePalette()
                        check(!store.quickOpenShown, "palette: its command a second time puts it away")
                        try? await Task.sleep(for: .milliseconds(400))
                        check(pane() == .contents, "palette: closing it gives the keyboard back to the contents")

                        press(48)
                        check(window.firstResponder === editor, "contents: Tab goes on to the page")
                        Panes.focus(.margin, in: store)
                        check(pane() == .margin, "Go › Margin gives the margin the keyboard")
                        press(48, .shift)
                        check(window.firstResponder === editor, "margin: ⇧Tab goes back to the page")
                        Panes.focus(.margin, in: store)
                        press(53)
                        check(window.firstResponder === editor, "margin: Escape goes back to the page")
                        Panes.focus(.contents, in: store)
                        press(125, .command)
                        check(window.firstResponder === editor, "contents: ⌘↓ opens the choice on the page")

                        // A page taken away while it had the keyboard: the one in its place gets it.
                        store.selection = .chapter(chapter.url)
                        try? await Task.sleep(for: .milliseconds(900))
                        let held = window.firstResponder as? NSView
                        check(held != nil && held !== window.contentView && held?.window === window && Panes.current(in: window) == .page,
                              "the page that replaces one holding the keyboard takes it"
                                + " (held by \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing")))")

                        // One thing over the page at a time, and the switcher keeps what is typed.
                        store.selection = .scene(scene.url)
                        try? await Task.sleep(for: .milliseconds(500))
                        if let page = window.contentView.flatMap({ findEditor(in: $0) }) {
                            window.makeFirstResponder(page)
                            let before = page.string
                            store.cheatSheetShown = true
                            store.switcherShown = true
                            check(!store.cheatSheetShown, "opening the scene switcher puts the cheat sheet away")
                            try? await Task.sleep(for: .milliseconds(300))
                            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, characters: "x",
                                                            charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) {
                                NSApp.sendEvent(event)
                            }
                            check(page.string == before, "the scene switcher: a letter typed doesn't go into the page behind")
                            store.quickOpenShown = true
                            check(!store.switcherShown, "opening the palette puts the scene switcher away")
                            store.quickOpenShown = false
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                        store.selection = .scene(scene.url)
                        try? await Task.sleep(for: .milliseconds(400))
                        window.makeFirstResponder(window.contentView.flatMap({ findEditor(in: $0) }) ?? editor)
                    }

                    // Theme › a theme previews it as it becomes the choice; closing puts the kept one back.
                    let kept = AppTheme.kept
                    if let target = AppTheme.allCases.first(where: { $0 != kept && !$0.darkOnly }),
                       let index = AppTheme.allCases.firstIndex(of: target) {
                        store.quickOpenShown = true
                        try? await Task.sleep(for: .milliseconds(400))
                        store.palette.group = "Theme"
                        try? await Task.sleep(for: .milliseconds(200))
                        store.palette.chosen = index
                        try? await Task.sleep(for: .milliseconds(600))
                        check(AppTheme.current == target && AppTheme.kept == kept,
                              "palette: the theme chosen in the list is shown, not kept")
                        check(store.quickOpenShown && store.palette.group == "Theme" && store.palette.chosen == index,
                              "palette: it stays open on the same theme while the window is drawn again")
                        store.quickOpenShown = false
                        try? await Task.sleep(for: .milliseconds(500))
                        check(AppTheme.current == kept, "palette: closing without choosing puts the kept theme back")
                        var held = NSApp.windows.first { $0.frame.width > 400 }?.firstResponder
                        for _ in 0..<15 where !(held is HighlightTextView) {
                            try? await Task.sleep(for: .milliseconds(100))
                            held = NSApp.windows.first { $0.frame.width > 400 }?.firstResponder
                        }
                        check(held is HighlightTextView && (held as? NSTextView)?.isEditable == true,
                              "palette: after a preview, closing gives the keyboard to the page" + (held is HighlightTextView ? "" : " (held by \(held.map { String(describing: type(of: $0)) } ?? "nothing"))"))
                    }
                } else {
                    check(false, "the scene editor is on screen for the palette test")
                }
            }

        }

        finish()
    }

    /// The scene editor's text view.
    private static func findEditor(in view: NSView) -> NSTextView? {
        if let textView = view as? HighlightTextView, textView.identifier != ChapterEditor.identifier, textView.isEditable {
            return textView
        }
        for subview in view.subviews {
            if let found = findEditor(in: subview) { return found }
        }
        return nil
    }

    /// The chapter page's text view, if a chapter is on screen.
    private static func chapterPage() -> NSTextView? {
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            if let page = findPage(in: root) { return page }
        }
        return nil
    }

    private static func findPage(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.identifier == ChapterEditor.identifier {
            return textView
        }
        for subview in view.subviews {
            if let page = findPage(in: subview) { return page }
        }
        return nil
    }

    private static func write(_ lines: [String], failures: Int, to path: String) {
        var output = lines
        output.append("")
        output.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? output.joined(separator: "\n").write(
            to: URL(fileURLWithPath: path),
            atomically: true,
            encoding: .utf8
        )
        print(output.joined(separator: "\n"))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
