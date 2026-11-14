import AppKit
import SwiftUI

/// Colours for badges. A book without a cover picture is a blank book in its form's colour
/// (`CoverColours`, owner 2026-11-14).
enum BookLook {
    /// The stages' badge colours (`BookStage.colour`).
    enum Colour: String {
        case yellow, green, blue, grey

        var color: NSColor {
            switch self {
            case .yellow: return pair(0xA27F14, 0xD9B54E)
            case .green: return pair(0x3F8A4A, 0x7CC487)
            case .blue: return pair(0x3D6FB0, 0x7FA6DD)
            case .grey: return pair(0x75736C, 0xA09E96)
            }
        }

        private func pair(_ light: Int, _ dark: Int) -> NSColor {
            func rgb(_ v: Int) -> NSColor {
                NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                        blue: CGFloat(v & 0xFF) / 255, alpha: 1)
            }
            return NSColor(name: "Book" + rawValue.capitalized) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
            }
        }
    }
}

/// Each form's cover colour (owner, 2026-11-14; mock-up
/// https://claude.ai/artifact/6KQ8iA4KAemUHmExe2JTg8): novel red, novella purple, short story
/// yellow, poetry green, lyrics orange, essay blue, screenplay white, notebook brown. The same
/// in light and dark: a book is the colour it is.
struct CoverColours {
    let fill: NSColor
    let spine: NSColor
    let edge: NSColor
    let ink: NSColor
    /// A screenplay's two brass fasteners.
    var brads = false

    private static func rgb(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    private init(_ fill: Int, _ spine: Int, edge: Int? = nil, ink: Int, brads: Bool = false) {
        self.fill = Self.rgb(fill); self.spine = Self.rgb(spine)
        self.edge = Self.rgb(edge ?? spine); self.ink = Self.rgb(ink); self.brads = brads
    }
    private init(fill: NSColor, spine: NSColor, edge: NSColor, ink: NSColor) {
        self.fill = fill; self.spine = spine; self.edge = edge; self.ink = ink
    }

    static func of(_ form: BookForm?) -> CoverColours {
        switch form {
        case .novel: return CoverColours(0xA63D33, 0x84302A, ink: 0xFBF7F0)
        case .novella: return CoverColours(0x6B4C8A, 0x553C6E, ink: 0xFBF7F0)
        case .shortStory: return CoverColours(0xD9AE3B, 0xB8912C, ink: 0x2A2825)
        case .poetry: return CoverColours(0x4C7A50, 0x3C6140, ink: 0xFBF7F0)
        case .lyrics: return CoverColours(0xC8692C, 0xA55522, ink: 0xFBF7F0)
        case .essay: return CoverColours(0x3D6698, 0x30527A, ink: 0xFBF7F0)
        case .screenplay: return CoverColours(0xF8F6EF, 0xE4E1D7, edge: 0xC9C6BB, ink: 0x2A2825, brads: true)
        case .notebook: return CoverColours(0x7A5536, 0x604129, ink: 0xF3E9DC)
        // No form yet: the plain blank book, in the theme's own colours.
        case nil: return CoverColours(fill: PaperTheme.card, spine: PaperTheme.hairline, edge: PaperTheme.frame, ink: PaperTheme.secondary)
        }
    }
}

/// A blank book in its form's colour: the cover's shape (1:1.6), a darker spine down the left,
/// and on it the title's first letter or, large enough to read, the title and the author.
/// Never the form's name (owner: the colour says it). Until a picture is chosen it stands in
/// for one everywhere.
struct BookPlaceholder: View {
    let title: String
    var width: CGFloat = 36
    var form: BookForm? = nil
    /// The author's byline, shown under the title on a large cover.
    var byline: String = ""
    /// One piece or a collection (nil: the form's own default); short stories, poems, songs and
    /// essays get a different cover for each (owner, 2026-11-14).
    var collection: Bool? = nil

    /// Wide enough to set the title (and the author) rather than its initial: the contents'
    /// covers and up (owner, 2026-11-14: "full text covers").
    private var large: Bool { width >= 48 }
    /// Small covers set their words a little larger for their size, to stay legible.
    private var titleSize: CGFloat { width >= 100 ? width * 0.125 : max(7.5, width * 0.15) }
    private var bylineSize: CGFloat { width >= 100 ? max(Layout.detailSize, width * 0.078) : max(6, width * 0.1) }

