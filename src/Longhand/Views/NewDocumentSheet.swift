import SwiftUI

/// File › New Document (owner, 2026-11-14; mock-up https://claude.ai/artifact/J55jg6eGfJEucMZmgZSJTp):
/// five blank covers in a row, one per form, then two checkboxes for how the story is divided.
/// Choosing a cover suggests a division (a novel has chapters and scenes, a short story is one
/// document); either box can change it.
struct NewDocumentSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var form: BookForm = .novel
    @State private var chapters = true
    @State private var scenes = true
    @State private var name = ""

    static let forms: [BookForm] = [.novel, .novella, .shortStory, .essay, .notebook]

    /// The division each form starts with.
    static func suggestedShape(for form: BookForm) -> BookShape {
        switch form {
        case .novel, .novella: return .chaptersAndScenes
        case .shortStory, .essay, .notebook: return .document
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Document")
                .font(.system(size: Layout.chromeSize, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.ink))

            HStack(spacing: 14) {
                ForEach(Self.forms) { item in
                    FormCover(title: item.title, chosen: item == form) { choose(item) }
                }
            }

            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

            SheetRow(label: "Split into") {
                HStack(spacing: 18) {
                    Toggle(PartNames.of(form).chapters, isOn: $chapters)
                    Toggle(PartNames.of(form).scenes, isOn: $scenes)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: Layout.chromeSize))
            }

            SheetRow(label: "Name") {
                KeyField(text: $name, placeholder: "Untitled \(form.title)", onSubmit: create, onCancel: { dismiss() })
                    .fieldBox(focused: true)
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
        let shape = Self.suggestedShape(for: item)
        chapters = shape.hasChapters
        scenes = shape.hasScenes
    }

    private func create() {
        store.createBook(title: name, form: form, shape: BookShape(chapters: chapters, scenes: scenes))
        dismiss()
    }
}

/// A blank book in the cover's shape (1:1.6) with the form's name on it, like a title page.
private struct FormCover: View {
    let title: String
    let chosen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                rounded(Layout.radius).fill(Color(PaperTheme.card))
                HStack(spacing: 0) {
                    Rectangle().fill(Color(PaperTheme.hairline)).frame(width: 7)
                    Spacer(minLength: 0)
                }
                Text(title)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .multilineTextAlignment(.center)
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
            }
            .frame(width: 98, height: 157)
            .clipShape(rounded(Layout.radius))
            .overlay(rounded(Layout.radius).strokeBorder(Color(chosen ? PaperTheme.ink : PaperTheme.frame), lineWidth: chosen ? 2 : 1))
            .padding(5)
            .background(rounded(Layout.radius + 2).fill(Color(chosen ? PaperTheme.selection : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
