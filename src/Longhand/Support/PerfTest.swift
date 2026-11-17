import AppKit
import QuartzCore

/// Dev aid: `Longhand --perftest /path/report.txt`, with `LONGHAND_LIBRARY` pointing at a
/// novel-sized library (`scripts/tools/make_perf_library.py`). Runs hidden, like the self-test,
/// times the things a writer feels, writes the report and quits.
///
/// Typing is timed as wall-clock per keystroke with a 1ms pause between keys, so it includes
/// everything the main thread does for a key: the edit, restyling, saving, SwiftUI updates and
/// drawing. `LONGHAND_PERF_KEYS` sets how many keys (default 60; more for profiling).
@MainActor
enum PerfTest {
    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--perftest"), args.count > index + 1 else { return }
        let path = args[index + 1]
        Task { @MainActor in await run(store: store, reportPath: path) }
    }

    /// The part of the last typing run's per-key time spent in the edit itself (the rest is
    /// SwiftUI, drawing and the run loop).
    private static var lastEditing = 0.0

    private static func now() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }

    private static func settle(_ milliseconds: Int = 400) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Seconds since this process started (from the kernel's record of it).
    static func sinceLaunch() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    /// Memory the process holds (what Activity Monitor shows), in MB.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// CPU seconds this process has used.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private static func run(store: LibraryStore, reportPath: String) async {
        var lines: [String] = []
        func report(_ label: String, _ value: Double, unit: String = "ms") {
            lines.append(String(format: "%-44@ %8.1f %@", label as NSString, value, unit as NSString))
        }
        report("launch to first idle", sinceLaunch() * 1000)
        report("memory at launch", footprint(), unit: "MB")
        let keys = Int(ProcessInfo.processInfo.environment["LONGHAND_PERF_KEYS"] ?? "") ?? 60
        await settle(800)

        guard let book = store.library?.books.first, !book.chapters.isEmpty else {
            lines.append("No library: set LONGHAND_LIBRARY")
            finish(lines, to: reportPath)
            return
        }
        let scenes = book.chapters.flatMap(\.scenes)
        lines.append("Library: \(scenes.count) scenes, \(store.totalWordCount) words")

        // LONGHAND_PERF_ONLY=chapters|cards|switch|themes: repeat just that (n = LONGHAND_PERF_REPEAT,
        // default 200), timed in phases, for profiling with `sample`.
        if ProcessInfo.processInfo.environment["LONGHAND_PERF_ONLY"] == "launch" {
            finishNow(lines, to: reportPath)
            return
        }
        if ProcessInfo.processInfo.environment["LONGHAND_PERF_ONLY"] == "idle" {
            // A scene open, nothing happening: CPU used over 10 seconds, and memory.
            if let scene = scenes.first { store.selection = .scene(scene.url) }
            await settle(2000)
            let before = cpuSeconds()
            await settle(10_000)
            report("idle CPU (10 s on a scene)", (cpuSeconds() - before) / 10 * 100, unit: "%")
            report("memory, one scene open", footprint(), unit: "MB")
            finish(lines, to: reportPath)
            return
        }
        if let only = ProcessInfo.processInfo.environment["LONGHAND_PERF_ONLY"] {
            let repeats = Int(ProcessInfo.processInfo.environment["LONGHAND_PERF_REPEAT"] ?? "") ?? 200
            if only == "cards" {
                ViewModes.forcedStory = .cards
                store.openBook = book.url
            }
            // LONGHAND_PERF_BARE=1|sidebar|margin: without both side columns, or with only that one.
            if let bare = ProcessInfo.processInfo.environment["LONGHAND_PERF_BARE"] {
                UserDefaults.standard.setVolatileDomain(
                    UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                        .merging(["showSidebar": bare == "margin", "showMargin": bare == "sidebar"]) { $1 },
                    forName: UserDefaults.argumentDomain)
                await settle(300)
            }
            if only == "themes", let longest = scenes.max(by: { store.wordCount(of: $0) < store.wordCount(of: $1) }) {
                store.selection = .scene(longest.url)
                await settle(800)
            }
            let window = NSApp.windows.first { $0.frame.width > 400 }
            var phases = [0.0, 0.0, 0.0]
            let started = now()
            for index in 0..<repeats {
                let a = now()
                switch only {
                case "chapters": store.selection = .chapter(book.chapters[index % book.chapters.count].url)
                case "cards": store.selection = index % 2 == 0 ? .book(book.url) : .scene(scenes[index % scenes.count].url)
                // A theme previewed (the palette's list): the window drawn again in it.
                case "themes": AppTheme.preview(AppTheme.allCases[index % AppTheme.allCases.count])
                default: store.selection = .scene(scenes[index % scenes.count].url)
                }
                let b = now()
                window?.contentView?.layoutSubtreeIfNeeded()
                window?.layoutIfNeeded()
                let c = now()
                window?.displayIfNeeded()
                CATransaction.flush()
                let d = now()
                phases[0] += b - a; phases[1] += c - b; phases[2] += d - c
                await settle(1)
            }
            let n = Double(repeats)
            // Whole steps, the run loop's own redraw included (less the 1ms pause in each).
            report("\(only): whole step", (now() - started) / n - 1)
            report("\(only): store", phases[0] / n)
            report("\(only): views", phases[1] / n)
            report("\(only): drawing", phases[2] / n)
            finish(lines, to: reportPath)
            return
        }

        // LONGHAND_PERF_TYPEWRITER=1: where the caret's line sits, with typewriter scrolling on,
        // as the caret moves and as you type (0 = the middle of the window).
        if let mode = ProcessInfo.processInfo.environment["LONGHAND_PERF_TYPEWRITER"] {
            let defaults = UserDefaults.standard
            defaults.setVolatileDomain(defaults.volatileDomain(forName: UserDefaults.argumentDomain)
                .merging([WritingModes.typewriterKey: true]) { $1 }, forName: UserDefaults.argumentDomain)
            if mode == "chapter", let chapter = book.chapters.max(by: { store.wordCount(of: $0) < store.wordCount(of: $1) }) {
                store.selection = .chapter(chapter.url)
                await settle(800)
            } else if let longest = scenes.max(by: { store.wordCount(of: $0) < store.wordCount(of: $1) }) {
                store.selection = .scene(longest.url)
                await settle(600)
            }
            guard let page = store.margin.textView, let scroll = page.enclosingScrollView else {
                lines.append("no page"); finish(lines, to: reportPath); return
            }
            page.window?.makeFirstResponder(page)
            func offset(_ label: String) {
                let caret = page.selectedRange().location
                var line = NSRect.null
                if let tlm = page.textLayoutManager, let hl = page as? HighlightTextView,
                   let range = hl.textRange(for: NSRange(location: caret, length: 0)) {
                    tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in line = frame; return false }
                }
                let clip = scroll.contentView.bounds
                let y = line.midY + page.textContainerOrigin.y
                lines.append(String(format: "%-40@ caret line %6.0f from the middle  (clip y %6.0f h %4.0f, inset %4.0f, doc h %6.0f)",
                                    label as NSString, y - clip.midY, clip.minY, clip.height, page.textContainerInset.height, page.frame.height))
            }
            await settle(300)
            offset("opened")
            let length = (page.string as NSString).length
            for fraction in [0.25, 0.5, 0.9, 1.0] {
                page.setSelectedRange(NSRange(location: Int(Double(length) * fraction), length: 0))
                await settle(300)
                offset("caret moved to \(Int(fraction * 100))%")
            }
            page.setSelectedRange(NSRange(location: length / 2, length: 0))
            await settle(300)
            for index in 0..<6 {
                page.insertText(index % 3 == 2 ? "\n" : "word ", replacementRange: page.selectedRange())
                await settle(120)
                offset("typed key \(index + 1)")
            }
            for _ in 0..<40 { page.insertText("more words ", replacementRange: page.selectedRange()) }
            await settle(300)
            offset("typed a line and more")
            page.moveDown(nil); await settle(200); offset("arrow down")
            page.moveDown(nil); await settle(200); offset("arrow down again")
            page.moveUp(nil); await settle(200); offset("arrow up")
            finish(lines, to: reportPath)
            return
        }

        // Re-reading the library (happens every time the app becomes active).
        var t = now()
        for _ in 0..<5 { store.refreshFromDisk() }
        report("re-read library (avg of 5)", (now() - t) / 5)

        // Switching scenes.
        let switches = Int(ProcessInfo.processInfo.environment["LONGHAND_PERF_SWITCHES"] ?? "") ?? 12
        let sample = (0..<switches).map { scenes[$0 % scenes.count] }
        t = now()
        for scene in sample {
            store.selection = .scene(scene.url)
            await settle(1)
        }
        report("switch scene (avg of \(sample.count))", (now() - t) / Double(sample.count))

        // The same, in phases: the store's own work, SwiftUI's update and layout, drawing.
        do {
            var phases = [0.0, 0.0, 0.0]
            let window = NSApp.windows.first { $0.frame.width > 400 }
            for scene in sample.reversed() {
                let a = now()
                store.selection = .scene(scene.url)
                let b = now()
                window?.contentView?.layoutSubtreeIfNeeded()
                window?.layoutIfNeeded()
                let c = now()
                window?.displayIfNeeded()
                CATransaction.flush()
                let d = now()
                phases[0] += b - a; phases[1] += c - b; phases[2] += d - c
                await settle(1)
            }
            let n = Double(sample.count)
            report("  store (selection change)", phases[0] / n)
            report("  views (SwiftUI update, layout)", phases[1] / n)
            report("  drawing", phases[2] / n)
        }

        // Typing in the longest scene.
        let longest = scenes.max { store.wordCount(of: $0) < store.wordCount(of: $1) }!
        store.selection = .scene(longest.url)
        await settle(600)
        if let page = store.margin.textView {
            lines.append("Scene: \(store.wordCount(of: longest)) words")
            // LONGHAND_PERF_AT=start or =end types only there (for profiling one case).
            if ProcessInfo.processInfo.environment["LONGHAND_PERF_AT"] != "start" {
                report("type in scene, per key, at the end", await type(keys, into: page, at: (page.string as NSString).length))
                report("  of which the edit itself", lastEditing)
            }
            if let repeats = Int(ProcessInfo.processInfo.environment["LONGHAND_PERF_SCROLLS"] ?? "") {
                for _ in 0..<repeats { _ = scroll(page) }
            }
            let sceneScroll = scroll(page)
            lines.append(String(format: "%-44@ %8.1f ms (worst %.1f)", "scroll scene, per 60pt step" as NSString, sceneScroll.average, sceneScroll.worst))
            if let window = page.window {
                let original = window.frame
                var total = 0.0, worst = 0.0
                let resizes = Int(ProcessInfo.processInfo.environment["LONGHAND_PERF_RESIZES"] ?? "") ?? 20
                // Negative narrows the page below its column (lines re-wrap); positive widens it.
                let delta = Double(ProcessInfo.processInfo.environment["LONGHAND_PERF_RESIZE_DELTA"] ?? "") ?? -120
                for index in 0..<resizes {
                    var frame = original
                    frame.size.width += CGFloat(index % 2 == 0 ? delta : 0)
                    let start = now()
                    window.setFrame(frame, display: true)
                    window.displayIfNeeded()
                    CATransaction.flush()
                    let spent = now() - start
                    total += spent
                    worst = max(worst, spent)
                }
                window.setFrame(original, display: true)
                lines.append(String(format: "%-44@ %8.1f ms (worst %.1f)", "resize window (avg of \(resizes))" as NSString, total / Double(max(1, resizes)), worst))
            }
            if ProcessInfo.processInfo.environment["LONGHAND_PERF_AT"] != "end" {
                report("type in scene, per key, at the start", await type(keys, into: page, at: 0))
                report("  of which the edit itself", lastEditing)
            }
            if ProcessInfo.processInfo.environment["LONGHAND_LAYERDUMP"] == "1" {
                let w = page.window
                lines.append("text system: \(page.textLayoutManager != nil ? "TextKit 2" : "TextKit 1")")
                lines.append("window screen=\(w?.screen?.localizedName ?? "nil") depth=\(w?.depthLimit.rawValue ?? 0) cs=\(w?.colorSpace?.localizedName ?? "nil") scale=\(w?.backingScaleFactor ?? 0) edr=\(w?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0)")
                func dump(_ v: NSView, _ d: Int) {
                    let l = v.layer
                    lines.append(String(repeating: "  ", count: d) + "\(Swift.type(of: v)) frame=\(v.frame) layer=\(l.map { "\(Swift.type(of: $0)) fmt=\($0.contentsFormat.rawValue) sublayers=\($0.sublayers?.count ?? 0)" } ?? "none")")
                    if let l { for sub in l.sublayers ?? [] where sub.delegate == nil || !(sub.delegate is NSView) { lines.append(String(repeating: "  ", count: d + 1) + "· \(Swift.type(of: sub)) fmt=\(sub.contentsFormat.rawValue) frame=\(sub.frame) scale=\(sub.contentsScale) tiled=\(sub is CATiledLayer)") } }
                    for sub in v.subviews { dump(sub, d + 1) }
                }
                if let scroll = page.enclosingScrollView { dump(scroll, 0) }
            }
        } else {
            lines.append("scene editor not on screen")
        }
        store.saveNow()
        await settle()

        // Typing with the margin on History (it used to re-read every copy on each key).
        func setTab(_ tab: MarginStore.Tab) {
            // In memory only, like every setting in a hidden run: the owner's choice is untouched.
            let defaults = UserDefaults.standard
            defaults.setVolatileDomain(
                defaults.volatileDomain(forName: UserDefaults.argumentDomain).merging(["marginTab": tab.rawValue]) { $1 },
                forName: UserDefaults.argumentDomain
            )
        }
        setTab(.changes)
        await settle(300)
        if let page = store.margin.textView {
            report("type in scene, Versions tab open, per key", await type(keys, into: page, at: (page.string as NSString).length))
        }
        setTab(.comments)
        store.saveNow()
        await settle()

        // Typing on the longest chapter's page.
        let chapter = book.chapters.max { store.wordCount(of: $0) < store.wordCount(of: $1) }!
        t = now()
        store.selection = .chapter(chapter.url)
        await settle(1)
        report("open chapter page", now() - t)
        // LONGHAND_PERF_FROMSCENE=n opens the chapter page from a scene n times (for profiling).
        if let repeats = Int(ProcessInfo.processInfo.environment["LONGHAND_PERF_FROMSCENE"] ?? "") {
            var total = 0.0
            for index in 0..<repeats {
                store.selection = .scene(scenes[index % scenes.count].url)
                await settle(40)
                let start = now()
                store.selection = .chapter(chapter.url)
                await settle(1)
                total += now() - start
                await settle(20)
            }
            report("open chapter page from a scene (avg of \(repeats))", total / Double(max(1, repeats)))
        }
        // LONGHAND_PERF_CHAPTERS=n opens chapter pages n more times (for profiling).
        if let repeats = Int(ProcessInfo.processInfo.environment["LONGHAND_PERF_CHAPTERS"] ?? "") {
            t = now()
            for index in 0..<repeats {
                store.selection = .chapter(book.chapters[index % book.chapters.count].url)
                await settle(1)
            }
            report("open chapter page (avg of \(repeats))", (now() - t) / Double(max(1, repeats)))
            store.selection = .chapter(chapter.url)
            await settle(1)
        }
        await settle(800)
        if let page = chapterPage() {
            lines.append("Chapter: \(store.wordCount(of: chapter)) words")
            report("type on chapter page, per key, near the end", await type(keys, into: page, at: (page.string as NSString).length - 2))
            let chapterScroll = scroll(page)
            lines.append(String(format: "%-44@ %8.1f ms (worst %.1f)", "scroll chapter page, per 60pt step" as NSString, chapterScroll.average, chapterScroll.worst))
        } else {
            lines.append("chapter page not on screen")
        }
        store.saveNow()
        await settle()

        // Versions: saving one, and comparing after a heavy revision (every tenth word of 20
        // scenes changed).
        let versions = store.versions
        while !versions.available { await settle(50) }
        t = now()
        let _: Bool = await withCheckedContinuation { go in versions.save(note: "Perf test") { go.resume(returning: $0) } }
        report("save version", now() - t)
        for scene in scenes.prefix(20) {
            guard let text = try? String(contentsOf: scene.url, encoding: .utf8) else { continue }
            var words = text.components(separatedBy: " ")
            for i in stride(from: 5, to: words.count, by: 10) { words[i] = "changed" }
            try? words.joined(separator: " ").write(to: scene.url, atomically: true, encoding: .utf8)
        }
        if let root = store.libraryURL, let head = versions.recent.first?.id {
            t = now()
            let comparison = Git.compare(root, from: head, to: nil)
            report("compare 20 revised scenes (Git + words)", now() - t)
            t = now()
            let built = CompareText.build(comparison.scenes)
            report("lay out comparison (\(built.rows.count) rows)", now() - t)
        }
        t = now()
        store.compareVersions()
        while versions.comparison == nil || versions.comparingBusy { await settle(1) }
        report("  open Compare Versions, comparison ready", now() - t)
        await settle(1)
        report("open Compare Versions, to first draw", now() - t)
        versions.comparing = false
        // LONGHAND_PERF_COMPARES=n opens Compare Versions n more times (for profiling).
        if let repeats = Int(ProcessInfo.processInfo.environment["LONGHAND_PERF_COMPARES"] ?? "") {
            await settle(100)
            var total = 0.0
            for _ in 0..<repeats {
                let start = now()
                store.compareVersions()
                while versions.comparison == nil || versions.comparingBusy { await settle(1) }
                await settle(1)
                total += now() - start
                versions.comparing = false
                await settle(60)
            }
            report("open Compare Versions (avg of \(repeats))", total / Double(max(1, repeats)))
        }
        t = now()
        versions.endSession(words: 0)
        report("version on quit", now() - t)

        // Rewrites: each runs while the writer waits.
        t = now()
        store.startRewrite(title: "Perf rewrite")
        report("start a rewrite", now() - t)
        if let scene = scenes.first, var text = try? String(contentsOf: scene.url, encoding: .utf8) {
            text += "\nA paragraph written in the rewrite.\n"
            try? text.write(to: scene.url, atomically: true, encoding: .utf8)
        }
        t = now()
        store.switchTo(nil)
        report("switch to the manuscript", now() - t)
        t = now()
        store.switchTo(versions.rewrites.first)
        report("switch to the rewrite", now() - t)
        t = now()
        store.keepRewrite()
        report("keep the rewrite (no overlap)", now() - t)

        // The book as cards.
        ViewModes.forcedStory = .cards
        t = now()
        store.selection = .book(book.url)
        await settle(1)
        report("open book as cards", now() - t)

        finish(lines, to: reportPath)
    }

    /// Types `count` characters at `location`, one at a time, and returns the average time per
    /// key less the 1ms pause.
    /// Scrolls the page from top to bottom in 60pt steps, drawing each one: the average and
    /// the slowest step (a frame is ~16ms at 60Hz, ~8ms at 120Hz).
    private static func scroll(_ page: NSTextView, pause: Double = Double(ProcessInfo.processInfo.environment["LONGHAND_PERF_SCROLLPAUSE"] ?? "") ?? 0) -> (average: Double, worst: Double) {
        guard let scrollView = page.enclosingScrollView, let window = page.window else { return (0, 0) }
        let clip = scrollView.contentView
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
        window.displayIfNeeded()
        var total = 0.0, worst = 0.0, steps = 0
        var y: CGFloat = 0
        while y + clip.bounds.height < page.frame.height, steps < 400 {
            y += 60
            let start = now()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            CATransaction.flush()
            let spent = now() - start
            total += spent
            worst = max(worst, spent)
            steps += 1
            // A trackpad leaves the run loop a few idle milliseconds between frames, in which
            // AppKit draws ahead of the visible part (responsive scrolling). 0 = none.
            if pause > 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: pause / 1000)) }
        }
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
        return (steps > 0 ? total / Double(steps) : 0, worst)
    }

    private static func type(_ count: Int, into page: NSTextView, at location: Int) async -> Double {
        page.window?.makeFirstResponder(page)
        page.setSelectedRange(NSRange(location: max(0, location), length: 0))
        let start = now()
        var editing = 0.0
        for index in 0..<count {
            let before = now()
            page.insertText(index % 6 == 5 ? " " : "x", replacementRange: page.selectedRange())
            editing += now() - before
            try? await Task.sleep(for: .milliseconds(1))
        }
        await settle(1)
        lastEditing = editing / Double(count)
        return (now() - start) / Double(count) - 1
    }

    private static func chapterPage() -> NSTextView? {
        for window in NSApp.windows {
            if let view = window.contentView, let found = find(in: view) { return found }
        }
        return nil
    }

    private static func find(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.identifier == ChapterEditor.identifier { return text }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }

    private static func finish(_ lines: [String], to path: String) {
        // LONGHAND_PERF_IDLE=n waits n seconds on a scene before quitting (to check idle CPU).
        if let seconds = Double(ProcessInfo.processInfo.environment["LONGHAND_PERF_IDLE"] ?? "") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finishNow(lines, to: path)
            }
            return
        }
        finishNow(lines, to: path)
    }

    private static func finishNow(_ lines: [String], to path: String) {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

/// Dev aid: `Longhand --export-sample /dir` (hidden, with `LONGHAND_LIBRARY`) exports the first
/// book in every format with sample details, for checking the output by eye.
@MainActor
enum ExportSample {
    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--export-sample"), args.count > index + 1 else { return }
        let folder = URL(fileURLWithPath: args[index + 1])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            var settings = ExportSettings()
            settings.name = "Jane Austen"
            settings.contact = "Chawton Cottage\nChawton, Hampshire\njane@example.com"
            if let book = store.library?.books.first {
                // LONGHAND_COVER=/image: a cover for the book (the library copy keeps it).
                if let path = ProcessInfo.processInfo.environment["LONGHAND_COVER"] {
                    store.margin.setCover(of: book.url, from: URL(fileURLWithPath: path))
                }
                // LONGHAND_LETTERED=paper|ink|shelf|frame: the e-book's lettered cover (with no
                // picture), and every style drawn as cover-<style>.png with a sample byline.
                if let name = ProcessInfo.processInfo.environment["LONGHAND_LETTERED"] {
                    settings.letteredCover = LetteredCover.Style(rawValue: name)
                    var text = Exporter.coverText(of: book, store: store)
                    if text.author.isEmpty { text.author = "Jane Austen" }
                    if text.form == nil { text.form = "a novel" }
                    for style in LetteredCover.Style.allCases {
                        if let image = LetteredCover.bitmap(style, text, width: 800),
                           let rep = image.representations.first as? NSBitmapImageRep,
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: folder.appendingPathComponent("cover-\(style.rawValue).png"))
                        }
                    }
                }
                for format in ExportSettings.Format.allCases {
                    settings.format = format
                    let url = folder.appendingPathComponent(Exporter.suggestedName(book, settings))
                    do { try Exporter.export(book, store: store, settings: settings, to: url) } catch {
                        try? "\(error)".write(to: folder.appendingPathComponent("error-\(format.rawValue).txt"), atomically: true, encoding: .utf8)
                    }
                }
            }
            NSApp.terminate(nil)
        }
    }
}