    private var height: CGFloat { width * 1.6 }
    private var spineWidth: CGFloat { max(2, width * 0.065) }
    /// Where words start (the spine and a margin) and how wide they run.
    private var lead: CGFloat { width * 0.14 }
    private var textWidth: CGFloat { width * 0.78 }
    private var collected: Bool { form.map { $0.collects && (collection ?? $0.collectionByDefault) } ?? false }
    private var shownTitle: String { title.isEmpty ? "Untitled" : title }
    /// Dark type on the cream labels and cards, whatever the cover's own ink.
    private static let labelInk = Color(red: 0.165, green: 0.157, blue: 0.145)

    var body: some View {
        let colours = CoverColours.of(form)
        let radius = min(Layout.radius, width * 0.08)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(colours.fill))
            Rectangle().fill(Color(colours.spine)).frame(width: spineWidth, height: height)
            if colours.brads, width >= 60 {
                VStack {
                    brad
                    Spacer()
                    brad
                }
                .padding(.vertical, height * 0.22)
                .padding(.leading, width * 0.13)
            }
            if large {
                design(colours)
            } else {
                Text(initial)
                    .font(.system(size: width * 0.52, weight: .regular, design: .serif))
                    .foregroundStyle(Color(colours.ink))
                    .padding(.leading, spineWidth)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(rounded(radius))
        .overlay(rounded(radius).strokeBorder(Color(colours.edge), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    // MARK: The designs (owner's picks, 2026-11-14)

    /// Novel: a double rule frame. Novella: the same without it. Short story: title left, no
    /// ribbon; a collection: a cream label. Poetry: title low on the left; a collection adds a
    /// dark band. Lyrics: staff lines. Essay: a cream card; a collection: a masthead rule.
    /// Notebook: an elastic band. Screenplay and any other: the title centred.
    @ViewBuilder private func design(_ colours: CoverColours) -> some View {
        let ink = Color(colours.ink)
        switch form {
        case .novel?, .novella?:
            ZStack(alignment: .topLeading) {
                if form == .novel {
                    frameRule(ink: ink, inset: 0)
                    frameRule(ink: ink, inset: width * 0.035)
                }
                layer(.topLeading, top: height * 0.34, lead: centred(form == .novel ? width * 0.62 : textWidth)) {
                    VStack(spacing: width * 0.06) {
                        titleText(.center, wide: form == .novel ? width * 0.62 : textWidth)
                        Rectangle().frame(width: width * 0.26, height: 1)
                        bylineText(.center, wide: form == .novel ? width * 0.62 : textWidth)
                    }
                }
            }
            .foregroundStyle(ink)
        case .shortStory? where !collected:
            ZStack(alignment: .topLeading) {
                layer(.topLeading, top: height * 0.42) { titleText(.leading) }
                layer(.bottomLeading, bottom: height * 0.09) { bylineText(.leading) }
            }
            .foregroundStyle(ink)
        case .shortStory?:
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(red: 0.953, green: 0.890, blue: 0.659))
                    .padding(EdgeInsets(top: height * 0.22, leading: width * 0.2, bottom: height * 0.30, trailing: width * 0.12))
                layer(.topLeading, top: height * 0.22, lead: width * 0.24) {
                    titleText(.center, wide: width * 0.60)
                        .frame(height: height * 0.48)
                }
                layer(.bottomLeading, bottom: height * 0.12) { bylineText(.center) }
            }
            .foregroundStyle(Self.labelInk)
        case .poetry?:
            ZStack(alignment: .topLeading) {
                if collected {
                    Rectangle().fill(Color(colours.spine))
                        .overlay(Color.black.opacity(0.15))
                        .frame(width: width - spineWidth, height: height * 0.34)
                        .frame(width: width, height: height, alignment: .bottomTrailing)
                }
                layer(.bottomLeading, bottom: height * 0.09, lead: width * 0.18) {
                    VStack(alignment: .leading, spacing: width * 0.04) {
                        titleText(.leading, wide: width * 0.74)
                        bylineText(.leading)
                    }
                }
            }
            .foregroundStyle(ink)
        case .lyrics?:
            ZStack(alignment: .topLeading) {
                VStack(spacing: width * 0.035) {
                    ForEach(0..<5, id: \.self) { _ in Rectangle().frame(height: 1) }
                }
                .opacity(0.7)
                .padding(.leading, spineWidth)
                .padding(.top, height * 0.30)
                layer(.topLeading, top: height * 0.58, lead: centred(textWidth)) { titleText(.center) }
                layer(.bottomLeading, bottom: height * 0.12, lead: centred(textWidth)) { bylineText(.center) }
            }
            .foregroundStyle(ink)
        case .essay? where collected:
            ZStack(alignment: .topLeading) {
                Rectangle().frame(height: 1)
                    .padding(.leading, lead).padding(.trailing, width * 0.08).padding(.top, height * 0.10)
                layer(.topLeading, top: height * 0.30) { titleText(.leading) }
                layer(.bottomLeading, bottom: height * 0.09) { bylineText(.leading) }
            }
            .foregroundStyle(ink)
        case .essay?:
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(red: 0.953, green: 0.937, blue: 0.894))
                    .padding(EdgeInsets(top: height * 0.18, leading: lead, bottom: height * 0.18, trailing: width * 0.08))
                VStack(spacing: width * 0.04) {
                    titleText(.center, wide: width * 0.62)
                    Rectangle().frame(width: width * 0.12, height: 1)
                    bylineText(.center)
                }
                .padding(.leading, lead).padding(.trailing, width * 0.08)
                .frame(width: width, height: height * 0.64)
                .padding(.top, height * 0.18)
            }
            .foregroundStyle(Self.labelInk)
        case .notebook?:
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black.opacity(0.75))
                    .frame(width: max(2, width * 0.05), height: height)
                    .padding(.trailing, width * 0.12)
                    .frame(width: width, height: height, alignment: .trailing)
                layer(.topLeading, top: height * 0.10) { titleText(.leading, wide: width * 0.52) }
            }
            .foregroundStyle(ink)
        default:
            layer(.center, lead: centred(textWidth)) {
                VStack(spacing: width * 0.06) {
                    titleText(.center)
                    bylineText(.center)
                }
            }
            .foregroundStyle(ink)
        }
    }

    /// A layer the size of the cover, its content pinned by `alignment` and the offsets.
    private func layer<C: View>(_ alignment: Alignment, top: CGFloat = 0, bottom: CGFloat = 0, lead: CGFloat? = nil,
                                @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.top, top).padding(.bottom, bottom).padding(.leading, lead ?? self.lead)
            .frame(width: width, height: height, alignment: alignment)
    }

    /// The left offset that centres something `wide` in the cover beside the spine.
    private func centred(_ wide: CGFloat) -> CGFloat { (width + spineWidth - wide) / 2 }

    private func frameRule(ink: Color, inset: CGFloat) -> some View {
        Rectangle().strokeBorder(ink.opacity(0.7), lineWidth: 1)
            .padding(EdgeInsets(top: height * 0.08 + inset, leading: lead + inset, bottom: height * 0.08 + inset, trailing: width * 0.07 + inset))
    }

    private func titleText(_ align: TextAlignment, wide: CGFloat? = nil) -> some View {
        Text(shownTitle)
            .font(.system(size: titleSize, weight: .regular, design: .serif))
            .multilineTextAlignment(align)
            .lineLimit(5)
            .minimumScaleFactor(0.6)
            .frame(width: wide ?? textWidth, alignment: align == .leading ? .leading : .center)
    }

    @ViewBuilder private func bylineText(_ align: TextAlignment, wide: CGFloat? = nil) -> some View {
        if !byline.isEmpty {
            Text(byline)
                .font(.system(size: bylineSize, design: .serif).italic())
                .lineLimit(2)
                .multilineTextAlignment(align)
                .frame(width: wide ?? textWidth, alignment: align == .leading ? .leading : .center)
        }
    }

    private var brad: some View {
        Circle().fill(Color(red: 0.71, green: 0.61, blue: 0.37)).frame(width: max(3, width * 0.045), height: max(3, width * 0.045))
    }

    private var initial: String {
        let skip = ["the ", "a ", "an "]
        var text = title.trimmingCharacters(in: .whitespaces)
        if let article = skip.first(where: { text.lowercased().hasPrefix($0) && text.count > $0.count }) {
            text = String(text.dropFirst(article.count))
        }
        return text.first.map { String($0).uppercased() } ?? "·"
    }
}

/// A book's cover, or its placeholder.
struct BookCover: View {
    let title: String
    let image: NSImage?
    var width: CGFloat = 36
    var form: BookForm? = nil
    var byline: String = ""
    var collection: Bool? = nil

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: width * 1.6)
                .clipShape(rounded(min(Layout.radius, max(2, width * 0.06))))
                .overlay(rounded(min(Layout.radius, max(2, width * 0.06))).strokeBorder(Color(PaperTheme.frame), lineWidth: 1))
        } else {
            BookPlaceholder(title: title, width: width, form: form, byline: byline, collection: collection)
        }
    }
}
