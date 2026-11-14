import AppKit
import CoreText
import SwiftUI

/// Colours. Each one is a fixed pair (light, dark) rather than a system colour with alpha
/// added, because those get frozen to whichever appearance was current when they were made.
/// Values come from the Margins design (`notes/design-proposal-2026-11-06.md`), set in the
/// Classic Mac layout the owner chose on 2026-11-06: framed panels on a grey window.
enum PaperTheme {
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// A colour that follows the chosen theme (Settings › Theme) and the light or dark mode.
    private static func token(_ name: String, _ pick: @escaping @Sendable (Palette) -> NSColor) -> NSColor {
        NSColor(name: name) { appearance in pick(AppTheme.palette(dark: isDark(appearance))) }
    }

    /// The page: warm off-white, never pure white; warm charcoal, never black.
    static let paper = token("Paper") { $0.paper }

    /// The window itself, behind the panels: toolbar, foot bars and the status bar.
    static let chrome = token("Chrome") { $0.chrome }

    /// The inset panels that hold the contents and the margin.
    static let well = token("Well") { $0.well }

    /// The contents list sits in a well.
    static let sidebar = well

    /// A panel's hairline frame.
    static let frame = token("Frame") { $0.frame }

    /// Framed controls on the window: buttons and segments. "On" is a pressed toggle or the
    /// chosen segment.
    static let controlFill = token("ControlFill") { $0.controlFill }
    static let controlBorder = token("ControlBorder") { $0.controlBorder }
    static let controlOn = token("ControlOn") { $0.controlOn }
    static let controlOnBorder = token("ControlOnBorder") { $0.controlOnBorder }

    /// The comment in focus, in the margin's list.
    static let commentFocus = token("CommentFocus") { $0.commentFocus }

    /// Prose and primary labels. In Paper, softer than black on white and white on black
    /// (about 14:1 and 11:1): strong enough for small type, without the glare and the halo that
    /// near-white text has on a dark page (2026-11-08, for long sessions without eye strain).
    static let ink = token("Ink") { $0.ink }

    /// Counts, ancestors in the path, timestamps, idle icons.
    static let secondary = token("Secondary") { $0.secondary }

    /// Disclosure triangles and other marks that only need to be findable.
    static let tertiary = token("Tertiary") { $0.tertiary }

    /// Every rule and divider: one hairline, one colour.
    static let hairline = token("Hairline") { $0.hairline }

    /// The selected row, a pressed button, a panel toggle that is on.
    static let selection = token("Selection") { $0.selection }

    /// Under the pointer.
    static let hover = token("Hover") { $0.hover }

    /// A comment being worked on sits on a card.
    static let card = token("Card") { $0.card }
    static let cardBorder = token("CardBorder") { $0.cardBorder }

    /// Commented text, and the comment in focus.
    static let highlight = token("Highlight") { $0.highlight }
    static let highlightFocus = token("HighlightFocus") { $0.highlightFocus }

    /// Markdown symbols (#, *, >): present but quiet.
    static let marker = token("Marker") { $0.ink.withAlphaComponent($0.dark ? 0.32 : 0.30) }

    /// Block quotes: a step softer than prose.
    static let quote = token("Quote") { $0.ink.withAlphaComponent($0.dark ? 0.70 : 0.72) }

    static let codeFill = token("CodeFill") { $0.ink.withAlphaComponent($0.dark ? 0.08 : 0.05) }

    /// Compare Versions and changes since the last version, set like any diff: old text on red
    /// rows, new on green, the words that changed a shade darker, − and + in the gutter. Used
    /// only to show changes.
    static let diffAddedRow = token("DiffAddedRow") { $0.diffAddedRow }
    static let diffAddedWord = token("DiffAddedWord") { $0.diffAddedWord }
    static let diffAddedMark = token("DiffAddedMark") { $0.diffAddedMark }
    static let diffRemovedRow = token("DiffRemovedRow") { $0.diffRemovedRow }
    static let diffRemovedWord = token("DiffRemovedWord") { $0.diffRemovedWord }
    static let diffRemovedMark = token("DiffRemovedMark") { $0.diffRemovedMark }
    /// A paragraph or scene edited since the last version (bars on the page, marks in the
    /// contents): ochre in Paper, the theme's yellow or orange in the others.
    static let diffChangedMark = token("DiffChangedMark") { $0.diffChangedMark }

    /// The one accent: the caret and links, and the sign that a backup failed.
    static let accent = token("Accent") { $0.accent }
}

