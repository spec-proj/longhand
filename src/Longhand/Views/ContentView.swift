import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    /// Not observed: the window only needs it for the toolbar's actions, and observing it
    /// redrew the whole window whenever a comment was focused.
    private var margin: MarginStore { store.margin }
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showMargin") private var showMargin = true
    @AppStorage("marginTab") private var marginTab = MarginStore.Tab.comments.rawValue
    @AppStorage(ProseFace.defaultsKey) private var proseFace = ProseFace.sfPro.rawValue
    @AppStorage(ProseSize.defaultsKey) private var proseSize = 0
    @AppStorage("showCards") private var showCards = false
    @AppStorage(ChapterDocumentView.readingKey) private var chapterReading = true
    @AppStorage(StoryPage.key) private var storyPage = false
    @State private var renameTarget: ManuscriptItem?
    /// The contents column's width, panel and gap included: drag its right edge (remembered).
    @AppStorage("contentsWidth") private var contentsWidth = Double(Layout.contentsWidth)
    @State private var dragStart: Double?
    /// Where the toolbar put the path's item, in the window: the path pads itself out from
    /// there so it starts at the page's left edge.
    @State private var pathItemX: CGFloat = 0
    /// The window's width, so the path knows how much room the toolbar has for it.
    @State private var windowWidth: CGFloat = 1200

    var body: some View {
        Group {
            if store.library == nil {
                WelcomeView()
                    // The band above it in the page's own colour (macOS paints it white).
                    .toolbarBackground(Color(PaperTheme.paper), for: .windowToolbar)
                    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            } else {
                VStack(spacing: 0) {
                    // One hairline under the toolbar, across the whole window.
                    Rectangle()
                        .fill(Color(PaperTheme.frame))
                        .frame(height: 1)
                        .deskFade(store.deskCleared)
                    // Three framed panels on the grey window; the contents can be dragged
                    // wider. (A split view opened the side columns at their widest and
                    // squeezed the page.)
                    HStack(alignment: .top, spacing: Layout.inset) {
                        if showSidebar || store.searchShown {
                            Group {
                                if store.searchShown {
                                    LibrarySearch()
                                        .panel()
                                } else {
                                    SidebarView()
                                }
                            }
                            .frame(width: contentsWidth - Layout.inset)
                            .overlay(alignment: .trailing) { resizeHandle }
                            .deskFade(store.deskCleared)
                        }
                        DetailArea()
                            .background(Color(PaperTheme.paper))
                            .panel(!store.deskCleared)
                            .frame(minWidth: 420, maxWidth: .infinity)
                            .id("\(proseFace) \(proseSize)")
                        if showMargin {
                            MarginView()
                                .frame(width: Layout.marginWidth - Layout.inset)
                                .deskFade(store.deskCleared)
                        }
                    }
                    // The same margin all round: the three panels share a top and a bottom.
                    .padding(Layout.inset)
                    StatusBar()
                        .deskFade(store.deskCleared)
                }
                // Clear Desk fades everything but the page where it stands, and the window
                // takes the page's colour: nothing moves, so the text stays exactly where it was.
                .background(Color(store.deskCleared ? PaperTheme.paper : PaperTheme.chrome)
                    .animation(.easeInOut(duration: Layout.deskFade), value: store.deskCleared))
                .overlay {
                    if store.quickOpenShown {
                        QuickOpen(palette: store.palette)
                    }
                    if store.switcherShown {
                        SceneSwitcher()
                    }
                    if store.cheatSheetShown {
                        CheatSheet()
                    }
                }
                .toolbar { toolbar }
                .toolbar(removing: .title)
                // macOS paints the toolbar band itself (white), whatever the window's colour.
                .toolbarBackground(Color(store.deskCleared ? PaperTheme.paper : PaperTheme.chrome), for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            if abs(width - windowWidth) > 0.5 { windowWidth = width }
        }
        .background(WindowChrome(onPointer: {
            if store.isTyping { store.isTyping = false }
        }, onEscape: {
            guard !store.quickOpenShown, !store.switcherShown else { return false }
            if store.cheatSheetShown {
                store.cheatSheetShown = false
                return true
            }
            // Escape brings the desk back.
            guard store.deskCleared else { return false }
            store.deskCleared = false
            return true
        }))
        .alert(
            store.errorMessage ?? "",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        }
        .alert(
            "Use this folder as a library?",
            isPresented: Binding(
                get: { store.pendingLibraryURL != nil },
                set: { if !$0 { store.pendingLibraryURL = nil } }
            )
        ) {
            Button("Use Folder") { store.confirmPendingLibrary() }
            Button("Cancel", role: .cancel) { store.pendingLibraryURL = nil }
        } message: {
            Text("“\(store.pendingLibraryURL?.lastPathComponent ?? "")” isn’t a Longhand library. Every folder inside it will appear as a story. Longhand won’t move your files.")
        }
        .sheet(isPresented: $store.exportRequested) {
            if let book = Exporter.book(in: store) {
                ExportSheet(book: book)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $store.gitIntroShown) { GitIntro() }
        // The Git introduction, once, the first time a library is open (never in hidden runs).
        .onChange(of: store.library != nil, initial: true) { _, open in
            guard open, !Snapshot.isBackgroundRun, !UserDefaults.standard.bool(forKey: GitIntro.seenKey) else { return }
            store.gitIntroShown = true
        }
        .modifier(VersionSheets())
        .sheet(item: $renameTarget) { item in
            RenameSheet(title: item.title) { newTitle in
                store.rename(item, to: newTitle)
            }
        }
        .onAppear {
            AppTheme.applyAppearance()
            Snapshot.applyAppearance()
            Snapshot.prepareMargin(margin)
            Snapshot.prepareExport(store)
            Snapshot.prepareVersions(store)
            Snapshot.prepareSheets(store)
            Snapshot.prepareCompare(store)
            Snapshot.prepareChanges(store)
            Snapshot.prepareExtras(store)
            Snapshot.runLive(store)
            Snapshot.prepareRewrite(store)
            Snapshot.preparePreview(store)
            Snapshot.prepareFind(store)
            if Snapshot.wantsChapter,
               let chapter = store.library?.books.first?.chapters.first {
                store.selection = .chapter(chapter.url)
            } else if Snapshot.wantsBook,
                      let book = store.library?.books.first {
                store.selection = .book(book.url)
            }
            SelfTest.runIfRequested(store: store)
            PerfTest.runIfRequested(store: store)
            ExportSample.runIfRequested(store: store)
            Snapshot.takeIfRequested()
        }
    }

    /// The page's left edge, in the window, less where the path's item begins; at least a
    /// small gap after the contents button when the contents is hidden.
    /// The toolbar's width left for the path: the window less where the path starts and the
    /// buttons on the right (Page | Cards when shown, Find and Comment, the margin toggle).
    private var pathRoom: CGFloat {
        let switchShown: Bool
        switch store.selection {
        case .chapter: switchShown = true
        case .book: switchShown = store.openBook != nil
        default: switchShown = false
        }
        var right: CGFloat = 150 + (switchShown ? 190 : 0)
        // Three segments (Read, Write, Cards; Contents, Page, Cards).
        if switchShown { right += 60 }
        return max(160, windowWidth - pathItemX - pathPadding - right)
    }

    private var pathPadding: CGFloat {
        let pageLeft = showSidebar || store.searchShown ? CGFloat(contentsWidth) + Layout.inset : Layout.inset
        return max(8, pageLeft - pathItemX)
    }

    /// The contents column's right edge, in the gap beside it: drag to resize, like Finder's
    /// sidebar. 220–440pt.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: Layout.inset)
            .contentShape(Rectangle())
            .offset(x: Layout.inset)
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? contentsWidth
                    if dragStart == nil { dragStart = start }
                    contentsWidth = min(440, max(220, (start + drag.translation.width).rounded()))
                }
                .onEnded { _ in dragStart = nil })
            .help("Drag to resize")
    }

    // MARK: - Path

    /// Library › Book › Chapter › Scene (owner, 2026-11-13: the library's name, which is its
    /// repository's, comes first; clicking it shows every story, as the contents' Library row does).
    private var currentPathSegments: [PathSegment] {
        guard let library = store.library else { return [] }
        // The repository's name when the library has a remote ("writing"), else its folder's.
        let name = store.versions.remoteAddress.map(Git.repositoryName(of:)) ?? library.name
        let home = PathSegment(id: 0, title: name, isCurrent: false,
                               action: { store.openBook = nil }, help: "Show every story in \(name)")
        let rest = placeSegments(in: library)
        return rest.first?.id == 0 ? rest : [home] + rest
    }

    private func placeSegments(in library: Library) -> [PathSegment] {

        switch store.selection {
        case .book(let url):
            guard let book = store.book(for: url) else { return [] }
            return [PathSegment(id: 1, title: book.title, isCurrent: true)]

        case .chapter(let url):
            guard let chapter = store.chapter(for: url) else { return [] }
            var segments: [PathSegment] = []
            if let book = library.books.first(where: { $0.chapters.contains { $0.url == url } }) {
                segments.append(PathSegment(
                    id: 1,
                    title: book.title,
                    isCurrent: false,
                    action: { store.selection = .book(book.url) },
                    help: "Open \(book.title)"
                ))
            }
            segments.append(PathSegment(id: 2, title: chapter.title, isCurrent: true))
            return segments

        case .scene(let url):
            guard let scene = store.scene(for: url), let location = store.location(ofScene: url) else {
                return []
            }
            return [
                PathSegment(
                    id: 1,
                    title: location.book.title,
                    isCurrent: false,
                    action: { store.selection = .book(location.book.url) },
                    help: "Open \(location.book.title)"
                ),
                PathSegment(
                    id: 2,
                    title: location.chapter.title,
                    isCurrent: false,
                    action: { store.selection = .chapter(location.chapter.url) },
                    help: "Open \(location.chapter.title)"
                ),
                PathSegment(
                    id: 3,
                    title: scene.title,
                    isCurrent: true,
                    action: {
                        renameTarget = ManuscriptItem(
                            url: scene.url,
                            title: scene.title,
                            order: scene.order,
                            kind: .scene
                        )
                    },
                    help: "Rename this scene"
                )
            ]

        case nil:
            return [PathSegment(id: 0, title: store.versions.remoteAddress.map(Git.repositoryName(of:)) ?? library.name, isCurrent: true)]
        }
    }

    // MARK: - Toolbar

    /// Left: the contents toggle and the path. Right: Find, Comment, and the margin toggle.
    /// Frameless buttons with SF Symbols. `sharedBackgroundVisibility(.hidden)`
    /// stops macOS drawing its glass capsule behind each item. While you type, the contents
    /// fade out; moving the mouse brings them back.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SquareToolbarButton(
                icon: .openPanelLeft,
                tooltip: showSidebar ? "Hide Contents" : "Show Contents",
                width: 28,
                height: Layout.controlHeight,
                iconSize: 14,
                bordered: false,
                isOn: showSidebar
            ) {
                showSidebar.toggle()
            }
            .frame(width: 28, height: Layout.controlHeight)
            .modifier(TypingFade(typing: store.isTyping, cleared: store.deskCleared))
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            HStack(spacing: 0) {
                WindowXReader { x in if abs(x - pathItemX) > 0.5 { pathItemX = x } }
                    .frame(width: 0, height: 1)
                PathBar(segments: currentPathSegments, room: pathRoom)
                    .padding(.leading, pathPadding)
            }
            .modifier(TypingFade(typing: store.isTyping, cleared: store.deskCleared))
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .primaryAction) {
            Group {
                switch store.selection {
                case .chapter:
                    ViewSwitch(showCards: $showCards, first: ("Read", "Write"), isFirst: $chapterReading)
                case .book where store.openBook != nil:
                    ViewSwitch(showCards: $showCards, first: ("Contents", "Page"), isFirst: Binding(
                        get: { !storyPage }, set: { storyPage = !$0 }))
                default:
                    EmptyView()
                }
            }
            .padding(.trailing, 8)
            .modifier(TypingFade(typing: store.isTyping, cleared: store.deskCleared))
        }
        .sharedBackgroundVisibility(.hidden)

        // Find and Comment share one frame, as a pair.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 4) {
                SquareToolbarButton(
                    icon: .search, tooltip: "Find",
                    width: 30, height: Layout.controlHeight, iconSize: 13, bordered: false
                ) {
                    Commands.showFind(in: margin)
                }
                .frame(width: 30, height: Layout.controlHeight)
                SquareToolbarButton(
                    icon: .addComment, tooltip: "Comment on Selection",
                    width: 30, height: Layout.controlHeight, iconSize: 14, bordered: false
                ) {
                    Commands.comment(margin: margin)
                }
                .frame(width: 30, height: Layout.controlHeight)
            }
            .padding(.trailing, 8)
            .modifier(TypingFade(typing: store.isTyping, cleared: store.deskCleared))
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            SquareToolbarButton(
                icon: .openPanelRight,
                tooltip: showMargin ? "Hide Margin" : "Show Margin",
                width: 28,
                height: Layout.controlHeight,
                iconSize: 14,
                bordered: false,
                isOn: showMargin
            ) {
                showMargin.toggle()
            }
            .frame(width: 28, height: Layout.controlHeight)
            .modifier(TypingFade(typing: store.isTyping, cleared: store.deskCleared))
        }
        .sharedBackgroundVisibility(.hidden)
    }

}

