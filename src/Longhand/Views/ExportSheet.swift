import SwiftUI
import AppKit

/// File › Export…: format, paper and typeface, remembered with the library. The author on the
/// title page comes from the book's Book Info page.
struct ExportSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    @Environment(\.dismiss) private var dismiss
    let book: Book

    @State private var settings = ExportSettings()
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export \(book.title)")
                .font(.headline)
                .foregroundStyle(Color(PaperTheme.ink))
                .padding(.bottom, 18)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    label("Format")
                    SquareSegments(options: ExportKind.allCases, title: \.title, selection: kind)
                }
                GridRow {
                    label("File")
                    SquareSegments(
                        options: settings.format.isBook ? [.bookPDF, .epub] : [.manuscriptWord, .manuscriptPDF],
                        title: \.fileTitle,
                        selection: $settings.format
                    )
                }
                if settings.format.isBook {
                    if settings.format == .bookPDF {
                        GridRow {
                            label("Size")
                            SquareSegments(options: ExportSettings.Trim.allCases, title: \.title, selection: $settings.trim)
                        }
                    }
                    // (An e-book takes its page and type from the reader.) Without a cover
                    // picture a book would start blank: offer a lettered one.
                    if margin.cover(of: book.url) == nil {
                        GridRow(alignment: .top) {
                            label("Cover").padding(.top, 1)
                            letteredCovers
                        }
                    }
                } else {
                    GridRow {
                        label("Paper")
                        SquareSegments(options: ExportSettings.Paper.allCases, title: \.title, selection: $settings.paper)
                    }
                    GridRow {
                        label("Font")
                        SquareSegments(options: ExportSettings.Typeface.allCases, title: \.title, selection: $settings.typeface)
                    }
                }
            }

            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1).padding(.vertical, 20)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    label("Author")
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(authorLine)
                            .font(.system(size: Layout.chromeSize))
                            .foregroundStyle(Color(author.hasNoAuthor ? PaperTheme.secondary : PaperTheme.ink))
                            .lineLimit(2)
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
            }

            Text(note)
                .font(.system(size: Layout.detailSize, weight: .medium))
                .foregroundStyle(Color(PaperTheme.secondary))
                .lineSpacing(3)
                .padding(.leading, valueEdge)
                .padding(.top, 14)

            if let failure {
                Text(failure)
                    .font(.system(size: Layout.detailSize))
                    .foregroundStyle(Color(PaperTheme.accent))
                    .padding(.leading, valueEdge)
                    .padding(.top, 8)
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
        .frame(width: 560)
        .background(Color(PaperTheme.paper))
        .onAppear {
            store.adoptExportAuthor()
            settings = store.loadExportSettings()
        }
    }

    private var note: String {
        let words = store.wordCount(of: book)
        switch settings.format {
        case .manuscriptWord, .manuscriptPDF:
            let rounded = ManuscriptBook(title: book.title, words: words, chapters: []).roundedWords
            return "\(Estimate.words(words)); the title page says \(rounded)."
        case .bookPDF:
            if margin.cover(of: book.url) != nil { return "A \(settings.trim.title) book, set in New York, with its cover." }
            return settings.letteredCover.map { "A \(settings.trim.title) book, set in New York, with the \($0.title) cover." }
                ?? "A \(settings.trim.title) book, set in New York."
        case .epub:
            if margin.cover(of: book.url) != nil { return "For Apple Books, Kobo or Kindle, with its cover, synopsis and genre." }
            return settings.letteredCover == nil
                ? "For Apple Books, Kobo or Kindle, with a blank cover."
                : "For Apple Books, Kobo or Kindle, with the \(settings.letteredCover!.title) cover."
        }
    }

    /// The story has no cover picture: the four lettered covers to choose from (click the
    /// chosen one again for none), or a way to the story's page to add a picture.
    private var letteredCovers: some View {
        let text = Exporter.coverText(of: book, store: store)
        return VStack(alignment: .leading, spacing: 10) {
            Text("This story has no cover picture.")
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.ink))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                ForEach(LetteredCover.Style.allCases) { style in
                    let chosen = settings.letteredCover == style
                    Button {
                        settings.letteredCover = chosen ? nil : style
                    } label: {
                        VStack(spacing: 5) {
                            Image(nsImage: LetteredCover.preview(style, text, width: 52))
                                .overlay(Rectangle().strokeBorder(Color(PaperTheme.cardBorder), lineWidth: 1))
                                .padding(3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Layout.radius)
                                        .strokeBorder(Color(chosen ? PaperTheme.ink : .clear), lineWidth: 2)
                                )
                            Text(style.title)
                                .font(.system(size: Layout.detailSize, weight: chosen ? .semibold : .medium))
                                .foregroundStyle(Color(chosen ? PaperTheme.ink : PaperTheme.secondary))
                                .fixedSize()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(chosen ? "The \(style.title) cover goes on the book. Click again for none." : "Use the \(style.title) cover")
                }
            }
            Button("Add a Picture…") {
                dismiss()
                store.openBook = nil
                store.selection = .book(book.url)
            }
            .buttonStyle(SquareButtonStyle())
            .help("Add a cover picture on the story’s page")
        }
    }

    /// Where the grids' values start, so the note under them shares their edge.
    private var valueEdge: CGFloat { Layout.sheetLabel + 16 }

    /// Manuscript or Book; switching keeps the file type when it can (PDF stays PDF).
    private var kind: Binding<ExportKind> {
        Binding(
            get: { settings.format.isBook ? .book : .manuscript },
            set: { kind in
                switch (kind, settings.format) {
                case (.book, .manuscriptWord): settings.format = .epub
                case (.book, .manuscriptPDF): settings.format = .bookPDF
                case (.manuscript, .bookPDF): settings.format = .manuscriptPDF
                case (.manuscript, .epub): settings.format = .manuscriptWord
                default: break
                }
            }
        )
    }

    private var author: SceneInfo { margin.info(for: book.url) }

    /// "Jane Austen, as A Lady · Chawton Cottage", or a note that there is none yet.
    private var authorLine: String {
        var filled = settings
        filled.useAuthor(author)
        guard !author.hasNoAuthor else { return "No author chosen" }
        var parts = [filled.name]
        if !filled.penName.isEmpty, filled.penName != filled.name { parts[0] += ", as \(filled.penName)" }
        if let first = filled.contact.split(separator: "\n").first { parts.append(String(first)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(Color(PaperTheme.secondary))
            .frame(width: Layout.sheetLabel, alignment: .leading)
    }

    private func export() {
        store.saveExportSettings(settings)
        var settings = self.settings
        settings.useAuthor(author)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Exporter.suggestedName(book, settings)
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.export(book, store: store, settings: settings, to: url)
            dismiss()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            failure = "Couldn’t export: \(error.localizedDescription)"
        }
    }
}

/// The export sheet's first choice: a manuscript to submit or a book to read.
enum ExportKind: CaseIterable {
    case manuscript, book
    var title: String { self == .manuscript ? "Manuscript" : "Book" }
}

/// Square segments in a hairline frame, the selected one filled.
struct SquareSegments<Option: Hashable>: View {
    let options: [Option]
    let title: KeyPath<Option, String>
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                if index > 0 { Rectangle().fill(Color(PaperTheme.cardBorder)).frame(width: 1) }
                Button {
                    selection = option
                } label: {
                    Text(option[keyPath: title])
                        .font(.system(size: Layout.chromeSize, weight: option == selection ? .semibold : .medium))
                        .foregroundStyle(Color(option == selection ? PaperTheme.ink : PaperTheme.secondary))
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity)
                        .background(option == selection ? Color(PaperTheme.selection) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 26)
        .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
        .fixedSize()
    }
}
