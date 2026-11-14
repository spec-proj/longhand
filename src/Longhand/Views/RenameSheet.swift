import SwiftUI

struct RenameSheet: View {
    let title: String
    let onRename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(title: String, onRename: @escaping (String) -> Void) {
        self.title = title
        self.onRename = onRename
        _text = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename")
                .font(.system(size: Layout.chromeSize, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.ink))

            // Takes the keyboard with the name selected, ready to type over.
            KeyField(text: $text, placeholder: "Name", onSubmit: commit, onCancel: { dismiss() })
                .fieldBox(focused: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SquareButtonStyle(primary: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(Color(PaperTheme.paper))
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}
