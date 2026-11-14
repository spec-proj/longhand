import SwiftUI
import AppKit

/// The margin's Versions tab. Versions belong to scenes (`SceneVersions`), so what it shows
/// follows what is selected:
///
/// - **A scene:** its changes since its last version (click to see them in the page), a note
///   and Save as v4; then its history as a timeline, versions as filled marks and automatic
///   copies (autosaves, copies on quit) as hollow ones. Click one to see the scene compared
///   with it in the page.
/// - **A chapter or a book:** the scenes inside changed since their last versions, each with
///   a coloured letter (M edited, N new, D deleted) and its words, and Save Versions.
struct ChangesPane: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var margin: MarginStore
    @EnvironmentObject private var versions: VersionStore
    @ObservedObject var changes: ChangeState

    @State private var note = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch store.selection {
                    case .scene(let url):
                        if let bar = margin.changeFocus {
                            FocusedChange(bar: bar)
                            rule
                        }
                        SceneSection(scene: url, changes: changes, note: $note, saving: $saving)
                    case .chapter(let url), .book(let url):
                        changeList(changes.changes(inside: url), groupByChapter: isBook)
                    case nil:
                        changeList(changes.scenes, groupByChapter: true)
                    }
                }
            }
            footer
        }
    }

    private var isBook: Bool {
        if case .book = store.selection { return true }
        return false
    }

    private var rule: some View {
        Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
    }

    // MARK: A chapter or a book

    @ViewBuilder
    private func changeList(_ list: [Comparison.SceneChange], groupByChapter: Bool) -> some View {
        let shown = list.filter { !$0.onlyMoved }
        HStack(spacing: 8) {
            Text("Changed scenes")
                .font(.system(size: Layout.detailSize, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.secondary))
            Spacer(minLength: 4)
            DiffNumbers(added: shown.reduce(0) { $0 + $1.wordsAdded }, removed: shown.reduce(0) { $0 + $1.wordsRemoved })
        }
        .padding(.horizontal, Layout.pad)
        .padding(.top, Layout.pad)
        .padding(.bottom, 6)
        if shown.isEmpty {
            Text("No changes")
                .font(.system(size: Layout.chromeSize))
                .foregroundStyle(Color(PaperTheme.secondary))
                .padding(.horizontal, Layout.pad)
                .padding(.vertical, 6)
        } else {
            let groups = Dictionary(grouping: shown) { chapterOf($0.path) }
            let order = shown.map { chapterOf($0.path) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            ForEach(order, id: \.self) { chapter in
                if groupByChapter {
                    Text(FileNaming.decode(chapter).title)
                        .font(.system(size: Layout.detailSize, weight: .medium))
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .padding(.horizontal, Layout.pad)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                }
                ForEach(groups[chapter] ?? []) { change in
                    SceneChangeRow(change: change, open: isShowing(change)) { show(change) }
                }
            }
            HStack(spacing: 6) {
                NoteField(note: $note, submit: { saveAll(shown) })
                Button(shown.count == 1 ? "Commit" : "Commit \(shown.count) Scenes") { saveAll(shown) }
                    .buttonStyle(PlainSquareButtonStyle(height: 24, horizontalPadding: 8, isOn: true))
                    .disabled(saving)
                    .help("Commit every changed scene with this summary")
            }
            .padding(Layout.pad)
        }
    }

    private func chapterOf(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : ""
    }

    private func isShowing(_ change: Comparison.SceneChange) -> Bool {
        versions.comparing && versions.detail?.path == change.path
    }

    private func show(_ change: Comparison.SceneChange) {
        guard let root = store.libraryURL else { return }
        if change.status == .added {
            store.selection = .scene(root.appendingPathComponent(change.path).canonical)
            return
        }
        let url = root.appendingPathComponent(change.path).canonical
        if let last = (changes.histories[change.path] ?? changes.history(of: url)).first(where: { $0.kind == .version }) {
            versions.openScene(change.path, from: last.commit, label: last.shortID)
        }
    }

    private func saveAll(_ list: [Comparison.SceneChange]) {
        let paths = list.filter { $0.status != .removed }.map(\.path)
        guard !paths.isEmpty, !saving else { return }
        saving = true
        store.saveNow()
        versions.saveVersions(of: paths, note: note) { saved in
            saving = false
            if saved { note = "" }
        }
    }

    // MARK: Foot

    private var footer: some View {
        VStack(spacing: 0) {
            rule
            VStack(spacing: 8) {
                if let rewrite = changes.branch {
                    HStack(spacing: 6) {
                        Text("Branch")
                            .foregroundStyle(Color(PaperTheme.secondary))
                        Text(rewrite)
                            .fontWeight(.medium)
                            .foregroundStyle(Color(PaperTheme.ink))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Button("Merge…") { store.versions.confirm = .keep }
                            .buttonStyle(PlainSquareButtonStyle(height: 24, horizontalPadding: 6))
                            .help("Merge this branch into main")
                    }
                    .font(.system(size: Layout.chromeSize))
                }
                backupLine
            }
            .padding(.horizontal, Layout.pad)
            // One row: the same foot as the contents' and Comments'. Two with a branch.
            .padding(.vertical, changes.branch == nil ? 0 : 8)
            .frame(minHeight: Layout.barHeight)
        }
    }

    @ViewBuilder
    private var backupLine: some View {
        HStack(spacing: 6) {
            switch changes.backup {
            case .none:
                Text("Only on this Mac")
                    .foregroundStyle(Color(PaperTheme.secondary))
                Spacer(minLength: 4)
                Button("Connect Repository…") { store.versions.sheet = .backup }
                    .buttonStyle(PlainSquareButtonStyle(height: 22, horizontalPadding: 6))
            case .done:
                Text("Pushed to \(store.versions.sync.place)")
                    .foregroundStyle(Color(PaperTheme.secondary))
                Spacer(minLength: 4)
            case .behind:
                Text("Commits to push")
                    .foregroundStyle(Color(PaperTheme.accent))
                Spacer(minLength: 4)
                Button("Push") { store.versions.pushNow() }
                    .buttonStyle(PlainSquareButtonStyle(height: 22, horizontalPadding: 6))
            }
        }
        .font(.system(size: Layout.chromeSize))
        .frame(height: 22)
    }

}

