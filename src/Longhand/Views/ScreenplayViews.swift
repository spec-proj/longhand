import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Read: the script as pages

/// A screenplay's Read page (owner, 2026-11-14; mock-up
/// https://claude.ai/artifact/5he383bmwa3ubvzCfKYMbt): the script set on real pages, exactly as
/// the PDF export sets it (title page, (MORE) and (CONT'D), page numbers). Read only.
struct ScreenplayReader: View {
    @EnvironmentObject private var store: LibraryStore
    let scene: Scene

    /// Read or Write for a screenplay: the toolbar's switch, ⌘R. Write by default.
    static let readingKey = "screenplayReading"
    /// Posted with a scene's index (0-based) to show its page.
    static let goToScene = Notification.Name("LonghandScreenplayGoToScene")

    var body: some View {
        VStack(spacing: 0) {
            if let location = store.location(ofScene: scene.url) {
                SceneHeader(scene: scene, book: location.book)
                    .deskFade(store.deskCleared)
            }
            // The title page is made with the pages, only when the text changes: it reads
            // Git for the last draft, which a view body must never do.
            ScreenplayPages(text: store.text, version: store.textVersion, scene: scene.url, margin: store.margin,
                            titlePage: { [weak store] document in
                                guard let store, let book = store.location(ofScene: scene.url)?.book else { return nil }
                                return Exporter.screenplayTitlePage(of: book, document: document, store: store)
                            })
        }
    }
}

/// The pages, drawn as the PDF export draws them (`ScreenplayPDF`), one under another on the
/// window's grey, each the width the pane allows (at most a quarter bigger than print).
private struct ScreenplayPages: NSViewRepresentable {
    let text: String
    let version: Int
    let scene: URL
    var margin: MarginStore
    /// Makes the title page for the script's document (nil for none).
    let titlePage: (Fountain.Document) -> ScreenplayTitlePage?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.drawsBackground = true
        scroll.backgroundColor = PaperTheme.chrome
        let sheets = SheetsView()
        sheets.autoresizingMask = [.width]
        scroll.documentView = sheets
        context.coordinator.sheets = sheets
        context.coordinator.observe()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let key = "\(scene.path)#\(version)#\((text as NSString).hash)"
        guard key != context.coordinator.key, let sheets = context.coordinator.sheets else { return }
        context.coordinator.key = key
        let document = Fountain.document(text)
        let laid = ScreenplayLayout.paginate(document)
        let title = titlePage(document)
        sheets.titlePage = title
        sheets.pages = laid.pages
        sheets.headingPages = laid.headingPages.map { $0 + (title == nil ? 0 : 1) }
        sheets.fit(width: scroll.contentSize.width)
        context.coordinator.scene = scene
        context.coordinator.margin = margin
        // Come from Write (⌘R): the same part of the script at the top. A moment later: SwiftUI
        // makes this page before it takes Write down, and Write leaves its place as it goes.
        DispatchQueue.main.async { [weak sheets, weak margin, scene] in
            guard let sheets, let margin, let anchor = margin.readingAnchor,
                  let top = anchor.top ?? anchor.caret, top.scene == scene else { return }
            margin.readingAnchor = nil
            if let width = sheets.superview?.bounds.width { sheets.fit(width: width) }
            sheets.show(source: top.location)
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // Leaving for Write: it opens at the part of the script at the top here.
        if let scene = coordinator.scene, let source = coordinator.sheets?.topSource() {
            coordinator.margin?.readingAnchor = MarginStore.ReadingAnchor(top: (scene, source), caret: nil)
        }
    }

    final class Coordinator {
        weak var sheets: SheetsView?
        var scene: URL?
        weak var margin: MarginStore?
        var key = ""
        private var token: NSObjectProtocol?

