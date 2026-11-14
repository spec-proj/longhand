import SwiftUI

/// File › New Document (owner, 2026-11-14; mock-up https://claude.ai/artifact/6KQ8iA4KAemUHmExe2JTg8):
/// one cover beside a list of forms. The cover takes the colour of the form under the pointer,
/// or the one chosen, and carries the title as typed and the author. Below: Structure (for a
/// form that can be one piece or several, Collection first), Name and Author.
struct NewDocumentSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authors = AuthorProfiles.shared

    @State private var form: BookForm
    @State private var hovered: BookForm?
    @State private var collection: Bool
    @State private var chapters: Bool
    @State private var scenes: Bool
    @State private var name = ""
    /// The author last chosen here: a profile's id, "" for None, nil before any choice (then
    /// the first profile).
    @AppStorage("newDocumentAuthor") private var authorID: String?

    static let forms: [BookForm] = [.novel, .novella, .shortStory, .poetry, .lyrics, .essay, .screenplay, .notebook]
    static let coverWidth: CGFloat = 168

    init(form: BookForm = .novel) {
        let collection = form.collectionByDefault
        let shape = Self.suggestedShape(for: form, collection: collection)
        _form = State(initialValue: form)
        _collection = State(initialValue: collection)
        _chapters = State(initialValue: shape.hasChapters)
        _scenes = State(initialValue: shape.hasScenes)
    }

    /// The division each form starts with: a novel has chapters and scenes; a collection of
    /// stories or essays has one chapter per piece; of poems or songs, one file per piece; a
    /// single piece is one document.
    static func suggestedShape(for form: BookForm, collection: Bool) -> BookShape {
        switch form {
        case .novel, .novella: return .chaptersAndScenes
        case .shortStory, .essay: return collection ? .chapters : .document
        case .poetry, .lyrics: return collection ? .scenes : .document
        case .screenplay, .notebook: return .document
        }
    }

    /// A new story's name until one is typed.
    static func untitled(_ form: BookForm?, collection: Bool?) -> String {
        guard let form else { return "Untitled Story" }
        let collected = form.collects && (collection ?? form.collectionByDefault)
        switch form {
        case .shortStory where collected: return "Untitled Stories"
        case .essay where collected: return "Untitled Essays"
        case .poetry: return collected ? "Untitled Collection" : "Untitled Poem"
        case .lyrics: return collected ? "Untitled Songs" : "Untitled Song"
        default: return "Untitled \(form.title)"
        }
    }

    /// One piece that is always one file: a screenplay, a single poem or song.
    private var oneDocument: String? {
        switch form {
        case .screenplay: return "Screenplay Document"
        case .poetry where !collection: return "Poem Document"
        case .lyrics where !collection: return "Song Document"
        default: return nil
        }
    }

    private var author: AuthorProfile? {
        authorID == nil ? authors.all.first : authors.profile(authorID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Document")
                .font(.system(size: Layout.chromeSize, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.ink))

            HStack(alignment: .top, spacing: 28) {
                let shown = hovered ?? form
                BookPlaceholder(
                    title: name.trimmingCharacters(in: .whitespaces).isEmpty
                        ? Self.untitled(shown, collection: shown == form ? collection : nil) : name,
                    width: Self.coverWidth, form: shown, byline: author?.byline ?? "",
                    collection: shown == form ? collection : nil)
                    .shadow(color: Color(PaperTheme.ink).opacity(0.18), radius: 8, y: 4)
                    .animation(.easeOut(duration: 0.12), value: shown)
                    .frame(width: 220, height: 300)
                    .background(rounded(Layout.panelRadius).fill(Color(PaperTheme.chrome)))

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.forms) { item in
                        FormRow(form: item, chosen: item == form, hovered: item == hovered) { choose(item) }
                            .onHover { inside in
                                if inside { hovered = item } else if hovered == item { hovered = nil }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

            SheetRow(label: "Structure") {
                HStack(spacing: 18) {
                    if form.collects {
                        Toggle("Collection", isOn: Binding(get: { collection }, set: { setCollection($0) }))
                        Rectangle().fill(Color(PaperTheme.hairline)).frame(width: 1, height: 16)
                    }
                    if let oneDocument {
                        Text(oneDocument)
                            .foregroundStyle(Color(PaperTheme.secondary))
                            .help(form == .screenplay ? "A screenplay is one document. Its scenes come from the scene headings you type." : "")
                    } else {
                        let names = PartNames.of(form, collection: collection)
                        Toggle(names.chapters, isOn: $chapters)
                        Toggle(names.scenes, isOn: $scenes)
                    }
                }
                .toggleStyle(.checkbox)
                .font(.system(size: Layout.chromeSize))
            }

            SheetRow(label: "Name") {
                KeyField(text: $name, placeholder: Self.untitled(form, collection: collection), onSubmit: create,
                         onMove: { step in move(by: step) }, onCancel: { dismiss() })
                    .fieldBox(focused: true)
            }

            SheetRow(label: "Author") {
                AuthorMenu(chosen: author, all: authors.all) { profile in
                    authorID = profile?.id ?? ""
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SquareButtonStyle(primary: true))
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(Color(PaperTheme.paper))
    }

    private func choose(_ item: BookForm) {
        form = item
        setCollection(item.collectionByDefault)
    }

    private func setCollection(_ value: Bool) {
        collection = value
        let shape = Self.suggestedShape(for: form, collection: value)
        chapters = shape.hasChapters
        scenes = shape.hasScenes
    }

    /// ↑ and ↓ in the Name field go through the forms.
    private func move(by step: Int) {
        guard let index = Self.forms.firstIndex(of: form) else { return }
        choose(Self.forms[max(0, min(Self.forms.count - 1, index + step))])
    }

    private func create() {
        let shape = oneDocument != nil ? .document : BookShape(chapters: chapters, scenes: scenes)
        store.createBook(title: name, form: form, shape: shape,
                         collection: form.collects ? collection : nil, author: author)
        dismiss()
    }
}

/// A form in the list: a small book in its colour, then its name. The chosen one sits on the
/// selection band; the one under the pointer on a lighter one.
private struct FormRow: View {
    let form: BookForm
    let chosen: Bool
    let hovered: Bool
    let action: () -> Void

    var body: some View {
        let colours = CoverColours.of(form)
        Button(action: action) {
            HStack(spacing: 10) {
                rounded(2).fill(Color(colours.fill))
                    .overlay(rounded(2).strokeBorder(Color(colours.edge), lineWidth: 1))
                    .frame(width: 10, height: 15)
                Text(form.title)
                    .font(.system(size: Layout.chromeSize, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(Color(PaperTheme.ink))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(rounded(Layout.radius).fill(chosen ? Color(PaperTheme.selection) : hovered ? Color(PaperTheme.chrome) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The author, chosen from Settings › Authors; None; New Author… opens Settings there.
private struct AuthorMenu: View {
    let chosen: AuthorProfile?
    let all: [AuthorProfile]
    let choose: (AuthorProfile?) -> Void

    var body: some View {
        Menu {
            ForEach(all) { profile in
                Toggle(profile.title, isOn: Binding(get: { profile.id == chosen?.id }, set: { if $0 { choose(profile) } }))
            }
            Toggle("None", isOn: Binding(get: { chosen == nil }, set: { if $0 { choose(nil) } }))
            Divider()
            Button("New Author…") { SettingsView.open(pane: "authors") }
        } label: {
            HStack(spacing: 6) {
                Text(chosen?.title ?? "None")
                    .foregroundStyle(Color(chosen == nil ? PaperTheme.secondary : PaperTheme.ink))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(PaperTheme.secondary))
            }
            .font(.system(size: Layout.chromeSize))
            .padding(.horizontal, 8)
            .frame(width: 220, height: 26)
            .background(Color(PaperTheme.paper), in: rounded())
            .overlay(rounded().strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}
