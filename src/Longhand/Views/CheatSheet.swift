import SwiftUI

/// Help › Cheat Sheet: a reference card in the middle of the window — three columns of
/// shortcuts, with Markdown (or a screenplay's own marks) below. It doesn't take the
/// keyboard, so you can keep writing with it open; ⌘/ again, Escape, its close button or a
/// click outside puts it away.
struct CheatSheet: View {
    @EnvironmentObject private var store: LibraryStore

    private struct Shortcut: Identifiable {
        var id: String { label }
        let label: String
        let keys: [Key]
    }

    /// What you type, and what it makes.
    private struct Mark: Identifiable {
        var id: String { typed }
        let typed: String
        let made: Text
    }

    private static let move: [Shortcut] = [
        Shortcut(label: "Command palette", keys: [.symbol("command"), .letter("K")]),
        Shortcut(label: "Library", keys: [.symbol("command"), .letter("4")]),
        Shortcut(label: "Switch scene", keys: [.symbol("command"), .letter("L")]),
        Shortcut(label: "Switch document", keys: [.symbol("shift"), .symbol("command"), .letter("L")]),
        Shortcut(label: "Next or previous scene", keys: [.symbol("control"), .symbol("command"), .symbol("arrow.up.arrow.down")]),
        Shortcut(label: "Next or previous chapter", keys: [.symbol("option"), .symbol("command"), .symbol("arrow.up.arrow.down")]),
        Shortcut(label: "Go to a pane", keys: [.symbol("option"), .symbol("command"), .letter("1"), .letter("2"), .letter("3")]),
        Shortcut(label: "Next pane, from a list", keys: [.symbol("arrow.right.to.line")]),
        Shortcut(label: "Open on the page", keys: [.symbol("command"), .symbol("arrow.down")]),
        Shortcut(label: "Find", keys: [.symbol("command"), .letter("F")]),
        Shortcut(label: "Find in library", keys: [.symbol("shift"), .symbol("command"), .letter("F")]),
        Shortcut(label: "Show library in Finder", keys: [.symbol("shift"), .symbol("command"), .letter("R")]),
        Shortcut(label: "Rename in the contents", keys: [.symbol("return")]),
        Shortcut(label: "Move to Trash", keys: [.symbol("command"), .symbol("delete.left")]),
        Shortcut(label: "Move to Boneyard", keys: [.symbol("shift"), .symbol("command"), .symbol("delete.left")]),
    ]

    private static let write: [Shortcut] = [
        Shortcut(label: "Bold", keys: [.symbol("command"), .letter("B")]),
        Shortcut(label: "Italic", keys: [.symbol("command"), .letter("I")]),
        Shortcut(label: "Comment", keys: [.symbol("command"), .letter("J")]),
        Shortcut(label: "New scene", keys: [.symbol("command"), .letter("N")]),
        Shortcut(label: "New chapter", keys: [.symbol("shift"), .symbol("command"), .letter("N")]),
        Shortcut(label: "Commit", keys: [.symbol("shift"), .symbol("command"), .letter("S")]),
        Shortcut(label: "Export", keys: [.symbol("command"), .letter("E")]),
    ]

    private static let view: [Shortcut] = [
        Shortcut(label: "Clear the desk", keys: [.symbol("command"), .letter(".")]),
        Shortcut(label: "Focus", keys: [.symbol("command"), .letter("D")]),
        Shortcut(label: "Typewriter scrolling", keys: [.symbol("shift"), .symbol("command"), .letter("T")]),
        Shortcut(label: "Cards", keys: [.symbol("command"), .letter("3")]),
        Shortcut(label: "Read or write", keys: [.symbol("command"), .letter("R")]),
        Shortcut(label: "Hide the contents", keys: [.symbol("command"), .letter("1")]),
        Shortcut(label: "Hide the margin", keys: [.symbol("command"), .letter("2")]),
        Shortcut(label: "Bigger text", keys: [.symbol("command"), .symbol("plus")]),
        Shortcut(label: "Smaller text", keys: [.symbol("command"), .symbol("minus")]),
        Shortcut(label: "Cheat sheet", keys: [.symbol("command"), .letter("/")]),
    ]

    /// The width of each column of shortcuts.
    private static let widths: (move: CGFloat, write: CGFloat, view: CGFloat) = (272, 202, 240)

