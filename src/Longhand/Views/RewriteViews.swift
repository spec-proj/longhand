import SwiftUI
import AppKit

// MARK: - Start a Rewrite

/// File › Start a Rewrite…: a name, then the writer is on the rewrite.
struct StartRewriteSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Branch")
                .font(.headline)
                .foregroundStyle(Color(PaperTheme.ink))
                .padding(.bottom, 18)
            HStack(spacing: 16) {
                Text("Name")
                    .font(.system(size: Layout.chromeSize))
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .frame(width: Layout.sheetLabel, alignment: .leading)
                TextField("First person", text: $name, prompt: .placeholder("First person"))
                    .textFieldStyle(.plain)
                    .font(.system(size: Layout.chromeSize))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color(PaperTheme.card))
                    .roundedFrame(Color(PaperTheme.cardBorder), lineWidth: 1)
            }
            .help("A separate line of work for trying a big change. main stays as it is until you merge.")
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SquareButtonStyle())
                Button("Create Branch") {
                    store.startRewrite(title: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SquareButtonStyle(primary: true))
            }
            .padding(.top, 22)
        }
    }
}

// MARK: - Keeping: choosing between passages

/// In place of the page while keeping a rewrite whose changes meet the manuscript's: each
/// passage changed in both, the two versions side by side in turn, and a choice for each.
struct MergeView: View {
    @EnvironmentObject private var versions: VersionStore
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        if let plan = versions.mergePlan {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Merging \(Text("“\(plan.rewrite.title)”").fontWeight(.semibold)): \(count(plan)) changed on both sides")
                        .foregroundStyle(Color(PaperTheme.ink))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Button("Cancel") { versions.mergePlan = nil }
                        .buttonStyle(SquareButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Merge") { store.finishKeep(plan) }
                        .buttonStyle(SquareButtonStyle(primary: true))
                        .help("Merge the branch into main with these choices")
                }
                .font(.system(size: Layout.chromeSize))
                .padding(.horizontal, 24)
                .frame(height: 44)
                .background(Color(PaperTheme.selection))
                Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(plan.scenes) { scene in
                            Text(scene.title)
                                .font(.system(size: Layout.chromeSize, weight: .semibold))
                                .foregroundStyle(Color(PaperTheme.ink))
                                .padding(.top, 36)
                                .padding(.bottom, 14)
                            if let pieces = scene.pieces {
                                ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                                    if case .passage(let id) = piece {
                                        PassageChoice(passageID: id, before: context(pieces, before: index))
                                    }
                                }
                            } else {
                                WholeSceneChoice(scene: scene)
                            }
                        }
                    }
                    .frame(maxWidth: Layout.column, alignment: .leading)
                    .padding(.horizontal, Layout.gutter)
                    .padding(.bottom, 56)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color(PaperTheme.paper))
        }
    }

    private func count(_ plan: MergePlan) -> String {
        let n = plan.passages.count + plan.scenes.filter { $0.pieces == nil }.count
        return n == 1 ? "1 passage" : "\(n) passages"
    }

    /// The last paragraph before a passage, to show where it is.
    private func context(_ pieces: [MergePlan.Piece], before index: Int) -> String? {
        guard index > 0, case .text(let text) = pieces[index - 1] else { return nil }
        let last = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !last.isEmpty else { return nil }
        return last.count > 220 ? "…" + last.suffix(220) : last
    }
}

private struct PassageChoice: View {
    @EnvironmentObject private var versions: VersionStore
    let passageID: Int
    let before: String?

    private var passage: MergePlan.Passage? { versions.mergePlan?.passages.first { $0.id == passageID } }

    var body: some View {
        if let passage {
            VStack(alignment: .leading, spacing: 10) {
                if let before {
                    Text(before)
                        .font(Font(EditorFont.serif(Layout.textSize)))
                        .foregroundStyle(Color(PaperTheme.tertiary))
                        .lineLimit(3)
                }
                let marked = Self.marked(passage)
                Version(label: "main", text: passage.manuscript, marked: marked.manuscript,
                        chosen: passage.choice != .rewrite)
                Version(label: "This branch", text: passage.rewrite, marked: marked.rewrite,
                        chosen: passage.choice != .manuscript)
                SquareSegments(options: [MergePlan.Passage.Choice.manuscript, .rewrite, .both],
                               title: \.title, selection: binding)
                    .help("Which version to keep. Both keeps main’s, then the branch’s.")
            }
            .padding(.bottom, 28)
        }
    }

    /// Each side with the words the other doesn't have marked, as in the comparison.
    static func marked(_ passage: MergePlan.Passage) -> (manuscript: AttributedString, rewrite: AttributedString) {
        var manuscript = AttributedString(), rewrite = AttributedString()
        for segment in WordDiff.segments(from: passage.manuscript.trimmingCharacters(in: .newlines),
                                         to: passage.rewrite.trimmingCharacters(in: .newlines)) {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                manuscript += piece
                rewrite += piece
            case .removed:
                if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    piece.backgroundColor = Color(PaperTheme.diffRemovedWord)
                }
                manuscript += piece
            case .added:
                if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    piece.backgroundColor = Color(PaperTheme.diffAddedWord)
                }
                rewrite += piece
            }
        }
        return (manuscript, rewrite)
    }

    private var binding: Binding<MergePlan.Passage.Choice> {
        Binding(
            get: { passage?.choice ?? .rewrite },
            set: { choice in
                guard let index = versions.mergePlan?.passages.firstIndex(where: { $0.id == passageID }) else { return }
                versions.mergePlan?.passages[index].choice = choice
            }
        )
    }
}

private struct WholeSceneChoice: View {
    @EnvironmentObject private var versions: VersionStore
    let scene: MergePlan.Scene

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Version(label: "main", text: scene.wholeManuscript ?? "Removed in main.",
                    chosen: !(versions.mergePlan?.wholeChoices[scene.path] ?? true), removed: scene.wholeManuscript == nil)
            Version(label: "This branch", text: scene.wholeRewrite ?? "Removed in this branch.",
                    chosen: versions.mergePlan?.wholeChoices[scene.path] ?? true, removed: scene.wholeRewrite == nil)
            SquareSegments(options: [false, true], title: \.wholeTitle, selection: Binding(
                get: { versions.mergePlan?.wholeChoices[scene.path] ?? true },
                set: { versions.mergePlan?.wholeChoices[scene.path] = $0 }
            ))
        }
        .padding(.bottom, 28)
    }
}

/// One side of a choice: a card with its label and text; the chosen side in ink, framed.
private struct Version: View {
    let label: String
    let text: String
    var marked: AttributedString?
    let chosen: Bool
    var removed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: Layout.detailSize, weight: .medium))
                .foregroundStyle(Color(PaperTheme.secondary))
            Text(marked ?? AttributedString(text.trimmingCharacters(in: .newlines)))
                .font(removed ? .system(size: Layout.chromeSize) : Font(EditorFont.serif(Layout.textSize)))
                .foregroundStyle(Color(chosen && !removed ? PaperTheme.ink : PaperTheme.secondary))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(chosen ? PaperTheme.card : PaperTheme.paper))
        .roundedFrame(Color(chosen ? PaperTheme.ink : PaperTheme.cardBorder), lineWidth: chosen ? 1.5 : 1)
    }
}

extension MergePlan.Passage.Choice {
    var title: String {
        switch self {
        case .manuscript: return "main"
        case .rewrite: return "Branch"
        case .both: return "Both"
        }
    }
}

private extension Bool {
    var wholeTitle: String { self ? "Branch" : "main" }
}
