import AppKit
import CoreText

/// Courier Prime (owner, 2026-11-14): the screenplay face, on the page and in every export.
/// Made for screenplays by Alan Dague-Greene for John August (quoteunquoteapps.com), under the
/// SIL Open Font License (`third_party/CourierPrime-OFL.txt`); bundled in `src/Longhand/Fonts`
/// and registered for this app alone at launch. Like Courier, every character is 0.6 em wide,
/// so 12pt sets ten characters an inch and a page runs about a minute.
enum ScreenplayFont {
    private static var registered = false

    /// Registers the bundled faces. Safe to call more than once.
    static func register() {
        guard !registered else { return }
        registered = true
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("CourierPrime") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        register()
        let name: String
        switch (bold, italic) {
        case (false, false): name = "CourierPrime-Regular"
        case (true, false): name = "CourierPrime-Bold"
        case (false, true): name = "CourierPrime-Italic"
        case (true, true): name = "CourierPrime-BoldItalic"
        }
        if let font = NSFont(name: name, size: size) { return font }
        // Without the bundled faces (never expected): Courier, then any monospaced face.
        let fallback = NSFont(name: "Courier", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return traits.isEmpty ? fallback : NSFontManager.shared.convert(fallback, toHaveTrait: traits)
    }

    static func font(_ size: CGFloat, style: Fountain.Style) -> NSFont {
        font(size, bold: style.contains(.bold), italic: style.contains(.italic))
    }

    /// The width of one character, as a share of the size.
    static let advance: CGFloat = 0.6
}