/// Window-level settings SwiftUI doesn't expose: a crisp one-pixel line under the toolbar,
/// as in classic Mac windows, instead of a soft scroll-edge fade.
struct WindowChrome: NSViewRepresentable {
    /// Called when the pointer moves or clicks in the window (brings faded chrome back).
    var onPointer: () -> Void = {}
    /// Escape anywhere in the window; returns true if it was used (closing the cheat sheet).
    var onEscape: () -> Bool = { false }

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.onPointer = onPointer
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.onPointer = onPointer
        view.onEscape = onEscape
    }

    final class ChromeView: NSView {
        var onPointer: () -> Void = {}
        var onEscape: () -> Bool = { false }
        private var monitor: Any?
        private var keys: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let keys { NSEvent.removeMonitor(keys) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Snapshot.hide(window)
            window.acceptsMouseMovedEvents = true
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
                ) { [weak self] event in
                    if event.window === self?.window { self?.onPointer() }
                    return event
                }
            }
            if keys == nil {
                // ⌘= for Bigger Text, as in Safari and TextEdit; the menu's ⌘+ needs Shift.
                keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53, event.window === self?.window,
                       event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                       self?.onEscape() == true {
                        return nil
                    }
                    guard event.window === self?.window,
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "=" else { return event }
                    ProseSize.step(1)
                    return nil
                }
            }
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            // The toolbar band takes the window's grey, so it reads as one with the panels' ground.
            window.backgroundColor = PaperTheme.chrome
        }
    }
}

