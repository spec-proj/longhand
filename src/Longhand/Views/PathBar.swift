import SwiftUI
import AppKit

/// One stopping point on the path.
struct PathSegment: Identifiable {
    let id: Int
    let title: String
    let isCurrent: Bool
    var action: (() -> Void)?
    var help: String?
}

/// The path: `Persuasion › Kellynch Hall › The Baronetage`, on the left of the toolbar
/// after the sidebar toggle. Each place is a small square framed button, like the toolbar's
/// others: ancestors open that book or chapter; the place you're on is pressed in (clicking a
/// scene's own name renames it).
struct PathBar: View {
    let segments: [PathSegment]
    /// The toolbar's room for the whole path.
    var room: CGFloat = .infinity

    var body: some View {
        let widths = Self.widths(of: segments, room: room)
        HStack(spacing: Self.gap) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Text("›")
                        .font(.system(size: Layout.chromeSize))
                        .foregroundStyle(Color(PaperTheme.tertiary))
                }
                label(for: segment)
                    // Each name gets a definite width (a flexible one was squeezed to a sliver:
                    // the toolbar sizes its items to their smallest): its full width while the
                    // path fits, shortened with "…" only when it doesn't.
                    .frame(width: widths[index])
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Space either side of a name inside its frame.
    static let padding: CGFloat = 8

    /// Between a place and the ›, and the › and the next place.
    static let gap: CGFloat = 5

    /// A name's own width in the chrome face, frame included.
    static func width(of segment: PathSegment) -> CGFloat {
        // Measuring text is slow and the toolbar asks on every redraw: remember each name.
        let key = "\(segment.isCurrent ? 1 : 0)\(Layout.chromeSize)\u{0}\(segment.title)"
        if let known = measured[key] { return known }
        let font = NSFont.systemFont(ofSize: Layout.chromeSize, weight: segment.isCurrent ? .semibold : .medium)
        let natural = (segment.title as NSString).size(withAttributes: [.font: font]).width
        // Capped (DESIGN.md): 240pt for where you are, 180pt for its ancestors.
        let width = min(ceil(natural) + 2 + 2 * padding, segment.isCurrent ? 240 : 180)
        if measured.count > 500 { measured.removeAll() }
        measured[key] = width
        return width
    }

    @MainActor private static var measured: [String: CGFloat] = [:]

    /// Every place at full width if the path fits in `room`. If not, the ancestors give way
    /// first, the longest first, down to 90pt each; then the current place, down to 120pt.
    static func widths(of segments: [PathSegment], room: CGFloat) -> [CGFloat] {
        var widths = segments.map(width(of:))
        let arrows = CGFloat(max(0, segments.count - 1)) * (gap * 2 + 8)
        var over = widths.reduce(0, +) + arrows - room
        guard over > 0 else { return widths }
        // Ancestors: shave the longest down towards the next longest, repeatedly.
        let ancestors = segments.indices.filter { !segments[$0].isCurrent }
        while over > 0.5 {
            let shrinkable = ancestors.filter { widths[$0] > 90 }
            guard let widest = shrinkable.map({ widths[$0] }).max() else { break }
            // Every ancestor at the widest width gives way together (two capped names are
            // the same width), down to the next widest, or to 90pt.
            let tied = shrinkable.filter { widths[$0] >= widest - 0.5 }
            let next = shrinkable.map { widths[$0] }.filter { $0 < widest - 0.5 }.max() ?? 90
            let each = max(min(over / CGFloat(tied.count), widest - max(90, next)), 0.5)
            for index in tied { widths[index] -= each }
            over -= each * CGFloat(tied.count)
        }
        if over > 0.5, let current = segments.firstIndex(where: \.isCurrent) {
            widths[current] = max(120, widths[current] - over)
        }
        return widths.map { $0.rounded(.down) }
    }

    @ViewBuilder
    private func label(for segment: PathSegment) -> some View {
        let text = Text(segment.title)
            .font(.system(size: Layout.chromeSize, weight: segment.isCurrent ? .semibold : .medium))
            .truncationMode(.middle)
        if let action = segment.action {
            Button(action: action) { text }
                .buttonStyle(PathButtonStyle(current: segment.isCurrent))
                .help(segment.help ?? "")
        } else {
            text
                .modifier(PathFrame(current: segment.isCurrent, pressed: false, hovering: false, enabled: true))
        }
    }
}

/// A place on the path: square, framed, on the control fill; the current one pressed in.
private struct PathButtonStyle: ButtonStyle {
    let current: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PathFrame(current: current, pressed: configuration.isPressed, hovering: hovering, enabled: true))
            .onHover { hovering = $0 }
    }
}

private struct PathFrame: ViewModifier {
    let current: Bool
    let pressed: Bool
    let hovering: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        let on = current || pressed
        content
            .foregroundStyle(Color(current ? PaperTheme.ink : PaperTheme.secondary))
            .padding(.horizontal, PathBar.padding)
            .frame(maxWidth: .infinity, minHeight: Layout.controlHeight)
            .background(Color(on ? PaperTheme.controlOn : hovering ? PaperTheme.hover : PaperTheme.controlFill))
            .roundedFrame(Color(on ? PaperTheme.controlOnBorder : PaperTheme.controlBorder), lineWidth: 1)
            .contentShape(Rectangle())
    }
}