/// "+120 −40" in the diff colours; grey at zero.
struct DiffNumbers: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(added.formatted())")
                .foregroundStyle(Color(added > 0 ? PaperTheme.diffAddedMark : PaperTheme.tertiary))
            Text("−\(removed.formatted())")
                .foregroundStyle(Color(removed > 0 ? PaperTheme.diffRemovedMark : PaperTheme.tertiary))
        }
        .font(.system(size: Layout.smallSize, weight: .semibold).monospacedDigit())
        .boxed(padding: 6)
    }
}

/// The note for a version: an inset field.
private struct NoteField: View {
    @Binding var note: String
    let submit: () -> Void

    var body: some View {
        TextField("Summary", text: $note, prompt: .placeholder("Summary"))
            .textFieldStyle(.plain)
            .font(.system(size: Layout.chromeSize))
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(Color(PaperTheme.card), in: rounded())
            .roundedFrame(Color(PaperTheme.controlBorder))
            .onSubmit(submit)
    }
}

// MARK: - A scene

/// One scene: its changes since its last version, Save as v4, and its history.
private struct SceneSection: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var versions: VersionStore
    let scene: URL
    @ObservedObject var changes: ChangeState
    @Binding var note: String
    @Binding var saving: Bool
    @State private var autosaves: [HistoryStore.Version] = []

    var body: some View {
        let change = changes.change(of: scene)
        let last = changes.lastVersion(of: scene)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                versions.showSceneChanges(scene)
            } label: {
                HStack(spacing: 8) {
                    Text(last == nil ? "No commit yet" : "Since")
                        .font(.system(size: Layout.chromeSize, weight: .semibold))
                        .foregroundStyle(Color(PaperTheme.ink))
                    if let last { Badge(last.shortID) }
                    Spacer(minLength: 4)
                    DiffNumbers(added: change?.wordsAdded ?? 0, removed: change?.wordsRemoved ?? 0)
                }
                .padding(.horizontal, Layout.pad)
                .frame(height: 34)
                .rowBackground(comparingLast(last) ? Color(PaperTheme.selection) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(change == nil || last == nil)
            .help(change == nil ? "" : "Show the changes in the page")

            HStack(spacing: 6) {
                NoteField(note: $note, submit: save)
                Button("Commit", action: save)
                    .buttonStyle(PlainSquareButtonStyle(height: 24, horizontalPadding: 8, isOn: true))
                    .disabled(saving || change == nil)
            }
            .padding(.horizontal, Layout.pad)
            .padding(.bottom, Layout.pad)

            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
            Text("History")
                .font(.system(size: Layout.detailSize, weight: .semibold))
                .foregroundStyle(Color(PaperTheme.secondary))
                .padding(.horizontal, Layout.pad)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Timeline(items: items, selected: selectedID) { item in open(item) }
                .padding(.bottom, Layout.pad)
        }
        .onAppear(perform: loadAutosaves)
        .onChange(of: scene) { loadAutosaves() }
        .onChange(of: store.wordCounts[scene]) { loadAutosaves() }
    }

    private func loadAutosaves() { autosaves = store.history.versions(of: scene) }

    private func comparingLast(_ last: SceneHistoryEntry?) -> Bool {
        guard let last else { return false }
        return versions.comparing && versions.compareFrom == last.commit && versions.detail != nil
    }

    /// The scene's versions, automatic copies and autosaves, newest first.
    private var items: [Timeline.Item] {
        var list: [Timeline.Item] = [.init(id: "now", date: .distantFuture, title: "Now", detail: nil, filled: true, kind: .now)]
        for entry in changes.history(of: scene) {
            if entry.kind == .version {
                let draft = entry.drafts.first.map { versions.draftTitles[$0] ?? $0 }
                list.append(.init(id: entry.commit, date: entry.date,
                                  title: [entry.shortID, draft].compactMap { $0 }.joined(separator: " · "),
                                  detail: entry.note.isEmpty ? nil : entry.note, filled: true, kind: .commit(entry)))
            } else {
                let title = SceneVersions.listedNote(entry.note)
                list.append(.init(id: entry.commit, date: entry.date, title: title, detail: nil, filled: false, kind: .commit(entry)))
            }
        }
        for copy in autosaves {
            list.append(.init(id: "autosave-\(copy.id)", date: copy.date, title: "Autosave", detail: nil, filled: false, kind: .autosave(copy)))
        }
        return list.sorted { $0.date > $1.date }
    }

    private var selectedID: String {
        if let preview = store.historyPreview { return "autosave-\(preview.id)" }
        if versions.comparing, versions.detail != nil, let from = versions.compareFrom { return from }
        return "now"
    }

    private func open(_ item: Timeline.Item) {
        switch item.kind {
        case .now:
            store.historyPreview = nil
            versions.comparing = false
        case .commit(let entry):
            store.historyPreview = nil
            guard let relative = changes.relative(scene) else { return }
            versions.openScene(relative, from: entry.commit,
                               label: entry.shortID)
        case .autosave(let copy):
            versions.comparing = false
            store.historyPreview = copy
        }
    }

    private func save() {
        guard !saving, changes.change(of: scene) != nil, let path = changes.relative(scene) else { return }
        saving = true
        store.saveNow()
        versions.saveVersions(of: [path], note: note) { saved in
            saving = false
            if saved { note = "" }
        }
    }
}