        func observe() {
            token = NotificationCenter.default.addObserver(forName: ScreenplayReader.goToScene, object: nil, queue: .main) { [weak self] note in
                guard let index = note.object as? Int else { return }
                self?.sheets?.show(scene: index)
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

/// Every page of a screenplay, title page first, in the theme's card and ink.
final class SheetsView: NSView {
    var titlePage: ScreenplayTitlePage?
    var pages: [ScreenplayLayout.Page] = []
    var headingPages: [Int] = []
    private let paper = ScreenplayLayout.Paper.letter
    private var scale: CGFloat = 1
    private let gap: CGFloat = 24

    override var isFlipped: Bool { true }

    private var count: Int { pages.count + (titlePage == nil ? 0 : 1) }

    override func resize(withOldSuperviewSize size: NSSize) {
        super.resize(withOldSuperviewSize: size)
        if let width = superview?.bounds.width { fit(width: width) }
    }

    func fit(width: CGFloat) {
        scale = max(0.5, min(1.25, (width - 2 * gap) / paper.size.width))
        let height = CGFloat(count) * (paper.size.height * scale + gap) + gap
        setFrameSize(NSSize(width: width, height: max(height, superview?.bounds.height ?? 0)))
        needsDisplay = true
    }

    private func origin(of index: Int) -> NSPoint {
        NSPoint(x: ((bounds.width - paper.size.width * scale) / 2).rounded(),
                y: gap + CGFloat(index) * (paper.size.height * scale + gap))
    }

    /// The page and row where the element starting at `source` (or the last before it) is.
    private func row(of source: Int) -> (page: Int, row: Int)? {
        var found: (Int, Int)?
        for (p, page) in pages.enumerated() {
            for (r, s) in page.sources.enumerated() where s <= source {
                if found == nil || s >= sourceAt(found!) { found = (p, r) }
            }
        }
        return found.map { (page: $0.0 + (titlePage == nil ? 0 : 1), row: $0.1) }
    }

    private func sourceAt(_ place: (Int, Int)) -> Int { pages[place.0].sources[place.1] }

    /// Scrolls so the element starting at `source` is at the top.
    func show(source: Int) {
        guard let place = row(of: source) else { return }
        let y = origin(of: place.page).y + (72 + CGFloat(place.row) * ScreenplayPDF.row) * scale - gap
        scroll(NSPoint(x: 0, y: max(0, y)))
    }

    /// Where in the file the first line on show comes from.
    func topSource() -> Int? {
        let top = visibleRect.minY + gap
        let pageHeight = paper.size.height * scale + gap
        let index = max(0, Int((top - gap) / pageHeight))
        let page = index - (titlePage == nil ? 0 : 1)
        guard pages.indices.contains(page) else { return pages.first?.sources.first }
        let within = (top - origin(of: index).y) / scale - 72
        // Half a row's grace: a page scrolled to a row reads back as that row, not the one above.
        let row = min(max(0, Int((within + ScreenplayPDF.row / 2) / ScreenplayPDF.row)), max(0, pages[page].sources.count - 1))
        return pages[page].sources[safe: row] ?? pages[page].sources.first
    }

    /// Scrolls to the page a scene heading is on.
    func show(scene: Int) {
        guard scene < headingPages.count else { return }
        let top = origin(of: headingPages[scene]).y - gap
        scroll(NSPoint(x: 0, y: max(0, top)))
    }

    override func draw(_ dirtyRect: NSRect) {
        PaperTheme.chrome.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for index in 0..<count {
            let o = origin(of: index)
            let frame = NSRect(x: o.x, y: o.y, width: paper.size.width * scale, height: paper.size.height * scale)
            guard frame.intersects(dirtyRect) else { continue }
            PaperTheme.card.setFill()
            frame.fill()
            PaperTheme.frame.setStroke()
            NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
            context.saveGState()
            context.translateBy(x: o.x, y: o.y)
            context.scaleBy(x: scale, y: scale)
            if let titlePage, index == 0 {
                ScreenplayPDF.drawTitlePage(titlePage, paper: paper, ink: PaperTheme.ink)
            } else {
                let page = index - (titlePage == nil ? 0 : 1)
                ScreenplayPDF.drawSheet(pages[page], index: page, ink: PaperTheme.ink)
            }
            context.restoreGState()
        }
    }
}

// MARK: - Export

/// How a screenplay is exported, remembered with the library's export choices.
struct ScreenplayChoices: Codable, Equatable {
    enum Format: String, Codable, CaseIterable {
        case pdf, finalDraft, fountain
        var title: String {
            switch self {
            case .pdf: return "PDF"
            case .finalDraft: return "Final Draft"
            case .fountain: return "Fountain"
            }
        }
        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .finalDraft: return "fdx"
            case .fountain: return "fountain"
            }
        }
    }

    var format: Format = .pdf
    var paper: ScreenplayLayout.Paper = .letter
    var titlePage = true
    var sceneNumbers = false
}

/// File › Export… for a screenplay (mock-up board 4): PDF, Final Draft or Fountain; paper;
/// a title page and scene numbers; the author from the story's page and the last draft.
struct ScreenplayExportSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: Book

