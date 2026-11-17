import SwiftUI

@main
struct LonghandApp: App {
    @StateObject private var store: LibraryStore
    /// Quitting waits for the commit and push, with a card saying so (`QuitProgress`).
    @NSApplicationDelegateAdaptor(LonghandAppDelegate.self) private var appDelegate
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showMargin") private var showMargin = true
    @AppStorage(ProseFace.defaultsKey) private var proseFace = ProseFace.sfPro.rawValue
    @AppStorage(ProseSize.defaultsKey) private var proseSize = 0
    /// The theme on screen: the kept one, or one being previewed.
    @ObservedObject private var themeState = ThemeState.shared
    @AppStorage(AppTheme.modeKey) private var appearanceMode = "system"
    @AppStorage(StatusBar.countKey) private var showCount = true
    @AppStorage(CardSize.key) private var cardSize = CardSize.medium.rawValue
    @AppStorage(WritingModes.focusKey) private var focus = false
    @AppStorage(WritingModes.unitKey) private var focusUnit = WritingModes.Unit.sentence.rawValue
    @AppStorage(WritingModes.typewriterKey) private var typewriter = false

    init() {
        // Plain 8-bit layers, as before Big Sur. With AppKit's "automatic" layer stores the page
        // was drawn in 16-bit floating point on this Mac's screen, at about twice the cost, and
        // scene switches and typing were slower. A known AppKit setting, used by other Mac
        // apps for the same reason: gist.github.com/lukaskubanek/9a61ac71dc0db8bb04db2028f2635779
        UserDefaults.standard.register(defaults: ["NSViewUsesAutomaticLayerBackingStores": false])
        // No window tabs: macOS adds Show Tab Bar, Show All Tabs and the Window menu's tab
        // commands to any app that allows them, and Longhand has one window per library
        // (owner, 2026-11-13: "remove, or plan real tabs").
        NSWindow.allowsAutomaticWindowTabbing = false
        // Fonts first: the store measures the prose face as it opens the library.
        Snapshot.prepareBackgroundRun()
        AppTheme.reload()
        ScreenplayFont.register()
        let store = LibraryStore()
        _store = StateObject(wrappedValue: store)
        LonghandAppDelegate.store = store
    }

    /// A story is open from inside it (Contents and Page apply).
    private var showingStory: Bool {
        if case .book = store.selection, store.openBook != nil { return true }
        return false
    }

    /// A screenplay is what's open (Read shows its pages).
    private var showingScreenplay: Bool {
        if case .scene(let url) = store.selection { return url.pathExtension.lowercased() == ProseFile.fountain }
        return false
    }

    /// A chapter is what's open (Read and Write apply to nothing else).
    private var showingChapter: Bool {
        if case .chapter = store.selection { return true }
        return false
    }