/// A scene's history drawn as a timeline, like a version-control graph: one vertical line,
/// a filled mark for each version and Now, a hollow one for each automatic copy.
private struct Timeline: View {
    struct Item: Identifiable {
        enum Kind { case now, commit(SceneHistoryEntry), autosave(HistoryStore.Version) }
        let id: String
        let date: Date
        let title: String
        let detail: String?
        let filled: Bool
        let kind: Kind
    }

    let items: [Item]
    let selected: String
    let open: (Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Row(item: item, first: index == 0, last: index == items.count - 1, selected: item.id == selected) { open(item) }
            }
        }
    }

    private struct Row: View {
        let item: Item
        let first: Bool
        let last: Bool
        let selected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack(alignment: .top) {
                        // The line runs through every mark, from the first to the last.
                        Rectangle()
                            .fill(Color(PaperTheme.frame))
                            .frame(width: 2)
                            .padding(.top, first ? 12 : 0)
                            .frame(maxHeight: last ? 12 : .infinity, alignment: .top)
                        mark.padding(.top, 7)
                    }
                    .frame(width: 12)
                    .frame(maxHeight: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: Layout.chromeSize, weight: item.filled ? .semibold : .regular))
                                .foregroundStyle(Color(item.filled ? PaperTheme.ink : PaperTheme.secondary))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if item.date != .distantFuture {
                                Text(VersionStore.when(item.date))
                                    .font(.system(size: Layout.detailSize).monospacedDigit())
                                    .foregroundStyle(Color(PaperTheme.secondary))
                                    .lineLimit(1)
                            }
                        }
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: Layout.detailSize))
                                .foregroundStyle(Color(PaperTheme.ink))
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .padding(.horizontal, Layout.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .rowBackground(selected ? Color(PaperTheme.selection) : hovering ? Color(PaperTheme.hover) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }

        @ViewBuilder
        private var mark: some View {
            if item.filled {
                Circle().fill(Color(item.date == .distantFuture ? PaperTheme.accent : PaperTheme.ink)).frame(width: 9, height: 9)
            } else {
                Circle().strokeBorder(Color(PaperTheme.tertiary), lineWidth: 1.5)
                    .background(Circle().fill(Color(PaperTheme.well)))
                    .frame(width: 9, height: 9)
            }
        }
    }
}

