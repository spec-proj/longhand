import AppKit
import SwiftUI

/// How a book looks without a cover (owner, 2026-11-08: no icons or colours to choose): a
/// blank book in the cover's shape with the first letter of its title, in the serif.
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

/// A blank book: the cover's shape (1:1.6), a hairline, a spine shadow down the left and the
/// title's first letter. Until a cover is chosen it stands in for one everywhere.
struct BookPlaceholder: View {
    let title: String
    var width: CGFloat = 36

    var body: some View {
        let height = width * 1.6
        ZStack {
            rounded(min(Layout.radius, width * 0.08)).fill(Color(PaperTheme.card))
            HStack(spacing: 0) {
                Rectangle().fill(Color(PaperTheme.hairline)).frame(width: max(2, width * 0.07))
                Spacer(minLength: 0)
            }
            Text(initial)
                .font(.system(size: width * 0.52, weight: .regular, design: .serif))
                .foregroundStyle(Color(PaperTheme.secondary))
                .offset(x: width * 0.03)
        }
        .frame(width: width, height: height)
        .clipShape(rounded(min(Layout.radius, width * 0.08)))
        .overlay(rounded(min(Layout.radius, width * 0.08)).strokeBorder(Color(PaperTheme.frame), lineWidth: 1))
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

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: width * 1.6)
                .clipShape(rounded(min(Layout.radius, max(2, width * 0.06))))
                .overlay(rounded(min(Layout.radius, max(2, width * 0.06))).strokeBorder(Color(PaperTheme.frame), lineWidth: 1))
        } else {
            BookPlaceholder(title: title, width: width)
        }
    }
}