/// Read, Write or Cards for a chapter (Read sets it like the book, Write is the same chapter
/// for editing); Contents, Page or Cards for a story (its contents page, the whole story to
/// read, or its cards). Square segments in a hairline frame.
struct ViewSwitch: View {
    @Binding var showCards: Bool
    /// The two pages before Cards, and whether the first is the one shown.
    let first: (String, String)
    @Binding var isFirst: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment(first.0, on: !showCards && isFirst) { showCards = false; isFirst = true }
            Rectangle().fill(Color(PaperTheme.controlBorder)).frame(width: 1)
            segment(first.1, on: !showCards && !isFirst) { showCards = false; isFirst = false }
            Rectangle().fill(Color(PaperTheme.controlBorder)).frame(width: 1)
            segment("Cards", on: showCards) { showCards = true }
        }
        .frame(height: Layout.controlHeight)
        .background(Color(PaperTheme.controlFill))
        .roundedFrame(Color(PaperTheme.controlBorder), lineWidth: 1)
        .help("\(first.0), \(first.1) or Cards")
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Layout.chromeSize, weight: on ? .semibold : .medium))
                .foregroundStyle(Color(on ? PaperTheme.ink : PaperTheme.secondary))
                .padding(.horizontal, 11)
                .frame(maxHeight: .infinity)
                .background(on ? Color(PaperTheme.controlOn) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The page, or the comparison in its place. Its own view, so version changes (a backup
/// finishing, say) redraw only this, never the whole window.
private struct DetailArea: View {
    @EnvironmentObject private var versions: VersionStore

    var body: some View {
        if versions.mergePlan != nil {
            MergeView()
        } else if versions.comparing {
            CompareView()
        } else {
            DetailView()
        }
    }
}

/// Save Version, Mark as Draft and Back Up sheets, watched apart from the window for the same
/// reason.
private struct VersionSheets: ViewModifier {
    @EnvironmentObject private var versions: VersionStore
    @EnvironmentObject private var store: LibraryStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $versions.sheet) { kind in
                VersionSheet(kind: kind)
                    .environmentObject(versions)
                    .environmentObject(store)
            }
            .alert(title, isPresented: Binding(get: { versions.confirm != nil }, set: { if !$0 { versions.confirm = nil } })) {
                if versions.confirm == .keep {
                    Button("Merge") { versions.confirm = nil; store.keepRewrite() }
                } else {
                    Button("Delete Branch", role: .destructive) { versions.confirm = nil; store.discardRewrite() }
                }
                Button("Cancel", role: .cancel) { versions.confirm = nil }
            } message: {
                Text(message)
            }
    }

    private var name: String { versions.currentRewrite.map { "“\($0.title)”" } ?? "this branch" }

    private var title: String {
        versions.confirm == .keep ? "Merge \(name) into main?" : "Delete the branch \(name)?"
    }

    private var message: String {
        versions.confirm == .keep
            ? "Everything written on this branch is added to main. If main and the branch changed the same passage, Longhand shows both and you pick one."
            : "You return to main. The branch’s last commit is kept as a tag, so you can still compare or restore it."
    }
}