/// A changed scene in a chapter's or book's list: a coloured letter (M edited, N new, D
/// deleted), its name, and the words added and cut.
private struct SceneChangeRow: View {
    let change: Comparison.SceneChange
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(letter)
                    .font(.system(size: Layout.detailSize, weight: .bold).monospaced())
                    .foregroundStyle(Color(colour))
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: Layout.chromeSize, weight: open ? .semibold : .medium))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if change.status == .changed {
                    DiffNumbers(added: change.wordsAdded, removed: change.wordsRemoved)
                }
            }
            .padding(.horizontal, Layout.pad)
            .frame(height: 28)
            .rowBackground(open ? Color(PaperTheme.selection) : hovering ? Color(PaperTheme.hover) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var name: String { change.title.components(separatedBy: " › ").last ?? change.title }

    private var letter: String {
        switch change.status {
        case .added: return "N"
        case .removed: return "C"
        case .changed: return "E"
        }
    }

    private var colour: NSColor {
        switch change.status {
        case .added: return PaperTheme.diffAddedMark
        case .removed: return PaperTheme.diffRemovedMark
        case .changed: return PaperTheme.diffChangedMark
        }
    }

    private var help: String {
        switch change.status {
        case .added: return "New, not yet committed"
        case .removed: return "Cut since your last commit"
        case .changed: return "Edited since your last commit"
        }
    }
}

/// A passage chosen from its bar on the page: how it was at the last version, with Put Back.
private struct FocusedChange: View {
    @EnvironmentObject private var margin: MarginStore
    @EnvironmentObject private var versions: VersionStore
    let bar: ChangeBar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(heading)
                    .font(.system(size: Layout.detailSize, weight: .semibold))
                    .foregroundStyle(Color(PaperTheme.secondary))
                Spacer()
                SquareToolbarButton(icon: .close, tooltip: "Close", size: 22, iconSize: 12) {
                    margin.changeFocus = nil
                }
                .frame(width: 22, height: 22)
            }
            if !bar.oldText.isEmpty {
                Text(bar.oldText.trimmingCharacters(in: .newlines))
                    .font(.system(size: Layout.chromeSize))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(PaperTheme.diffRemovedRow))
            }
            HStack {
                Button(bar.kind == .added ? "Remove" : "Put Back") {
                    // Back to the editor first, if the page is showing a comparison.
                    if versions.comparing {
                        versions.comparing = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { margin.putBack(bar) }
                    } else {
                        margin.putBack(bar)
                    }
                }
                    .buttonStyle(PlainSquareButtonStyle(height: 24, horizontalPadding: 6, isOn: true))
                    .help(bar.kind == .added
                          ? "Take out what was added since your last commit (Undo brings it back)"
                          : "Put the passage back as it was at your last commit (Undo brings it back)")
                Spacer()
            }
        }
        .padding(.horizontal, Layout.pad)
        .padding(.vertical, 12)
        .background(Color(PaperTheme.commentFocus))
    }

    private var heading: String {
        switch bar.kind {
        case .added: return "Added since your last commit"
        case .changed: return "As it was"
        case .removed: return "Cut since your last commit"
        }
    }
}