extension Color {
    init(_ color: NSColor) { self.init(nsColor: color) }
}

/// The face the prose is set in. The interface is always the system face (SF Pro).
enum ProseFace: String, CaseIterable, Identifiable {
    /// SF Pro, Apple's system face: the sans option, and the default. (Source Sans 3, Alegreya
    /// Sans and iA Writer Quattro were tried and dropped by the owner.)
    case sfPro
    /// New York, Apple's own serif (owner, 2026-11-08: ET Book was dropped, "awful").
    case newYork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfPro: return "SF Pro"
        case .newYork: return "New York"
        }
    }

    static let defaultsKey = "proseFace"

    static var current: ProseFace {
        let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        // ET Book's choosers get the serif that replaced it; dropped sans faces get SF Pro.
        if stored == "etBook" { return .newYork }
        return ProseFace(rawValue: stored) ?? .sfPro
    }

    /// Body size: each face set so its lowercase reads at about the same size, then moved by
    /// View › Bigger / Smaller (`ProseSize`).
    var size: CGFloat {
        (self == .newYork ? 18 : 17) + CGFloat(ProseSize.current)
    }

    /// Line height as a multiple of the size.
    var leading: CGFloat { self == .newYork ? 1.6 : 1.65 }

    /// The face's regular, bold (headings, **strong**) or italic font.
    fileprivate func font(bold: Bool = false, italic: Bool = false, size: CGFloat) -> NSFont? {
        switch self {
        case .newYork:
            let base = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            guard let serif = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: serif, size: size) else { return nil }
            return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        case .sfPro:
            let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        }
    }
}

/// View › Bigger Text / Smaller Text / Actual Size: steps of about a point from the default
/// size (17pt SF Pro, 18pt New York). Remembered between launches.
enum ProseSize {
    static let defaultsKey = "proseSize"
    static let range = -3...8

    static var current: Int {
        min(range.upperBound, max(range.lowerBound, UserDefaults.standard.integer(forKey: defaultsKey)))
    }

    /// One step bigger (+1) or smaller (−1); 0 goes back to the default size.
    static func step(_ by: Int) {
        let next = by == 0 ? 0 : min(range.upperBound, max(range.lowerBound, current + by))
        if next != current { UserDefaults.standard.set(next, forKey: defaultsKey) }
    }
}

/// The prose face, with the system serif as a fallback.
enum EditorFont {
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let font = ProseFace.current.font(bold: weight >= .semibold, size: size) { return font }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    static func italic(_ size: CGFloat) -> NSFont {
        if let font = ProseFace.current.font(italic: true, size: size) { return font }
        return NSFontManager.shared.convert(serif(size), toHaveTrait: .italicFontMask)
    }