extension View {
    /// Clear Desk: faded out and out of reach, but still taking its room, so nothing else
    /// moves when the desk is cleared or comes back.
    func deskFade(_ cleared: Bool) -> some View {
        opacity(cleared ? 0 : 1)
            .allowsHitTesting(!cleared)
            .animation(.easeInOut(duration: Layout.deskFade), value: cleared)
    }

    /// Sets this view in a framed panel; `framed: false` keeps the same view without the frame
    /// (Clear Desk), so the page inside isn't rebuilt.
    func panel(_ framed: Bool = true) -> some View {
        roundedFrame(framed ? Color(PaperTheme.frame) : .clear, radius: framed ? Layout.panelRadius : 0)
    }
}

/// Toolbar items fade out while you type (0.6s) and come back when the pointer moves (0.15s).
/// The animation belongs to the item alone: set on the whole window, it also slowed every
/// other change that happened on the first keystroke, such as the word count.
private struct TypingFade: ViewModifier {
    let typing: Bool
    /// Clear Desk: put away until it's turned off, whatever the pointer does.
    var cleared = false

    func body(content: Content) -> some View {
        content
            .opacity(typing ? 0 : 1)
            .animation(.easeOut(duration: typing ? 0.6 : 0.15), value: typing)
            .deskFade(cleared)
    }
}

/// Reports its own left edge in window coordinates, whenever it moves.
struct WindowXReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class Reader: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        private var last: CGFloat = -1

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func layout() { super.layout(); report() }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); report() }

        func report() {
            guard window != nil else { return }
            let x = convert(NSPoint.zero, to: nil).x
            guard abs(x - last) > 0.5 else { return }
            last = x
            DispatchQueue.main.async { [onChange] in onChange(x) }
        }
    }
}