    var body: some View {
        ZStack {
            Color.black.opacity(0.10)
                .contentShape(Rectangle())
                .onTapGesture { store.cheatSheetShown = false }
            card
                .padding(28)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cheat Sheet")
                    .font(.headline)
                    .foregroundStyle(Color(PaperTheme.ink))
                Spacer()
                SquareToolbarButton(icon: .close, tooltip: "Close", size: 24, iconSize: 11) {
                    store.cheatSheetShown = false
                }
                .frame(width: 24, height: 24)
            }
            .padding(.leading, 20)
            .padding(.trailing, 10)
            .frame(height: 44)
            Rectangle().fill(Color(PaperTheme.hairline)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // The shortcuts, in three columns.
                    HStack(alignment: .top, spacing: 18) {
                        section("Move around", width: Self.widths.move) { shortcuts(Self.move) }
                        section("Write", width: Self.widths.write) { shortcuts(Self.write) }
                        section("View", width: Self.widths.view) { shortcuts(Self.view) }
                    }
                    // What you type, and what it makes.
                    if screenplayOpen {
                        section("Screenplay", width: nil) { screenplay }
                    } else {
                        section("Markdown", width: nil) { markdown }
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 620)
        }
        .frame(width: 812)
        .background(Color(PaperTheme.chrome), in: rounded(Layout.panelRadius))
        .roundedFrame(Color(PaperTheme.controlOnBorder), radius: Layout.panelRadius)
    }

    /// A framed group with its title above, like a Mac group box.
    private func section<Content: View>(_ title: String, width: CGFloat?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(PaperTheme.secondary))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.vertical, 6)
                .frame(width: width, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(PaperTheme.card), in: rounded(Layout.radius))
                .roundedFrame(Color(PaperTheme.cardBorder), radius: Layout.radius)
        }
    }

    private func shortcuts(_ items: [Shortcut]) -> some View {
        ForEach(items) { item in
            HStack(spacing: 10) {
                Text(item.label)
                    .font(.system(size: Layout.chromeSize))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 3) { ForEach(item.keys, id: \.self) { KeyCap(key: $0) } }
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
        }
    }

    private var screenplayOpen: Bool {
        if case .scene(let url) = store.selection { return url.pathExtension.lowercased() == ProseFile.fountain }
        return false
    }

    /// The keys that move between elements, then what to type for each (Fountain).
    private var screenplay: some View {
        let keys: [Shortcut] = [
            Shortcut(label: "Character, on an empty line", keys: [.symbol("arrow.right.to.line")]),
            Shortcut(label: "Parenthetical, in a speech", keys: [.symbol("arrow.right.to.line")]),
            Shortcut(label: "On to dialogue or action", keys: [.symbol("return")]),
        ]
        let rows: [(String, String)] = [
            ("INT. ROOM - DAY", "Scene heading"),
            ("MARA", "Character"),
            ("(beat)", "Parenthetical"),
            ("CUT TO:", "Transition"),
            ("> THE END <", "Centred"),
            ("[[note]]", "Note, not printed"),
        ]
        return Group {
            shortcuts(keys)
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 10) {
                    Text(row.0)
                        .font(.system(size: Layout.detailSize, design: .monospaced))
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .frame(width: 124, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: Layout.chromeSize))
                        .foregroundStyle(Color(PaperTheme.ink))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
            }
        }
    }

    /// What to type, and what it makes: four pairs to a line.
    private var markdown: some View {
        let size = Layout.chromeSize
        let ink = Color(PaperTheme.ink)
        let rows: [Mark] = [
            Mark(typed: "# Title", made: Text("Heading").font(.system(size: size + 2, weight: .semibold)).foregroundColor(ink)),
            Mark(typed: "**words**", made: Text("Bold").font(.system(size: size, weight: .bold)).foregroundColor(ink)),
            Mark(typed: "*words*", made: Text("Italic").font(.system(size: size).italic()).foregroundColor(ink)),
            Mark(typed: "> words", made: Text("A quotation").font(.system(size: size)).foregroundColor(Color(PaperTheme.quote))),
            Mark(typed: "- words", made: Text("•  A list").font(.system(size: size)).foregroundColor(ink)),
            Mark(typed: "1. words", made: Text("1.  A numbered list").font(.system(size: size)).foregroundColor(ink)),
            Mark(typed: "---", made: Text("*  *  *").font(.system(size: size)).foregroundColor(Color(PaperTheme.secondary))),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .topLeading), count: 3),
                         alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.typed)
                        .font(.system(size: Layout.detailSize, design: .monospaced))
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .frame(width: 78, alignment: .leading)
                    row.made
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
            }
        }
    }
}
