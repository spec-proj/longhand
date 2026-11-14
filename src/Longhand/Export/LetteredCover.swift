import AppKit

/// A plain cover of type alone, for a story exported as an e-book without a cover picture.
/// Four styles (designs shown to the owner 2026-11-13; they chose to offer all four). It is
/// drawn into the exported file only, never kept as the story's cover.
///
/// Drawn on a 160 × 256 grid (the Kindle shape, 1:1.6) and scaled, so the export sheet's
/// small previews and the e-book's 1600 × 2560 cover are the same drawing.
enum LetteredCover {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case paper, ink, shelf, frame
        var id: String { rawValue }
        var title: String {
            switch self {
            case .paper: return "Paper"
            case .ink: return "Ink"
            case .shelf: return "Shelf"
            case .frame: return "Frame"
            }
        }
    }

    struct Text {
        var title: String
        /// The byline; left off when empty.
        var author: String
        /// "a novel", for Frame; nil leaves the line out.
        var form: String?
    }

    static let grid = CGSize(width: 160, height: 256)

    /// The e-book's cover: 1600 × 2560 pixels.
    static func bitmap(_ style: Style, _ text: Text, width: Int = 1600) -> NSImage? {
        let height = width * 16 / 10
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Flip, so the drawing below reads top-down like the designs.
        let cg = context.cgContext
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = flipped
        draw(style, text, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// A preview for the export sheet, drawn at the screen's resolution.
    static func preview(_ style: Style, _ text: Text, width: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: width, height: width * 1.6), flipped: true) { rect in
            draw(style, text, in: rect)
            return true
        }
    }

    // MARK: Drawing

    private static let paperColour = NSColor(srgbRed: 0xf6 / 255, green: 0xf2 / 255, blue: 0xea / 255, alpha: 1)
    private static let shelfColour = NSColor(srgbRed: 0xef / 255, green: 0xe9 / 255, blue: 0xdd / 255, alpha: 1)
    private static let inkColour = NSColor(srgbRed: 0x2b / 255, green: 0x29 / 255, blue: 0x25 / 255, alpha: 1)
    private static let nightColour = NSColor(srgbRed: 0x1f / 255, green: 0x2a / 255, blue: 0x36 / 255, alpha: 1)
    private static let redColour = NSColor(srgbRed: 0xa5 / 255, green: 0x40 / 255, blue: 0x2d / 255, alpha: 1)

    /// Draws into a flipped context filling `rect`, of any shape near 1:1.6.
    static func draw(_ style: Style, _ text: Text, in rect: CGRect) {
        let s = rect.width / grid.width
        // Laid out down the page's own height, so a book page (5.5 × 8.5, a little wider
        // than 1:1.6) gets the same design rather than a crop of it.
        let gh = rect.height / s
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }
        let title = text.title.isEmpty ? "Untitled" : text.title
        let author = text.author.trimmingCharacters(in: .whitespacesAndNewlines)

        switch style {
        case .paper:
            paperColour.setFill(); rect.fill()
            let t = line(title, serif(24 * s), inkColour, .center, leading: 1.1)
            let a = line(author, serif(12 * s, italic: true), inkColour, .center)
            let width: CGFloat = 132
            let th = height(t, width * s) / s, ah = author.isEmpty ? 0 : height(a, width * s) / s
            let total = th + 29 + ah
            var y = (gh - total) / 2
            t.draw(with: r(14, y, width, th), options: wrap)
            y += th + 14
            inkColour.setFill(); r(66, y, 28, 1).fill()
            y += 15
            if !author.isEmpty { a.draw(with: r(14, y, width, ah), options: wrap) }

        case .ink:
            nightColour.setFill(); rect.fill()
            let light = NSColor(srgbRed: 0xef / 255, green: 0xe9 / 255, blue: 0xdd / 255, alpha: 1)
            let t = line(title, serif(24 * s), light, .center, leading: 1.1)
            t.draw(with: r(14, 26, 132, height(t, 132 * s) / s), options: wrap)
            if !author.isEmpty {
                let a = line(author, serif(12 * s), light, .center, kern: 0.24 * s)
                let ah = height(a, 132 * s) / s
                a.draw(with: r(14, gh - 22 - ah, 132, ah), options: wrap)
            }

        case .shelf:
            shelfColour.setFill(); rect.fill()
            redColour.setFill(); r(14, 18, 36, 3).fill()
            let t = line(title, serif(27 * s), inkColour, .left, leading: 1.02)
            t.draw(with: r(14, 33, 132, height(t, 132 * s) / s), options: wrap)
            if !author.isEmpty {
                let a = line(author, NSFont.systemFont(ofSize: 12 * s, weight: .medium), inkColour, .left)
                let ah = height(a, 132 * s) / s
                a.draw(with: r(14, gh - 18 - ah, 132, ah), options: wrap)
            }

        case .frame:
            paperColour.setFill(); rect.fill()
            inkColour.setStroke()
            for inset in [CGFloat(9.5), 14.5] {
                let path = NSBezierPath(rect: r(inset, inset, grid.width - inset * 2, gh - inset * 2))
                path.lineWidth = s
                path.stroke()
            }
            let width: CGFloat = 116
            let f = text.form.map { line($0, serif(11 * s, italic: true), inkColour, .center) }
            let t = line(title, serif(22 * s), inkColour, .center, leading: 1.1)
            let a = line(author, serif(12 * s), inkColour, .center)
            let fh = f.map { height($0, width * s) / s } ?? 0
            let th = height(t, width * s) / s
            let ah = author.isEmpty ? 0 : height(a, width * s) / s
            let total = fh + (f == nil ? 0 : 10) + th + (author.isEmpty ? 0 : 16 + ah)
            var y = (gh - total) / 2
            if let f { f.draw(with: r(22, y, width, fh), options: wrap); y += fh + 10 }
            t.draw(with: r(22, y, width, th), options: wrap)
            y += th + 16
            if !author.isEmpty { a.draw(with: r(22, y, width, ah), options: wrap) }
        }
    }

    private static let wrap: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    private static func serif(_ size: CGFloat, italic: Bool = false) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            ?? NSFont.systemFont(ofSize: size).fontDescriptor
        if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private static func line(_ string: String, _ font: NSFont, _ colour: NSColor, _ alignment: NSTextAlignment,
                             leading: CGFloat? = nil, kern: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        if let leading {
            style.minimumLineHeight = font.pointSize * leading
            style.maximumLineHeight = font.pointSize * leading
        }
        return NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: colour, .paragraphStyle: style, .kern: kern,
        ])
    }

    private static func height(_ text: NSAttributedString, _ width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: wrap).height)
    }

    /// "a novel" for a story's form ("stories" for a collection); nothing for a notebook or
    /// no form.
    static func formLine(_ form: BookForm?, collection: Bool? = nil) -> String? {
        let collected = collection ?? form?.collectionByDefault ?? false
        switch form {
        case .novel: return "a novel"
        case .novella: return "a novella"
        case .shortStory: return collected ? "stories" : "a short story"
        case .poetry: return collected ? "poems" : "a poem"
        case .lyrics: return collected ? "songs" : "a song"
        case .essay: return collected ? "essays" : "an essay"
        case .screenplay: return "a screenplay"
        case .notebook, nil: return nil
        }
    }
}