    static func boldItalic(_ size: CGFloat) -> NSFont {
        if let font = ProseFace.current.font(bold: true, italic: true, size: size) { return font }
        return NSFontManager.shared.convert(serif(size, weight: .semibold), toHaveTrait: .italicFontMask)
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Measurements. The measure is set in characters, not points, so it stays right whatever the
/// face and size: about 68 characters a line, inside the 60–75 a novel wants.
enum Layout {
    static var textSize: CGFloat { ProseFace.current.size }
    static let measure: CGFloat = 68

    /// Space either side of the column.
    static let gutter: CGFloat = 32

    /// The margin Markdown symbols hang into, so the left edge of the prose stays straight.
    static let hang: CGFloat = 30

    /// Caches are kept per face and size.
    private struct Key: Hashable { let face: ProseFace; let size: CGFloat }
    private static var key: Key { Key(face: ProseFace.current, size: textSize) }

    private static var widths: [Key: CGFloat] = [:]

    /// Average character width of the prose face at `textSize`.
    static var characterWidth: CGFloat {
        let key = key
        if let width = widths[key] { return width }
        let sample = "the quick brown fox jumps over the lazy dog, and then, Reader, she married him."
        let width = (sample as NSString).size(withAttributes: [.font: EditorFont.serif(textSize)]).width
            / CGFloat(sample.count)
        widths[key] = width
        return width
    }

    private static var corrections: [Key: CGFloat] = [:]

    /// Line heights are given as multiples of the type size (1.6 = 32pt lines for 20pt type),
    /// but AppKit multiplies the font's own line height, which differs from face to face
    /// (faces differ). This converts one to the other.
    static var lineHeightCorrection: CGFloat {
        let key = key
        if let value = corrections[key] { return value }
        let font = EditorFont.serif(textSize)
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        let value = natural > 0 ? textSize / natural : 1
        corrections[key] = value
        return value
    }

    /// Width of the prose itself.
    static var proseWidth: CGFloat { (characterWidth * measure).rounded() }

    /// The full column: prose, the hanging margin on both sides, and the gutters.
    static var column: CGFloat { proseWidth + 2 * (hang + gutter) }

    /// Where the prose starts inside the column; the status line aligns here.
    static var proseInset: CGFloat { hang + gutter }

    /// Interface type is on Apple's macOS scale (HIG): 13 (Body, Headline) for chrome, rows and
    /// titles, 12 (Callout) for secondary lines and counts, 15 (Title 3) for a book's name.
    /// No half points and nothing under 12 for words, so grey text never tires the eyes
    /// (owner, 2026-11-08). Weights: Regular for rows and reading; Medium for control labels
    /// and short grey labels; Semibold for the chosen item; Bold (`.headline`) for titles.
    static let chromeSize: CGFloat = 13
    static let listSize: CGFloat = 13
    static let detailSize: CGFloat = 12
    static let smallSize: CGFloat = 12
    /// A story's page sets its byline and synopsis in New York at Title 3's size. Fixed: the
    /// Editor's font and Bigger Text are for the prose, never for the interface.
    static let blurbSize: CGFloat = 15

    /// Height of the bars at the foot of each column, and of the header row at the top of the
    /// contents and the margin (so their hairlines line up across the window).
    static let barHeight: CGFloat = 32
    /// The column of labels in a sheet (Export, Commit, Push, Branch): one width, so sheets line up.
    static let sheetLabel: CGFloat = 88
    /// How long Clear Desk takes to fade the desk away or back.
    static let deskFade: Double = 0.25
    static let headerHeight: CGFloat = 32
    /// Inside every panel, content starts this far from the frame (rows, cards, headers, foot
    /// bars alike), so left edges line up down each column.
    static let pad: CGFloat = 12
    /// The status bar along the foot of the window.
    static let statusHeight: CGFloat = 26
    /// Contents row height.
    static let rowHeight: CGFloat = 24
    /// The contents column and the margin, panels included.
    static let contentsWidth: CGFloat = 300
    static let marginWidth: CGFloat = 316
    /// Space between the panels and around them.
    static let inset: CGFloat = 10
    /// Framed controls: buttons and segmented tabs.
    static let controlHeight: CGFloat = 22

    /// Corner radii (owner, 2026-11-08: "subtle corner radius to everything", after the Mac's
    /// own look of the last ten years): controls, fields and cards 4, panels 6, selected
    /// rows 4, small badges and text highlights 2 (lowered 2026-11-12: "corner radius is too high").
    static let radius: CGFloat = 4
    static let panelRadius: CGFloat = 6
    static let rowRadius: CGFloat = 4
    static let smallRadius: CGFloat = 2
}

/// An icon: Apple's SF Symbols (owner, 2026-11-08), so every icon matches macOS. Sizes are
/// the visual size in points; the weight follows the text around it.
enum Symbol: String {
    case openPanelLeft = "sidebar.left"
    case openPanelRight = "sidebar.right"
    case search = "magnifyingglass"
    case addComment = "text.bubble"
    case add = "plus"
    case more = "ellipsis"
    case caretRight = "chevron.right"
    case caretDown = "chevron.down"
    case back = "chevron.left"
    case checkmark = "checkmark"
    case document = "doc.text"
    case chat = "bubble.left"
    case note = "note.text"
    case versions = "plus.forwardslash.minus"
    case close = "xmark"
    case folder = "folder"
    case upload = "arrow.up.to.line"
    case syncing = "arrow.triangle.2.circlepath"
    case mac = "laptopcomputer"
    case server = "server.rack"
    case menuBar = "pencil.and.scribble"

    func image(size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let image = NSImage(systemSymbolName: rawValue, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    func view(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        Image(systemName: rawValue)
            .font(.system(size: size, weight: weight))
            .frame(minWidth: size, minHeight: size)
    }
}

/// GitHub's own mark, for the buttons that go to GitHub: the one icon that isn't an SF Symbol
/// (owner, 2026-11-11). The outline is GitHub's, from its Octicons set (MIT; see
/// `third_party/ICONS.md`); it is drawn in the text colour around it, never recoloured.
struct GitHubMark: View {
    var size: CGFloat = 13

    private static let image: NSImage? = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.31-.63-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
