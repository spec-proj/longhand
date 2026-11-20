import SwiftUI

/// The stories this one is linked to, and the ones linked to it, on a story's page (issue
/// #14): a novel's planning notebook, a poem's notes. A link is made from one story, and both
/// show it. Shown in the Library only, where the page is about the story as a whole.
struct LinkedStories: View {
    @EnvironmentObject private var store: LibraryStore
    let book: Book
    let editing: Bool
    @ObservedObject var margin: MarginStore

    var body: some View {
        let outgoing = store.links(from: book)
        let incoming = store.links(to: book).filter { other in !outgoing.contains { $0.url == other.url } }
        if editing || !outgoing.isEmpty || !incoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Linked").font(.headline).foregroundStyle(Color(PaperTheme.ink))
                    Spacer()
                    if editing { linkMenu(excluding: outgoing) }
                }
                VStack(spacing: 2) {
                    ForEach(outgoing) { other in
                        LinkedRow(book: other, outgoing: true,
                                  unlink: editing ? { margin.unlink(book.url, from: other.title) } : nil)
                    }
                    ForEach(incoming) { other in
                        LinkedRow(book: other, outgoing: false, unlink: nil)
                    }
                }
                .padding(.horizontal, -8)
            }
        }
    }

    /// Every other story that isn't linked yet.
    private func linkMenu(excluding linked: [Book]) -> some View {
        let candidates = (store.library?.books ?? []).filter { other in
            other.url != book.url && !linked.contains { $0.url == other.url }
        }
        return Menu("Link a Story") {
            ForEach(candidates) { other in
                Button(other.title) { margin.link(book.url, to: other.title) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(FramedButtonStyle())
        .fontWeight(.medium)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(candidates.isEmpty)
        .help("Link this story to another: its planning notes, say")
    }
}

/// One linked story: its cover, its name and what it is. Click to see its page.
private struct LinkedRow: View {
    @EnvironmentObject private var store: LibraryStore
    let book: Book
    /// True when this story links to the other; false when the other links here.
    let outgoing: Bool
    let unlink: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let info = store.margin.info(for: book.url)
        Button { store.selection = .book(book.url) } label: {
            HStack(spacing: 10) {
                BookCover(title: book.title, image: store.margin.cover(of: book.url), width: 22,
                          form: info.form, collection: info.collection)
                Text(book.title)
                    .font(.system(size: Layout.blurbSize, design: .serif))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1)
                if let form = info.form {
                    Text(form.title(collection: info.collection))
                        .font(.system(size: Layout.detailSize, weight: .medium))
                        .foregroundStyle(Color(PaperTheme.secondary))
                }
                Spacer(minLength: 8)
                if let unlink {
                    Button(action: unlink) { Symbol.close.view(size: 10, weight: .semibold) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .help("Remove the link")
                } else {
                    (outgoing ? Symbol.linkedTo : Symbol.linkedFrom).view(size: 11, weight: .medium)
                        .foregroundStyle(Color(PaperTheme.secondary))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(hovering ? Color(PaperTheme.hover) : .clear, in: rounded())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(outgoing ? "Open \(book.title)" : "\(book.title) links to this story")
    }
}