    @State private var choices = ScreenplayChoices()
    @State private var failure: String?
    @State private var draft: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export \(book.title)")
                .font(.headline)
                .foregroundStyle(Color(PaperTheme.ink))
                .padding(.bottom, 18)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    label("Format")
                    SquareSegments(options: ScreenplayChoices.Format.allCases, title: \.title, selection: $choices.format)
                }
                GridRow {
                    label("Paper")
                    SquareSegments(options: ScreenplayLayout.Paper.allCases, title: \.title, selection: $choices.paper)
                        .disabled(choices.format != .pdf)
                        .opacity(choices.format == .pdf ? 1 : 0.5)
                        .help(choices.format == .pdf ? "" : "Final Draft and Fountain files take their paper from the app that opens them")
                }
                GridRow(alignment: .top) {
                    label("Include").padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Title page", isOn: $choices.titlePage)
                        Toggle("Scene numbers", isOn: $choices.sceneNumbers)
                            .help("For a shooting script: each scene heading numbered in both margins")
                            .disabled(choices.format == .fountain)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: Layout.chromeSize))
                }
            }

            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1).padding(.vertical, 20)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    label("Written by")
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(byline ?? "No author chosen")
                            .font(.system(size: Layout.chromeSize))
                            .foregroundStyle(Color(byline == nil ? PaperTheme.secondary : PaperTheme.ink))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Choose Author…") {
                            dismiss()
                            store.openBook = nil
                            store.selection = .book(book.url)
                        }
                        .buttonStyle(SquareButtonStyle())
                        .help("Choose the author on the story’s page")
                    }
                }
                if let draft {
                    GridRow(alignment: .firstTextBaseline) {
                        label("Draft")
                        Text(draft)
                            .font(.system(size: Layout.chromeSize))
                            .foregroundStyle(Color(PaperTheme.ink))
                    }
                }
            }

            if let failure {
                Text(failure)
                    .font(.system(size: Layout.detailSize))
                    .foregroundStyle(Color(PaperTheme.accent))
                    .padding(.leading, Layout.sheetLabel + 16)
                    .padding(.top, 12)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SquareButtonStyle(primary: true))
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 520)
        .background(Color(PaperTheme.paper))
        .onAppear {
            store.adoptExportAuthor()
            choices = store.loadExportSettings().screenplay
            draft = store.versions.latestDraft?.name
        }
    }

    private var byline: String? {
        var author = ExportSettings()
        author.useAuthor(store.margin.info(for: book.url))
        return author.byline.isEmpty ? nil : author.byline
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(Color(PaperTheme.secondary))
            .frame(width: Layout.sheetLabel, alignment: .leading)
    }

    private func export() {
        var settings = store.loadExportSettings()
        settings.screenplay = choices
        store.saveExportSettings(settings)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(FileNaming.sanitized(book.title)).\(choices.format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.exportScreenplay(book, store: store, choices: choices, to: url)
            dismiss()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            failure = "Couldn’t export: \(error.localizedDescription)"
        }
    }
}

// MARK: - Import

extension LibraryStore {
    /// File › Import Final Draft…: a `.fdx` script becomes a new screenplay story, its text in
    /// Fountain (the original file is left as it was).
    func importFinalDraft() {
        guard libraryURL != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fdx") ?? .xml]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Final Draft script to bring in as a screenplay."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFinalDraft(from: url)
    }

    /// Imports one file. Returns the new story's script, or nil (with an error shown).
    @discardableResult
    func importFinalDraft(from url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url), let script = FinalDraft.read(data) else {
            errorMessage = "“\(url.lastPathComponent)” isn’t a Final Draft script Longhand can read."
            return nil
        }
        let title = url.deletingPathExtension().lastPathComponent
        return createScreenplay(title: title, text: FinalDraft.fountain(script))
    }
}

extension Exporter {
    /// The title page for a screenplay: the file's own `Title:` keys, else the story's title,
    /// its author (byline; name and contact details at the foot) and its last draft.
    static func screenplayTitlePage(of book: Book, document: Fountain.Document, store: LibraryStore) -> ScreenplayTitlePage {
        var author = ExportSettings()
        author.useAuthor(store.margin.info(for: book.url))
        var contact: [String] = []
        if !author.name.isEmpty, author.name != author.byline { contact.append(author.name) }
        contact += author.contact.split(separator: "\n").map(String.init)
        // The last draft tagged, dated the day it was tagged (not the day of export).
        var draft: [String] = []
        if let last = store.versions.latestDraft {
            draft = [last.name, last.date.formatted(.dateTime.day().month(.wide).year())]
        }
        return ScreenplayTitlePage.make(document: document, storyTitle: book.title,
                                        author: author.byline.isEmpty ? nil : author.byline, contact: contact, draft: draft)
    }

    static func exportScreenplay(_ book: Book, store: LibraryStore, choices: ScreenplayChoices, to url: URL) throws {
        store.saveNow()
        guard let scene = book.document else { return }
        let text = store.fileText(at: scene.url)
        let document = Fountain.document(text)
        let titlePage = choices.titlePage ? screenplayTitlePage(of: book, document: document, store: store) : nil
        switch choices.format {
        case .pdf:
            var author = ExportSettings()
            author.useAuthor(store.margin.info(for: book.url))
            let made = ScreenplayPDF.make(document, titlePage: titlePage, paper: choices.paper, sceneNumbers: choices.sceneNumbers,
                                          title: book.title, author: author.byline)
            try made.data.write(to: url, options: .atomic)
        case .finalDraft:
            try FinalDraft.fdx(document, titlePage: titlePage, sceneNumbers: choices.sceneNumbers)
                .write(to: url, atomically: true, encoding: .utf8)
        case .fountain:
            // The file itself; a title page put at its head if it has none of its own.
            var out = text
            if let titlePage, document.titlePage.isEmpty {
                out = Fountain.titlePageText(titlePage.fountainKeys) + "\n" + text
            }
            try out.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