    var body: some SwiftUI.Scene {
        WindowGroup(id: "main") {
            ContentView()
                // A new theme (chosen or previewed) draws the whole window again in its colours.
                .id(themeState.shown)
                .environmentObject(store)
                .environmentObject(store.margin)
                .environmentObject(store.versions)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.check(userAsked: true) }
            }
            CommandGroup(replacing: .newItem) {
                // Scenes and chapters are made inside a story; stories and folders in the
                // Library.
                Button("New \(store.contextNames.scene)") { store.createSceneInContext() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.openBook == nil || !store.canAddScene)
                Button("New \(store.contextNames.chapter)") { store.createChapterInContext() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.openBook == nil || !store.canAddChapter)
                Button("New Document…") { store.newDocumentShown = true }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(store.library == nil || store.openBook != nil)
                Button("New Folder") { store.createFolder() }
                    .disabled(store.library == nil || store.openBook != nil)
                Button("Import Final Draft…") { store.importFinalDraft() }
                    .disabled(store.library == nil)
                Divider()
                Button("Open Library…") { store.chooseLibrary() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Commit…") { store.versions.sheet = .save }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.library == nil)
                Button("New Tag…") { store.versions.sheet = .draft }
                    .disabled(store.library == nil)
                Button("Compare Commits…") { store.compareVersions() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(store.library == nil)
                RewriteMenu(store: store, versions: store.versions)
                Divider()
                Button("Export…") { store.exportRequested = true }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(store.library?.books.isEmpty ?? true)
                Divider()
                Button("Move to Boneyard") { store.moveSelectionToBoneyard() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(!store.canMoveSelectionToBoneyard)
                Divider()
                Button("Show Library in Finder") { store.revealLibrary() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.library == nil)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Close Library") { store.closeLibrary() }
                    .disabled(store.library == nil)
            }
            CommandMenu("Go") {
                // Out of the story to every story, as the contents' ‹ Library row does.
                Button("Library") { store.showLibrary() }
                    .keyboardShortcut("4", modifiers: .command)
                    .disabled(store.library == nil || store.openBook == nil)
                Button("Switch Scene…") { store.switcherShown = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(store.library == nil)
                Button("Switch Document…") { store.documentSwitcherShown = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(store.library?.books.isEmpty ?? true)
                Divider()
                // The keyboard, from pane to pane: the numbers are the ones that show and
                // hide the contents (1) and the margin (2) and flip the page and cards (3).
                Button("Contents") { Panes.focus(.contents, in: store) }
                    .keyboardShortcut("1", modifiers: [.option, .command])
                    .disabled(store.library == nil)
                Button("Margin") { Panes.focus(.margin, in: store) }
                    .keyboardShortcut("2", modifiers: [.option, .command])
                    .disabled(store.library == nil)
                Button("Page") { Panes.focus(.page, in: store) }
                    .keyboardShortcut("3", modifiers: [.option, .command])
                    .disabled(store.library == nil)
                Divider()
                Button("Previous Scene") { store.stepScene(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .command])
                Button("Next Scene") { store.stepScene(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .command])
                Divider()
                Button("Previous Chapter") { store.stepChapter(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                Button("Next Chapter") { store.stepChapter(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette…") { store.togglePalette() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(store.library == nil)
                Button("Find in Library…") { store.searchShown = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(store.library == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Cheat Sheet") { store.cheatSheetShown.toggle() }
                    .keyboardShortcut("/", modifiers: .command)
                Button("Git in Four Steps") { store.gitIntroShown = true }
            }
            CommandGroup(replacing: .textFormatting) {
                Button("Bold") { Commands.format(.bold, margin: store.margin) }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { Commands.format(.italic, margin: store.margin) }
                    .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Comment on Selection") { Commands.comment(margin: store.margin) }
                    .keyboardShortcut("j", modifiers: .command)
            }
            CommandGroup(replacing: .sidebar) {
                Button(showSidebar ? "Hide Contents" : "Show Contents") { showSidebar.toggle() }
                    .keyboardShortcut("1", modifiers: .command)
                Button(showMargin ? "Hide Margin" : "Show Margin") { showMargin.toggle() }
                    .keyboardShortcut("2", modifiers: .command)
                Button(store.viewMode == .cards ? "Show as Page" : "Show as Cards") { store.toggleCards() }
                    .keyboardShortcut("3", modifiers: .command)
                Picker("Card Size", selection: $cardSize) {
                    ForEach(CardSize.allCases) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
                // A chapter set like the book, or the same chapter for editing; a story's
                // contents, or the whole story to read.
                Button(showingStory ? (store.viewMode == .page ? "Show Contents" : "Read Story")
                       : showingScreenplay ? (store.viewMode == .read ? "Write Screenplay" : "Read Screenplay")
                       : (store.viewMode == .write ? "Read Chapter" : "Write in Chapter")) {
                    store.togglePageView()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!showingChapter && !showingStory && !showingScreenplay)
                Divider()
                Toggle("Focus", isOn: $focus)
                    .keyboardShortcut("d", modifiers: .command)
                Picker("Focus On", selection: $focusUnit) {
                    ForEach(WritingModes.Unit.allCases) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
                Toggle("Typewriter Scrolling", isOn: $typewriter)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                // ⌘. (two keys, neither used in typing). A sheet keeps it for itself.
                Toggle("Clear Desk", isOn: Binding(
                    get: { store.deskCleared },
                    set: { on in
                        guard NSApp.keyWindow?.attachedSheet == nil, NSApp.keyWindow?.isSheet != true else { return }
                        store.deskCleared = on
                    }))
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(store.library == nil)
                Divider()
                Toggle("Word Count", isOn: $showCount)
                Divider()
                Picker("Appearance", selection: Binding(
                    get: { appearanceMode },
                    set: { AppTheme.setMode($0) })) {
                    Text("Match System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .disabled(AppTheme.current.darkOnly)
                Picker("Font", selection: $proseFace) {
                    ForEach(ProseFace.allCases) { face in
                        Text(face.title).tag(face.rawValue)
                    }
                }
                // ⌘= works too (WindowChrome), as in other Mac apps.
                Button("Bigger Text") { ProseSize.step(1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(proseSize >= ProseSize.range.upperBound)
                Button("Smaller Text") { ProseSize.step(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(proseSize <= ProseSize.range.lowerBound)
                Button("Actual Size") { ProseSize.step(0) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(proseSize == 0)
                Divider()
            }
        }

        Settings {
            SettingsView(versions: store.versions)
        }
    }
}

/// File › New Branch…, Switch Branch, Merge, Delete Branch, Fetch, Push and Git Activity. Watches the versions store itself, so
/// the menu follows which rewrite is open.
private struct RewriteMenu: View {
    let store: LibraryStore
    @ObservedObject var versions: VersionStore

    var body: some View {
        Divider()
        Button("New Branch…") { versions.sheet = .rewrite }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(store.library == nil || !versions.available)
        Menu("Switch Branch") {
            // Toggles, so the open one carries the menu's own checkmark.
            Toggle("main", isOn: Binding(
                get: { versions.currentRewrite == nil },
                set: { if $0 { store.switchTo(nil) } }))
            ForEach(versions.rewrites) { rewrite in
                Toggle(rewrite.title, isOn: Binding(
                    get: { versions.currentRewrite == rewrite },
                    set: { if $0 { store.switchTo(rewrite) } }))
            }
        }
        .disabled(versions.rewrites.isEmpty)
        Button("Merge into main…") { versions.confirm = .keep }
            .disabled(versions.currentRewrite == nil)
        Button("Delete Branch") { versions.confirm = .discard }
            .disabled(versions.currentRewrite == nil)
        Divider()
        Button("Fetch") { versions.syncNow() }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!versions.hasBackup)
        Button("Push") { store.saveNow(); versions.commitAndPush() }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!versions.hasBackup)
        Button(versions.hasBackup ? "Git Activity…" : "Connect Repository…") { versions.sheet = .backup }
            .disabled(store.library == nil || !versions.available)
        Divider()
    }
}
