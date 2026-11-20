import SwiftUI

/// The margin's Names tab (issue #24): the characters (or places) the open story tracks, each
/// with the names it goes by and how many places hold any of them. Click one to go to its
/// next place on the page; change a name and it changes everywhere. Select a name on the page
/// and press ⇧⌘J to track it, or type it here: commas make one character of several names.
struct NamesPane: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore

    @State private var counts: [String: (places: Int, scenes: Int)] = [:]
    /// The new-character field is open.
    @State private var adding = false
    /// The character (by main name) another name is being added to.
    @State private var addingTo: String?
    @State private var draft = ""
    @State private var renaming: String?
    /// Moves after each save, so the counts look again.
    @State private var tick = 0

    private var book: Book? { margin.bookURL.flatMap { store.book(for: $0) } }
    private var groups: [MarginStore.NameGroup] { book.map { margin.nameGroups(of: $0.url) } ?? [] }

    private struct Recount: Equatable { let groups: [MarginStore.NameGroup]; let tick: Int }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    NameRow(group: group, places: counts[group.main]?.places,
                            go: { go(to: group) },
                            add: { draft = ""; addingTo = group.main },
                            rename: { renaming = $0 },
                            remove: { if let book { margin.untrackName($0, in: book.url) } },
                            untrack: { if let book { margin.untrackGroup(group.main, in: book.url) } })
                    if addingTo == group.main {
                        field(placeholder: "Another name", commit: {
                            if let book { margin.addNames(draft, toGroupOf: group.main, in: book.url) }
                            addingTo = nil
                        }, cancel: { addingTo = nil })
                    }
                }
                addRow
            }
            .padding(Layout.pad)
            .padding(.horizontal, -8)
        }
        .scrollIndicators(.never)
        .onReceive(store.versions.changes.$generation) { _ in tick += 1 }
        .task(id: Recount(groups: groups, tick: tick)) {
            guard let book, !groups.isEmpty else { counts = [:]; return }
            counts = await store.occurrences(ofGroups: groups.map(\.names), in: book)
        }
        .sheet(item: Binding(get: { renaming.map(Renaming.init) }, set: { renaming = $0?.name })) { target in
            if let book {
                ChangeNameSheet(name: target.name, book: book)
            }
        }
    }

    private struct Renaming: Identifiable { let name: String; var id: String { name } }

    private func field(placeholder: String, commit: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        KeyField(text: $draft, placeholder: placeholder, onSubmit: commit, onCancel: cancel)
            .fieldBox(focused: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    @ViewBuilder private var addRow: some View {
        if adding {
            field(placeholder: "Name, or several with commas", commit: {
                if let book { margin.trackName(draft, in: book.url) }
                adding = false
            }, cancel: { adding = false })
        } else {
            Button { draft = ""; adding = true } label: {
                HStack(spacing: 8) {
                    Symbol.add.view(size: 12, weight: .semibold).frame(width: 13)
                    Text("Add a Name").fontWeight(.medium)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color(PaperTheme.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PlainSquareButtonStyle(height: 28))
            .help("Names you track show a dotted line when the pointer is over them on the page, and can be changed everywhere at once. Select one on the page and press ⇧⌘J to track it. Commas make one character of several names: Mara, Mara Voss, Ms. Voss.")
        }
    }

    /// The character's next place on the page after the caret (any of its names), wrapping round.
    private func go(to group: MarginStore.NameGroup) {
        guard let page = margin.textView else { return }
        let found = group.names.flatMap { NameMatch.ranges(of: $0, in: page.string) }.sorted { $0.location < $1.location }
        guard !found.isEmpty else { NSSound.beep(); return }
        let here = page.selectedRange().location
        let next = found.first { $0.location > here } ?? found[0]
        page.window?.makeFirstResponder(page)
        page.setSelectedRange(NSRange(location: next.location, length: 0))
        page.scrollRangeToVisible(next)
        page.showFindIndicator(for: next)
    }
}

/// One tracked character: its main name and, under it, the other names; its count; and on
/// hover adding a name, changing the main name, and stopping tracking.
private struct NameRow: View {
    let group: MarginStore.NameGroup
    let places: Int?
    let go: () -> Void
    let add: () -> Void
    let rename: (String) -> Void
    let remove: (String) -> Void
    let untrack: () -> Void
    @State private var hovering = false

    private var others: [String] { Array(group.names.dropFirst()) }

    var body: some View {
        Button(action: go) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.main)
                        .foregroundStyle(Color(PaperTheme.ink))
                        .lineLimit(1)
                    if !others.isEmpty {
                        Text(others.joined(separator: " · "))
                            .font(.system(size: Layout.detailSize))
                            .foregroundStyle(Color(PaperTheme.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if hovering {
                    Button(action: add) { Symbol.add.view(size: 11, weight: .semibold) }
                        .buttonStyle(.plain)
                        .help("Add another name for \(group.main)")
                    Button { rename(group.main) } label: { Symbol.rename.view(size: 11, weight: .medium) }
                        .buttonStyle(.plain)
                        .help("Change \(group.main) everywhere")
                    Button(action: untrack) { Symbol.close.view(size: 10, weight: .semibold) }
                        .buttonStyle(.plain)
                        .help("Stop tracking \(group.main)")
                } else if let places {
                    Badge("\(places)")
                }
            }
            .foregroundStyle(Color(PaperTheme.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PlainSquareButtonStyle(height: others.isEmpty ? 28 : 40))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Add Another Name…", action: add)
            Menu("Change Everywhere") {
                ForEach(group.names, id: \.self) { name in Button(name) { rename(name) } }
            }
            if !others.isEmpty {
                Menu("Remove a Name") {
                    ForEach(group.names, id: \.self) { name in Button(name) { remove(name) } }
                }
            }
            Divider()
            Button("Stop Tracking", action: untrack)
        }
        .help(places.map { "\($0) \($0 == 1 ? "place" : "places") in the story" } ?? "")
    }
}

/// Changes a tracked name to another, everywhere in the story. Says how many places that is
/// before it does it, and that the story is committed with the change (Restore undoes it).
struct ChangeNameSheet: View {
    let name: String
    let book: Book

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var found: (places: Int, scenes: Int)?

    init(name: String, book: Book) {
        self.name = name
        self.book = book
        _text = State(initialValue: name)
    }

    private var new: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changes: Bool { !new.isEmpty && new != name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change \(name) to")
                .font(.headline)
                .foregroundStyle(Color(PaperTheme.ink))
            KeyField(text: $text, placeholder: "Name", onSubmit: commit, onCancel: { dismiss() })
                .fieldBox(focused: true)
            if let found {
                Text("\(found.places) \(found.places == 1 ? "place" : "places") in \(found.scenes) \(found.scenes == 1 ? "scene" : "scenes"), and in notes, synopses and comments.")
                    .font(.system(size: Layout.detailSize))
                    .foregroundStyle(Color(PaperTheme.secondary))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Change") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SquareButtonStyle(primary: true))
                    .disabled(!changes)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(Color(PaperTheme.paper))
        .task { found = await store.occurrences(of: [name], in: book)[name] }
    }

    private func commit() {
        guard changes else { return }
        store.renameName(name, to: new, in: book)
        dismiss()
    }
}
