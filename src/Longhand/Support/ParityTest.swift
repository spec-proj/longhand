import AppKit

/// Dev aid: `Longhand --paritytest /path/report.txt`, with a scratch library and a local bare
/// repository standing in for GitHub. Drives the app's own operations on "this Mac", pushes,
/// then clones the remote as "the other Mac" and lists what differs between the two copies.
///
/// Issue #22: libraries on two Macs did not hold the same files, with nothing said.
@MainActor
enum ParityTest {
    private static let lastLibraryKey = "lastLibraryPath"

    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--paritytest"), args.count > index + 1 else { return }
        let reportPath = args[index + 1]
        Task { @MainActor in await run(store: store, reportPath: reportPath) }
    }

    private static func run(store: LibraryStore, reportPath: String) async {
        var lines: [String] = []
        func say(_ text: String) { lines.append(text) }
        func settle(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

        let fm = FileManager.default
        let defaults = UserDefaults.standard
        let remembered = defaults.string(forKey: lastLibraryKey)
        let base = fm.temporaryDirectory.appendingPathComponent("LonghandParity-\(UUID().uuidString)")
        let library = base.appendingPathComponent("Writing")
        let remote = base.appendingPathComponent("remote.git")
        try? fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func finish() {
            store.closeLibrary()
            if let remembered { defaults.set(remembered, forKey: lastLibraryKey) }
            else { defaults.removeObject(forKey: lastLibraryKey) }
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func git(_ args: [String], in root: URL? = nil) -> String {
            Git.run(args, in: (root ?? library).canonical).output
        }

        /// Everything the writer sees, as `Path` and `Path/` for folders. Hidden things
        /// (`.git`, `.longhand`, `.DS_Store`) are left out: Finder's view of the library.
        func tree(_ root: URL) -> Set<String> {
            var out = Set<String>()
            guard let walk = fm.enumerator(at: root.canonical, includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles]) else { return out }
            for case let url as URL in walk {
                let rel = String(url.path.dropFirst(root.canonical.path.count + 1))
                guard !rel.isEmpty else { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                out.insert(isDir ? rel + "/" : rel)
            }
            return out
        }

        func prose(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        func item(_ scene: Scene) -> ManuscriptItem {
            ManuscriptItem(url: scene.url, title: scene.title, order: scene.order, kind: .scene)
        }
        func item(_ chapter: Chapter) -> ManuscriptItem {
            ManuscriptItem(url: chapter.url, title: chapter.title, order: chapter.order, kind: .chapter)
        }
        func book(_ title: String) -> Book? { store.library?.books.first { $0.title == title } }

        // MARK: The app's own saves and syncs

        func commitAndPush() async {
            store.saveNow()
            store.margin.saveNow()
            await settle(250)
            _ = await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in
                store.versions.commitNow { go.resume(returning: $0) }
            }
            _ = await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in
                store.versions.pushNow { go.resume(returning: $0) }
            }
            for _ in 0..<60 {
                store.versions.waitUntilIdle()
                if store.versions.sync.activity == .idle { break }
                await settle(100)
            }
            await settle(300)
        }

        /// Pushes everything, clones the remote fresh (the other Mac's first look), and lists
        /// what the two copies don't share.
        func compare(_ name: String) async {
            await commitAndPush()
            let bRoot = base.appendingPathComponent("Mac B \(UUID().uuidString.prefix(4))")
            try? fm.createDirectory(at: bRoot, withIntermediateDirectories: true)
            guard let other = Git.fetchLibrary(from: remote.path, named: "Writing", into: bRoot).folder else {
                say("\(name): THE CLONE FAILED")
                return
            }
            defer { try? fm.removeItem(at: bRoot) }

            let mine = tree(library), theirs = tree(other)
            let onlyHere = mine.subtracting(theirs).sorted()
            let onlyThere = theirs.subtracting(mine).sorted()
            say("")
            say("== \(name) ==")
            if onlyHere.isEmpty && onlyThere.isEmpty {
                say("  same files and folders on both Macs")
            }
            for path in onlyHere { say("  MISSING on the other Mac: \(path)") }
            for path in onlyThere { say("  only on the other Mac: \(path)") }
            for path in mine.intersection(theirs).sorted() where path.hasSuffix(".md") || path.hasSuffix(".fountain") {
                let a = prose(library.appendingPathComponent(path))
                let b = prose(other.appendingPathComponent(path))
                if a != b { say("  DIFFERENT WORDS: \(path)") }
            }

            // Git's own list: what was committed, hidden sidecars included.
            let here = Set(git(["ls-files"]).split(separator: "\n").map(String.init))
            let there = Set(git(["ls-files"], in: other).split(separator: "\n").map(String.init))
            for path in here.subtracting(there).sorted() { say("  missing from the remote (never committed): \(path)") }
            for path in there.subtracting(here).sorted() { say("  on the remote but not here: \(path)") }
            let dirty = git(["status", "--porcelain"]).split(separator: "\n").count
            if dirty > 0 { say("  left uncommitted on this Mac: \(dirty) path(s)") }
        }

        // MARK: Setup: a library on this Mac, a bare repository as GitHub

        store.openLibrary(at: library)
        for _ in 0..<50 where !store.versions.available { await settle(100) }
        say("library open: \(store.library != nil), Git available: \(store.versions.available)")

        _ = Git.run(["init", "-q", "--bare", remote.path], in: base)
        _ = Git.run(["remote", "add", "origin", remote.path], in: library.canonical)
        store.versions.refresh()
        for _ in 0..<50 where !store.versions.hasBackup { await settle(100) }
        say("remote known: \(store.versions.hasBackup)")

        // A story with a chapter and a scene, named so it can be re-capitalised later.
        store.createBook(title: "Parity Novel")
        await settle(300)
        if let scene = book("Parity Novel")?.chapters.first?.scenes.first {
            store.rename(item(scene), to: "Arrival")
        }
        await settle(300)
        if let scene = book("Parity Novel")?.chapters.first?.scenes.first {
            store.selection = .scene(scene.url)
            await settle(300)
            store.updateText("# Arrival\n\nThe first scene.")
            store.saveNow()
        }
        await compare("first push: a story, a chapter and a scene")

        // New Folder: an empty group, remembered by name.
        let folder = store.createFolder(named: "Bookcase")
        say("New Folder made a folder on disk: \(folder.map { fm.fileExists(atPath: $0.path) } ?? false)")
        await compare("after New Folder (an empty group)")

        // A second story, then its only scene deleted: the chapter is left empty.
        store.createBook(title: "Second Story")
        await settle(300)
        if let chapter = book("Second Story")?.chapters.first {
            for scene in chapter.scenes { store.delete(item(scene)) }
        }
        await settle(300)
        await compare("after deleting a story's only scene (its chapter is left empty)")

        // Then the empty chapter deleted: the story's folder is left empty.
        if let chapter = book("Second Story")?.chapters.first {
            store.delete(item(chapter))
        }
        await settle(300)
        await compare("after deleting that empty chapter (the story is left empty)")

        // Boneyard: a cut scene, then the Boneyard emptied.
        if let chapter = book("Parity Novel")?.chapters.first {
            store.selection = .chapter(chapter.url)
            await settle(300)
            store.createSceneInContext()
            await settle(300)
            if case .scene(let url) = store.selection {
                store.moveToBoneyard(url)
                await settle(300)
                if let cut = book("Parity Novel")?.boneyard?.scenes.first { store.delete(item(cut)) }
            }
        }
        await settle(300)
        await compare("after emptying the Boneyard")

        // Rename with capitals only.
        if let scene = book("Parity Novel")?.chapters.first?.scenes.first {
            store.rename(item(scene), to: "arrival")
            await settle(300)
            if let renamed = book("Parity Novel")?.chapters.first?.scenes.first {
                store.selection = .scene(renamed.url)
                await settle(300)
                store.updateText("# arrival\n\nThe first scene, re-capitalised.")
                store.saveNow()
                _ = Git.commitAll(library, message: "Case rename")
                let relative = String(renamed.url.canonical.path.dropFirst(library.canonical.path.count + 1))
                let inGit = git(["ls-files", "--", relative]).trimmingCharacters(in: .whitespacesAndNewlines)
                say("")
                say("case-only rename: on disk “\(renamed.url.lastPathComponent)”"
                    + ", in Git “\(inGit.isEmpty ? "the old name only" : inGit)”")
            }
        }
        await compare("after renaming a scene “Arrival” to “arrival”")

        // A note and nothing else: does it get committed by itself?
        let head = git(["rev-parse", "HEAD"])
        if let scene = book("Parity Novel")?.chapters.first?.scenes.first {
            store.selection = .scene(scene.url)
            await settle(300)
            store.margin.setSceneNote("A note that has to reach the other Mac.")
            store.margin.saveNow()
            await settle(400)
            let status = git(["status", "--porcelain"]).split(separator: "\n").count
            say("")
            say("note only: \(status) changed path(s) on disk, uncommitted")
            await settle(35_000)
            say("note only: after 35 seconds, a new commit: \(git(["rev-parse", "HEAD"]) != head)")
        }
        await compare("after adding a note (and nothing else)")

        say("")
        say("Done.")
        finish()
    }
}
