import AppKit

/// Every colour Longhand draws with, for one theme in one mode (light or dark).
struct Palette: Sendable {
    var dark: Bool
    var paper, chrome, well, frame: NSColor
    var controlFill, controlBorder, controlOn, controlOnBorder: NSColor
    var commentFocus: NSColor
    var ink, secondary, tertiary: NSColor
    var hairline, selection, hover: NSColor
    var card, cardBorder: NSColor
    var highlight, highlightFocus: NSColor
    var accent: NSColor
    var diffAddedRow, diffAddedWord, diffAddedMark: NSColor
    var diffRemovedRow, diffRemovedWord, diffRemovedMark: NSColor
    var diffChangedMark: NSColor
}

/// Settings › Theme. Paper is Longhand's own; the others are published open-source themes,
/// their colours taken from each project's own palette (all MIT licensed; see
/// `third_party/THEMES.md`). Only a theme's own colours are used, mixed with each other where
/// Longhand needs a shade the palette doesn't have; words in a grey too faint to read
/// comfortably are deepened toward the theme's own text colour.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case paper, catppuccin, dracula, nord, solarized, gruvbox, rosePine, tokyoNight, everforest, oneDark, github
    /// Added 2026-11-13 (owner: "add more themes"), all MIT licensed.
    case flexoki, kanagawa, ayu, nightOwl, tomorrow
    /// Four named for novels (owner, 2026-11-12), each from a palette a person published for
    /// that work or its film; sources in `third_party/THEMES.md`.
    case electricSheep, areaX, odyssey, hailMary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: return "Paper"
        case .catppuccin: return "Catppuccin"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .solarized: return "Solarized"
        case .gruvbox: return "Gruvbox"
        case .rosePine: return "Rosé Pine"
        case .tokyoNight: return "Tokyo Night"
        case .everforest: return "Everforest"
        case .oneDark: return "One"
        case .github: return "GitHub"
        case .flexoki: return "Flexoki"
        case .kanagawa: return "Kanagawa"
        case .ayu: return "Ayu"
        case .nightOwl: return "Night Owl"
        case .tomorrow: return "Tomorrow"
        case .electricSheep: return "Electric Sheep"
        case .areaX: return "Area X"
        case .odyssey: return "2001"
        case .hailMary: return "Hail Mary"
        }
    }

    /// How Settings and the palette group them: Longhand's own, editors' themes, novels'.
    enum Family: String, CaseIterable { case own = "Longhand", editors = "Editor Themes", novels = "From Novels" }
    var family: Family {
        switch self {
        case .paper: return .own
        case .electricSheep, .areaX, .odyssey, .hailMary: return .novels
        default: return .editors
        }
    }
    static func members(of family: Family) -> [AppTheme] { allCases.filter { $0.family == family } }

    /// Dracula has no light version: choosing it turns the window dark.
    var darkOnly: Bool { self == .dracula || self == .electricSheep || self == .hailMary }

    static let defaultsKey = "theme"
    /// Settings › Appearance: "system", "light" or "dark".
    static let modeKey = "appearanceMode"

    /// The chosen theme and its two palettes, made once per choice: every themed colour reads
    /// one of them each time it is drawn, so that must cost next to nothing.
    private final class Chosen: @unchecked Sendable {
        let theme: AppTheme
        let light: Palette
        let dark: Palette
        init(_ theme: AppTheme) {
            self.theme = theme
            light = theme.make(dark: theme.darkOnly)
            dark = theme.make(dark: true)
        }
    }

    nonisolated(unsafe) private static var chosen = Chosen(stored)

    private static var stored: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .paper
    }

    static var current: AppTheme { chosen.theme }
    /// The theme kept in Settings (the one on screen may be a preview).
    static var kept: AppTheme { stored }

    /// Called by every themed colour as it is drawn. (Swapping the reference is atomic enough:
    /// a colour drawn mid-switch uses the old theme, and the window is redrawn after.)
    static func palette(dark: Bool) -> Palette {
        let chosen = chosen
        return dark ? chosen.dark : chosen.light
    }

    /// Switches theme: remembered, and the window is drawn again in it.
    @MainActor
    static func choose(_ theme: AppTheme) {
        chosen = Chosen(theme)
        UserDefaults.standard.set(theme.rawValue, forKey: defaultsKey)
        applyAppearance()
        ThemeState.shared.shown = theme
    }

    /// Shows a theme without keeping it (the palette's and Settings' lists, as the pointer or
    /// the arrow keys pass over a theme). `endPreview` puts the kept one back.
    @MainActor
    static func preview(_ theme: AppTheme) {
        guard theme != current else { return }
        chosen = Chosen(theme)
        applyAppearance()
        ThemeState.shared.shown = theme
    }

    /// Back to the theme kept in Settings, after previews.
    @MainActor
    static func endPreview() {
        preview(stored)
    }

    /// Picks up a theme set elsewhere (a hidden run's settings).
    static func reload() {
        chosen = Chosen(stored)
    }

    /// "system", "light" or "dark".
    static var mode: String { UserDefaults.standard.string(forKey: modeKey) ?? "system" }

    /// Light, dark or the Mac's own (the palette's and the View menu's way; Settings writes
    /// the same key).
    @MainActor
    static func setMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: modeKey)
        applyAppearance()
    }

    /// Light, dark or the Mac's own; a dark-only theme is always dark.
    @MainActor
    static func applyAppearance() {
        let mode = UserDefaults.standard.string(forKey: modeKey) ?? "system"
        if current.darkOnly || mode == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if mode == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        } else {
            NSApp.appearance = nil
        }
    }

    /// The colours shown on the theme's swatch in Settings: page, text, accent, marks.
    func swatch(dark: Bool) -> [NSColor] {
        let p = make(dark: darkOnly || dark)
        return [p.paper, p.ink, p.accent, p.diffAddedMark, p.diffChangedMark]
    }

    // MARK: - The palettes

    private func make(dark: Bool) -> Palette {
        switch (self, dark) {
        case (.paper, false): return Self.paperLight
        case (.paper, true): return Self.paperDark

        // Catppuccin (github.com/catppuccin/palette): Latte and Mocha.
        case (.catppuccin, false):
            return .derived(dark: false, paper: hex(0xEFF1F5), chrome: hex(0xE6E9EF), well: hex(0xEFF1F5),
                            frame: hex(0xBCC0CC), ink: hex(0x4C4F69), secondary: hex(0x6C6F85), tertiary: hex(0x8C8FA1),
                            selection: hex(0xCCD0DA), accent: hex(0x8839EF),
                            green: hex(0x40A02B), red: hex(0xD20F39), yellow: hex(0xDF8E1D))
        case (.catppuccin, true):
            return .derived(dark: true, paper: hex(0x1E1E2E), chrome: hex(0x181825), well: hex(0x1E1E2E),
                            frame: hex(0x45475A), ink: hex(0xCDD6F4), secondary: hex(0xA6ADC8), tertiary: hex(0x7F849C),
                            selection: hex(0x313244), accent: hex(0xCBA6F7),
                            green: hex(0xA6E3A1), red: hex(0xF38BA8), yellow: hex(0xF9E2AF))

        // Dracula (draculatheme.com/spec): dark only.
        case (.dracula, _):
            let background = hex(0x282A36), foreground = hex(0xF8F8F2)
            return .derived(dark: true, paper: background, chrome: hex(0x21222C), well: background,
                            frame: hex(0x44475A), ink: foreground, secondary: mix(foreground, background, 0.3),
                            tertiary: hex(0x6272A4), selection: hex(0x44475A), accent: hex(0xFF79C6),
                            green: hex(0x50FA7B), red: hex(0xFF5555), yellow: hex(0xFFB86C))

        // Nord (nordtheme.com): Snow Storm for light, Polar Night for dark.
        case (.nord, false):
            return .derived(dark: false, paper: hex(0xECEFF4), chrome: hex(0xE5E9F0), well: hex(0xECEFF4),
                            frame: hex(0xD8DEE9), ink: hex(0x2E3440), secondary: hex(0x4C566A), tertiary: hex(0x4C566A),
                            selection: hex(0xD8DEE9), accent: hex(0x5E81AC),
                            green: hex(0xA3BE8C), red: hex(0xBF616A), yellow: hex(0xD08770))
        case (.nord, true):
            let text = hex(0xD8DEE9), night = hex(0x2E3440)
            return .derived(dark: true, paper: night, chrome: hex(0x3B4252), well: night,
                            frame: hex(0x4C566A), ink: text, secondary: mix(text, night, 0.25), tertiary: mix(text, night, 0.45),
                            selection: hex(0x434C5E), accent: hex(0x88C0D0),
                            green: hex(0xA3BE8C), red: hex(0xBF616A), yellow: hex(0xEBCB8B))

        // Solarized (ethanschoonover.com/solarized).
        case (.solarized, false):
            return .derived(dark: false, paper: hex(0xFDF6E3), chrome: hex(0xEEE8D5), well: hex(0xFDF6E3),
                            frame: hex(0x93A1A1), ink: hex(0x586E75), secondary: hex(0x657B83), tertiary: hex(0x93A1A1),
                            selection: mix(hex(0xEEE8D5), hex(0x93A1A1), 0.3), accent: hex(0x268BD2),
                            green: hex(0x859900), red: hex(0xDC322F), yellow: hex(0xB58900))
        case (.solarized, true):
            return .derived(dark: true, paper: hex(0x002B36), chrome: hex(0x073642), well: hex(0x002B36),
                            frame: hex(0x586E75), ink: hex(0x93A1A1), secondary: hex(0x839496), tertiary: hex(0x657B83),
                            selection: mix(hex(0x073642), hex(0x586E75), 0.3), accent: hex(0x268BD2),
                            green: hex(0x859900), red: hex(0xDC322F), yellow: hex(0xB58900))

        // Gruvbox (github.com/morhetz/gruvbox).
        case (.gruvbox, false):
            return .derived(dark: false, paper: hex(0xFBF1C7), chrome: hex(0xEBDBB2), well: hex(0xFBF1C7),
                            frame: hex(0xBDAE93), ink: hex(0x3C3836), secondary: hex(0x665C54), tertiary: hex(0x928374),
                            selection: hex(0xD5C4A1), accent: hex(0xAF3A03),
                            green: hex(0x79740E), red: hex(0x9D0006), yellow: hex(0xB57614))
        case (.gruvbox, true):
            return .derived(dark: true, paper: hex(0x282828), chrome: hex(0x3C3836), well: hex(0x282828),
                            frame: hex(0x665C54), ink: hex(0xEBDBB2), secondary: hex(0xBDAE93), tertiary: hex(0x928374),
                            selection: hex(0x504945), accent: hex(0xFE8019),
                            green: hex(0xB8BB26), red: hex(0xFB4934), yellow: hex(0xFABD2F))

        // Rosé Pine (rosepinetheme.com): Dawn for light, Main for dark.
        case (.rosePine, false):
            return .derived(dark: false, paper: hex(0xFAF4ED), chrome: hex(0xF2E9E1), well: hex(0xFFFAF3),
                            frame: hex(0xCECACD), ink: hex(0x575279), secondary: hex(0x797593), tertiary: hex(0x9893A5),
                            selection: hex(0xDFDAD9), accent: hex(0xD7827E),
                            green: hex(0x286983), red: hex(0xB4637A), yellow: hex(0xEA9D34))
        case (.rosePine, true):
            return .derived(dark: true, paper: hex(0x191724), chrome: hex(0x26233A), well: hex(0x1F1D2E),
                            frame: hex(0x524F67), ink: hex(0xE0DEF4), secondary: hex(0x908CAA), tertiary: hex(0x6E6A86),
                            selection: hex(0x403D52), accent: hex(0xEBBCBA),
                            green: hex(0x9CCFD8), red: hex(0xEB6F92), yellow: hex(0xF6C177))

        // Tokyo Night (github.com/enkia/tokyo-night-vscode-theme): Light and Night.
        case (.tokyoNight, false):
            return .derived(dark: false, paper: hex(0xE6E7ED), chrome: hex(0xD6D8DF), well: hex(0xE6E7ED),
                            frame: hex(0xC1C2C7), ink: hex(0x343B58), secondary: hex(0x40434F), tertiary: hex(0x6C6E75),
                            selection: hex(0xDCDEE3), accent: hex(0x2959AA),
                            green: hex(0x385F0D), red: hex(0x8C4351), yellow: hex(0x8F5E15))
        case (.tokyoNight, true):
            return .derived(dark: true, paper: hex(0x1A1B26), chrome: hex(0x16161E), well: hex(0x1A1B26),
                            frame: hex(0x292E42), ink: hex(0xC0CAF5), secondary: hex(0xA9B1D6), tertiary: hex(0x565F89),
                            selection: hex(0x292E42), accent: hex(0x7AA2F7),
                            green: hex(0x9ECE6A), red: hex(0xF7768E), yellow: hex(0xE0AF68))

        // Everforest (github.com/sainnhe/everforest): medium contrast, light and dark.
        case (.everforest, false):
            return .derived(dark: false, paper: hex(0xFDF6E3), chrome: hex(0xEFEBD4), well: hex(0xFDF6E3),
                            frame: hex(0xE0DCC7), ink: hex(0x5C6A72), secondary: hex(0x829181), tertiary: hex(0x939F91),
                            selection: hex(0xE6E2CC), accent: hex(0x8DA101),
                            green: hex(0x35A77C), red: hex(0xF85552), yellow: hex(0xDFA000))
        case (.everforest, true):
            return .derived(dark: true, paper: hex(0x2D353B), chrome: hex(0x232A2E), well: hex(0x2D353B),
                            frame: hex(0x475258), ink: hex(0xD3C6AA), secondary: hex(0x9DA9A0), tertiary: hex(0x859289),
                            selection: hex(0x3D484D), accent: hex(0xA7C080),
                            green: hex(0x83C092), red: hex(0xE67E80), yellow: hex(0xDBBC7F))

        // One (github.com/atom/one-light-syntax, one-dark-syntax): Atom's One Light and One Dark.
        case (.oneDark, false):
            return .derived(dark: false, paper: hex(0xFAFAFA), chrome: hex(0xEAEAEB), well: hex(0xFAFAFA),
                            frame: hex(0xDBDBDC), ink: hex(0x383A42), secondary: hex(0x696C77), tertiary: hex(0xA0A1A7),
                            selection: hex(0xE5E5E6), accent: hex(0x4078F2),
                            green: hex(0x50A14F), red: hex(0xE45649), yellow: hex(0xC18401))
        case (.oneDark, true):
            return .derived(dark: true, paper: hex(0x282C34), chrome: hex(0x21252B), well: hex(0x282C34),
                            frame: hex(0x3E4451), ink: hex(0xABB2BF), secondary: hex(0x828997), tertiary: hex(0x5C6370),
                            selection: hex(0x3E4451), accent: hex(0x61AFEF),
                            green: hex(0x98C379), red: hex(0xE06C75), yellow: hex(0xE5C07B))

        // GitHub (primer.style/primitives): Light default and Dark default.
        case (.github, false):
            return .derived(dark: false, paper: hex(0xFFFFFF), chrome: hex(0xF6F8FA), well: hex(0xFFFFFF),
                            frame: hex(0xD0D7DE), ink: hex(0x1F2328), secondary: hex(0x656D76), tertiary: hex(0x6E7781),
                            selection: hex(0xEAEEF2), accent: hex(0x0969DA),
                            green: hex(0x1A7F37), red: hex(0xCF222E), yellow: hex(0x9A6700))
        case (.github, true):
            return .derived(dark: true, paper: hex(0x0D1117), chrome: hex(0x161B22), well: hex(0x0D1117),
                            frame: hex(0x30363D), ink: hex(0xE6EDF3), secondary: hex(0x7D8590), tertiary: hex(0x6E7681),
                            selection: hex(0x21262D), accent: hex(0x2F81F7),
                            green: hex(0x3FB950), red: hex(0xF85149), yellow: hex(0xD29922))

        // Flexoki (stephango.com/flexoki, Steph Ango): paper and black, its 600 and 400 accents.
        case (.flexoki, false):
            return .derived(dark: false, paper: hex(0xFFFCF0), chrome: hex(0xF2F0E5), well: hex(0xFFFCF0),
                            frame: hex(0xDAD8CE), ink: hex(0x100F0F), secondary: hex(0x6F6E69), tertiary: hex(0x878580),
                            selection: hex(0xE6E4D9), accent: hex(0xBC5215),
                            green: hex(0x66800B), red: hex(0xAF3029), yellow: hex(0xAD8301))
        case (.flexoki, true):
            return .derived(dark: true, paper: hex(0x100F0F), chrome: hex(0x1C1B1A), well: hex(0x100F0F),
                            frame: hex(0x343331), ink: hex(0xCECDC3), secondary: hex(0x878580), tertiary: hex(0x6F6E69),
                            selection: hex(0x282726), accent: hex(0xDA702C),
                            green: hex(0x879A39), red: hex(0xD14D41), yellow: hex(0xD0A215))

        // Kanagawa (github.com/rebelot/kanagawa.nvim): Lotus for light, Wave for dark.
        case (.kanagawa, false):
            return .derived(dark: false, paper: hex(0xF2ECBC), chrome: hex(0xE5DDB0), well: hex(0xF2ECBC),
                            frame: hex(0xDCD5AC), ink: hex(0x545464), secondary: hex(0x716E61), tertiary: hex(0x8A8980),
                            selection: hex(0xE7DBA0), accent: hex(0x4D699B),
                            green: hex(0x6F894E), red: hex(0xC84053), yellow: hex(0xCC6D00))
        case (.kanagawa, true):
            return .derived(dark: true, paper: hex(0x1F1F28), chrome: hex(0x16161D), well: hex(0x1F1F28),
                            frame: hex(0x363646), ink: hex(0xDCD7BA), secondary: hex(0xC8C093), tertiary: hex(0x727169),
                            selection: hex(0x2D4F67), accent: hex(0x7E9CD8),
                            green: hex(0x98BB6C), red: hex(0xE46876), yellow: hex(0xE6C384))

        // Ayu (github.com/ayu-theme/ayu-colors): Light and Mirage.
        case (.ayu, false):
            // Its text and selection are colours over the page at part strength; these are
            // the colours they make there.
            let page = hex(0xFCFCFC), text = hex(0x5C6166)
            return .derived(dark: false, paper: page, chrome: hex(0xF8F9FA), well: page,
                            frame: hex(0xE0E4E7), ink: text, secondary: mix(text, page, 0.25), tertiary: hex(0xADAEB1),
                            selection: hex(0xD7E4F6), accent: hex(0xF29718),
                            green: hex(0x86B300), red: hex(0xE65050), yellow: hex(0xEBA400))
        case (.ayu, true):
            let page = hex(0x242936), text = hex(0xCCCAC2)
            return .derived(dark: true, paper: page, chrome: hex(0x1F2430), well: page,
                            frame: hex(0x171B24), ink: text, secondary: mix(text, page, 0.25), tertiary: hex(0x6E7C8F),
                            selection: hex(0x2B4768), accent: hex(0xFFCC66),
                            green: hex(0xD5FF80), red: hex(0xFF6666), yellow: hex(0xFFCD66))

        // Night Owl (github.com/sdras/night-owl-vscode-theme, Sarah Drasner): Light Owl and Night Owl.
        case (.nightOwl, false):
            let page = hex(0xFBFBFB), text = hex(0x403F53)
            return .derived(dark: false, paper: page, chrome: hex(0xF0F0F0), well: page,
                            frame: hex(0xD9D9D9), ink: text, secondary: mix(text, page, 0.25), tertiary: hex(0x989FB1),
                            selection: hex(0xE0E0E0), accent: hex(0x4876D6),
                            green: hex(0x08916A), red: hex(0xE64D49), yellow: hex(0xE0AF02))
        case (.nightOwl, true):
            // Its sidebar is the page's own colour: the window's band is set a little toward its border.
            let night = hex(0x011627), text = hex(0xD6DEEB), border = hex(0x122D42)
            return .derived(dark: true, paper: night, chrome: mix(night, border, 0.5), well: night,
                            frame: border, ink: text, secondary: mix(text, night, 0.3), tertiary: hex(0x637777),
                            selection: hex(0x1D3B53), accent: hex(0x82AAFF),
                            green: hex(0x22DA6E), red: hex(0xEF5350), yellow: hex(0xFFCB8B))

        // Tomorrow (github.com/chriskempson/tomorrow-theme, Chris Kempson): Tomorrow and Tomorrow Night.
        case (.tomorrow, false):
            let page = hex(0xFFFFFF), text = hex(0x4D4D4C)
            return .derived(dark: false, paper: page, chrome: hex(0xEFEFEF), well: page,
                            frame: hex(0xD6D6D6), ink: text, secondary: mix(text, hex(0x8E908C), 0.5), tertiary: hex(0x8E908C),
                            selection: hex(0xD6D6D6), accent: hex(0x4271AE),
                            green: hex(0x718C00), red: hex(0xC82829), yellow: hex(0xEAB700))
        case (.tomorrow, true):
            return .derived(dark: true, paper: hex(0x1D1F21), chrome: hex(0x282A2E), well: hex(0x1D1F21),
                            frame: hex(0x373B41), ink: hex(0xC5C8C6), secondary: hex(0x969896), tertiary: mix(hex(0x969896), hex(0x1D1F21), 0.2),
                            selection: hex(0x373B41), accent: hex(0x81A2BE),
                            green: hex(0xB5BD68), red: hex(0xCC6666), yellow: hex(0xF0C674))

        // Electric Sheep: "Replicant" by Kenzie Bottoms, a Blade Runner editor theme
        // (github.com/kenziebottoms/vscode-theme-replicant). Dark only. No palette for the
        // novel itself was found; this is for its film.
        case (.electricSheep, _):
            let night = hex(0x00234A), text = hex(0xE7F7FF)
            return .derived(dark: true, paper: night, chrome: hex(0x092B51), well: night,
                            frame: mix(night, hex(0x5C7892), 0.55), ink: text, secondary: hex(0xA2B7C9), tertiary: hex(0x748DA5),
                            selection: mix(night, hex(0x2DBDE0), 0.22), accent: hex(0x72FFC6),
                            green: hex(0x0DB39D), red: hex(0xE180B8), yellow: hex(0x2DBDE0))

        // Area X: "annihilation cover II" by Clark Iroz on Adobe Color, the greens and the
        // pink of the paperback's cover; the white page is from his other version of it.
        case (.areaX, false):
            let page = hex(0xFDF7FF), khaki = hex(0xD1D1B1), forest = hex(0x0A3F30)
            return .derived(dark: false, paper: page, chrome: mix(page, khaki, 0.5), well: page,
                            frame: khaki, ink: forest, secondary: mix(forest, page, 0.3), tertiary: mix(forest, page, 0.45),
                            selection: mix(page, khaki, 0.75), accent: hex(0xFF4C98),
                            green: hex(0x61A540), red: hex(0xFF4C98), yellow: hex(0x535928))
        case (.areaX, true):
            let forest = hex(0x0A3F30), khaki = hex(0xD1D1B1)
            return .derived(dark: true, paper: forest, chrome: mix(forest, hex(0x535928), 0.2), well: forest,
                            frame: mix(forest, khaki, 0.25), ink: khaki, secondary: mix(khaki, forest, 0.25), tertiary: mix(khaki, forest, 0.45),
                            selection: mix(forest, hex(0x61A540), 0.25), accent: hex(0xFF4C98),
                            green: hex(0x61A540), red: hex(0xFF4C98), yellow: hex(0x535928))

        // 2001: "HAL 9000" by Steve Cooper on Adobe Color: the ship's white, the dark of
        // space, the console's blue and the red of HAL's eye.
        case (.odyssey, false):
            let white = hex(0xE8EDF3), space = hex(0x072936)
            return .derived(dark: false, paper: white, chrome: mix(white, space, 0.07), well: white,
                            frame: mix(white, space, 0.2), ink: space, secondary: mix(space, white, 0.3), tertiary: mix(space, white, 0.45),
                            selection: mix(white, hex(0x66ADD9), 0.3), accent: hex(0xCF330A),
                            green: hex(0x66ADD9), red: hex(0xCF330A), yellow: hex(0xE8654E))
        case (.odyssey, true):
            let white = hex(0xE8EDF3), space = hex(0x072936)
            return .derived(dark: true, paper: space, chrome: mix(space, white, 0.06), well: space,
                            frame: mix(space, white, 0.22), ink: white, secondary: mix(white, space, 0.25), tertiary: mix(white, space, 0.45),
                            selection: mix(space, hex(0x66ADD9), 0.25), accent: hex(0xE8654E),
                            green: hex(0x66ADD9), red: hex(0xCF330A), yellow: hex(0xE8654E))

        // Hail Mary: "Project Hail Mary" by Esther Jeninga on Adobe Color (charcoal, teal,
        // the cover's yellow, orange); it has no light colour, so the text is the lightest of
        // "project Hail Mary Desperation" by Loredana Conte. Dark only.
        case (.hailMary, _):
            let charcoal = hex(0x222626), text = hex(0xF2B47E), teal = hex(0x254746)
            return .derived(dark: true, paper: charcoal, chrome: mix(charcoal, teal, 0.4), well: charcoal,
                            frame: mix(charcoal, hex(0x428C77), 0.35), ink: text, secondary: mix(text, charcoal, 0.25), tertiary: mix(text, charcoal, 0.45),
                            selection: teal, accent: hex(0xFCD548),
                            green: hex(0x428C77), red: hex(0xF25A38), yellow: hex(0xFCD548))
        }
    }

    /// Longhand's own colours, tuned by hand (docs/DESIGN.md › Colour).
    private static let paperLight = Palette(
        dark: false,
        paper: rgb(251, 250, 245), chrome: rgb(239, 237, 230), well: rgb(255, 255, 255), frame: rgb(214, 211, 200),
        controlFill: rgb(251, 250, 245), controlBorder: rgb(201, 198, 187), controlOn: rgb(228, 225, 215), controlOnBorder: rgb(168, 165, 154),
        commentFocus: rgb(251, 246, 226),
        ink: rgb(42, 40, 37), secondary: rgb(107, 105, 98), tertiary: rgb(122, 120, 113),
        hairline: rgb(226, 224, 215), selection: rgb(230, 227, 217), hover: rgb(244, 242, 235),
        card: rgb(255, 255, 255), cardBorder: rgb(214, 211, 200),
        highlight: rgb(247, 238, 203), highlightFocus: rgb(242, 223, 150),
        accent: rgb(163, 36, 26),
        diffAddedRow: rgb(232, 245, 233), diffAddedWord: rgb(184, 226, 189), diffAddedMark: rgb(34, 120, 52),
        diffRemovedRow: rgb(252, 234, 232), diffRemovedWord: rgb(246, 196, 191), diffRemovedMark: rgb(180, 40, 32),
        diffChangedMark: rgb(176, 122, 22)
    )

    private static let paperDark = Palette(
        dark: true,
        paper: rgb(30, 30, 28), chrome: rgb(40, 40, 37), well: rgb(31, 31, 29), frame: rgb(58, 57, 53),
        controlFill: rgb(50, 50, 47), controlBorder: rgb(72, 71, 66), controlOn: rgb(66, 65, 61), controlOnBorder: rgb(98, 96, 90),
        commentFocus: rgb(50, 45, 30),
        ink: rgb(218, 215, 206), secondary: rgb(156, 154, 146), tertiary: rgb(142, 140, 131),
        hairline: rgb(48, 47, 44), selection: rgb(48, 47, 44), hover: rgb(37, 37, 35),
        card: rgb(36, 36, 34), cardBorder: rgb(58, 57, 53),
        highlight: rgb(58, 51, 32), highlightFocus: rgb(84, 70, 30),
        accent: rgb(224, 112, 95),
        diffAddedRow: rgb(28, 48, 33), diffAddedWord: rgb(36, 89, 49), diffAddedMark: rgb(120, 200, 132),
        diffRemovedRow: rgb(56, 30, 29), diffRemovedWord: rgb(112, 42, 38), diffRemovedMark: rgb(236, 124, 112),
        diffChangedMark: rgb(214, 168, 80)
    )
}

/// The theme on screen, for the window to be drawn again when it changes (a choice or a
/// preview). Only the window's root watches it.
@MainActor
final class ThemeState: ObservableObject {
    static let shared = ThemeState()
    @Published var shown: AppTheme = AppTheme.current
}

extension Palette {
    /// A whole palette from a theme's own handful of colours.
    static func derived(dark: Bool, paper: NSColor, chrome: NSColor, well: NSColor, frame: NSColor,
                        ink: NSColor, secondary: NSColor, tertiary: NSColor, selection: NSColor,
                        accent: NSColor, green: NSColor, red: NSColor, yellow: NSColor) -> Palette {
        // Words must stay easy to read: 4.5:1 for secondary text, 3:1 for marks and hints.
        let secondary = readable(secondary, on: well, toward: ink, at: 4.5)
        let tertiary = readable(tertiary, on: well, toward: ink, at: 3.2)
        let green = readable(green, on: well, toward: ink, at: 3)
        let red = readable(red, on: well, toward: ink, at: 3)
        let yellow = readable(yellow, on: well, toward: ink, at: 2.6)
        let rows = dark ? 0.16 : 0.13, words = dark ? 0.34 : 0.32
        return Palette(
            dark: dark,
            paper: paper, chrome: chrome, well: well, frame: frame,
            controlFill: dark ? mix(well, ink, 0.05) : mix(well, chrome, 0.3),
            controlBorder: frame,
            controlOn: selection,
            controlOnBorder: mix(frame, ink, 0.3),
            commentFocus: mix(well, yellow, dark ? 0.12 : 0.14),
            ink: ink, secondary: secondary, tertiary: tertiary,
            hairline: mix(frame, well, 0.45), selection: selection, hover: mix(well, selection, 0.5),
            card: well, cardBorder: frame,
            highlight: mix(paper, yellow, dark ? 0.2 : 0.24), highlightFocus: mix(paper, yellow, dark ? 0.36 : 0.45),
            accent: accent,
            diffAddedRow: mix(paper, green, rows), diffAddedWord: mix(paper, green, words), diffAddedMark: green,
            diffRemovedRow: mix(paper, red, rows), diffRemovedWord: mix(paper, red, words), diffRemovedMark: red,
            diffChangedMark: yellow
        )
    }
}

// MARK: - Colour arithmetic

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

private func hex(_ value: Int) -> NSColor {
    rgb((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
}

/// `a` moved `t` of the way toward `b`, in sRGB.
func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
    return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                   green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                   blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t,
                   alpha: 1)
}

/// WCAG contrast between two opaque colours.
func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    let x = luminance(a), y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// The colour itself if it reads well enough on `background`, else moved toward `ink` until it does.
private func readable(_ color: NSColor, on background: NSColor, toward ink: NSColor, at minimum: CGFloat) -> NSColor {
    var step: CGFloat = 0
    var result = color
    while contrast(result, background) < minimum, step < 1 {
        step += 0.05
        result = mix(color, ink, step)
    }
    return result
}
