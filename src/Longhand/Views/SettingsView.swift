import SwiftUI

/// Longhand › Settings… (⌘,): three short panes, chosen at the top. Appearance (theme, light
/// or dark), Editor (the page's type and the writing modes), Backup (GitHub). The window is as tall
/// as the pane; a pane's name is not repeated as a heading inside it. `LONGHAND_SETTINGS_PANE` picks one for a picture.
struct SettingsView: View {
    @AppStorage(AppTheme.defaultsKey) private var theme = AppTheme.paper.rawValue
    @AppStorage(AppTheme.modeKey) private var mode = "system"
    @AppStorage(ProseFace.defaultsKey) private var proseFace = ProseFace.sfPro.rawValue
    @AppStorage(ProseSize.defaultsKey) private var proseSize = 0
    @AppStorage(MenuBarItem.key) private var showMenuBarItem = true
    @AppStorage(Updates.key) private var checkForUpdates = true
    @AppStorage(WritingModes.focusKey) private var focus = false
    @AppStorage(WritingModes.unitKey) private var focusUnit = WritingModes.Unit.sentence.rawValue
    @AppStorage(WritingModes.typewriterKey) private var typewriter = false
    @AppStorage(StatusBar.countKey) private var showCount = true
    @AppStorage(Places.settingKey) private var rememberPlace = true

    /// The open library's versions, for the Backup section (nil in a bare preview).
    var versions: VersionStore?
    @State private var pane = ProcessInfo.processInfo.environment["LONGHAND_SETTINGS_PANE"] ?? SettingsView.wanted ?? "appearance"

    /// The pane to show when Settings next opens (or now, if it is open).
    static var wanted: String?
    static let paneChange = Notification.Name("LonghandSettingsPane")

    /// Opens Settings on a pane, e.g. from a story's page to edit authors.
    @MainActor
    static func open(pane: String) {
        wanted = pane
        NotificationCenter.default.post(name: paneChange, object: pane)
        Commands.openSettings()
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Segments(options: [("appearance", "Appearance"), ("editor", "Editor"), ("authors", "Authors"), ("backup", "Git")], value: $pane)
                .frame(maxWidth: .infinity)

            if pane == "appearance" {
            section("Mode") {
                Segments(options: [("system", "System"), ("light", "Light"), ("dark", "Dark")], value: $mode)
                    .disabled(AppTheme(rawValue: theme)?.darkOnly == true)
                    .onChange(of: mode) { AppTheme.applyAppearance() }
            }

            section("Theme") {
                // A drop-down (owner, 2026-11-13): each theme with a strip of its colours.
                ThemeMenu(theme: AppTheme(rawValue: theme) ?? .paper, dark: scheme == .dark)
            }

            section("Menu bar") {
                SquareCheckbox(title: "Show Longhand in the menu bar", isOn: $showMenuBarItem)
                    .help("A click shows or hides the window; right-click for Git status, Commit and Push")
            }

            section("Updates") {
                SquareCheckbox(title: "Check for new versions", isOn: $checkForUpdates)
                    .help("Once a day Longhand asks GitHub for its latest release, and says in the status bar if there is a newer one. Nothing is downloaded by itself.")
            }
            }

            if pane == "editor" {
            VStack(alignment: .leading, spacing: 10) {
                row("Font") {
                    Segments(options: ProseFace.allCases.map { ($0.rawValue, $0.title) }, value: $proseFace)
                }
                row("Text size") {
                    HStack(spacing: 6) {
                        Button("Smaller") { ProseSize.step(-1) }
                            .disabled(proseSize <= ProseSize.range.lowerBound)
                        Text("\(Int(ProseFace(rawValue: proseFace)?.size ?? 17)) pt")
                            .font(.system(size: Layout.chromeSize).monospacedDigit())
                            .foregroundStyle(Color(PaperTheme.secondary))
                            .frame(width: 44)
                        Button("Bigger") { ProseSize.step(1) }
                            .disabled(proseSize >= ProseSize.range.upperBound)
                        Button("Actual Size") { ProseSize.step(0) }
                            .disabled(proseSize == 0)
                    }
                    .buttonStyle(FramedButtonStyle())
                }
                row("Focus") {
                    HStack(spacing: 10) {
                        SquareCheckbox(title: "", isOn: $focus)
                            .accessibilityLabel("Focus")
                        Segments(options: WritingModes.Unit.allCases.map { ($0.rawValue, $0.title) }, value: $focusUnit)
                    }
                }
                row("Typewriter scrolling") {
                    SquareCheckbox(title: "", isOn: $typewriter)
                        .accessibilityLabel("Typewriter scrolling")
                }
                // One name per row and a plain checkbox: nothing said twice.
                row("Reopen last scene") {
                    SquareCheckbox(title: "", isOn: $rememberPlace)
                        .accessibilityLabel("Reopen last scene")
                }
                row("Word count") {
                    SquareCheckbox(title: "", isOn: $showCount)
                        .accessibilityLabel("Word count")
                }
            }
            }

            if pane == "authors" { AuthorSettings() }

            if pane == "backup" {
                if let versions { BackupSettings(versions: versions) }
            }
        }
        .font(.system(size: Layout.chromeSize))
        .foregroundStyle(Color(PaperTheme.ink))
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(PaperTheme.chrome))
        .onReceive(NotificationCenter.default.publisher(for: SettingsView.paneChange)) { note in
            if let wanted = note.object as? String { pane = wanted }
        }
        .id(theme)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        // Every row the same height, whatever it holds, so the labels sit on an even grid.
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .foregroundStyle(Color(PaperTheme.secondary))
                .frame(width: 150, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: Layout.controlHeight + 2)
    }
}

/// Settings › Authors: the authors set up on this Mac. A story's page picks one; changing
/// an author here changes every story that uses it.
private struct AuthorSettings: View {
    @ObservedObject private var authors = AuthorProfiles.shared
    @State private var chosen: String?
    @State private var draft = AuthorProfile()

    private var current: AuthorProfile? { authors.profile(chosen) ?? authors.all.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                // Side by side while they fit; from four on, a pop-up (owner, 2026-11-14:
                // more ran off the window).
                if authors.all.count > 3 {
                    Menu {
                        ForEach(authors.all) { profile in
                            Toggle(profile.title, isOn: Binding(get: { profile.id == current?.id }, set: { if $0 { choose(profile.id) } }))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(current?.title ?? "")
                                .foregroundStyle(Color(PaperTheme.ink))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(PaperTheme.secondary))
                        }
                        .font(.system(size: Layout.chromeSize))
                        .padding(.horizontal, 8)
                        .frame(width: 240, height: 26)
                        .background(Color(PaperTheme.paper), in: rounded())
                        .overlay(rounded().strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                } else if authors.all.count > 1 {
                    Segments(options: authors.all.map { ($0.id, $0.title) },
                             value: Binding(get: { current?.id ?? "" }, set: { choose($0) }))
                }
                Spacer(minLength: 0)
                Button("New Author") { choose(authors.add().id) }
                if let current {
                    Button("Remove") {
                        authors.remove(current.id)
                        choose(authors.all.first?.id)
                    }
                    .help("Stories already using this author keep their details")
                }
            }
            .buttonStyle(FramedButtonStyle())

            if current != nil {
                VStack(alignment: .leading, spacing: 10) {
                    field("Name", \.name)
                    field("Pen name", \.penName)
                    field("Address", \.address, lines: 3)
                    field("Email", \.email)
                    field("Phone", \.phone)
                    field("Previous works", \.previousWorks, lines: 4)
                }
            } else {
                Text("No authors yet")
                    .foregroundStyle(Color(PaperTheme.secondary))
            }
        }
        .onAppear { choose(current?.id) }
        .onChange(of: draft) { _, value in if value.id == current?.id { authors.update(value) } }
    }

    private func choose(_ id: String?) {
        chosen = id
        if let profile = authors.profile(id) { draft = profile }
    }

    private func field(_ title: String, _ path: WritableKeyPath<AuthorProfile, String>, lines: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(Color(PaperTheme.secondary))
                .frame(width: 150, alignment: .leading)
            TextField("", text: Binding(get: { draft[keyPath: path] }, set: { draft[keyPath: path] = $0 }),
                      prompt: nil, axis: lines > 1 ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .lineLimit(lines > 1 ? 2...lines : 1...1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(PaperTheme.card), in: rounded())
                .roundedFrame(Color(PaperTheme.controlBorder))
        }
    }
}

/// Settings › Git: commit and push by themselves, and where this library is pushed (GitHub,
/// another remote, or a folder). Read from what the versions store already knows; nothing is asked of GitHub.
private struct BackupSettings: View {
    @ObservedObject var versions: VersionStore

    /// ("spec-proj", "my-novel") from `https://github.com/spec-proj/my-novel`.
    private var place: (account: String, repository: String)? {
        // Dev switch for pictures: the connected state without a real backup.
        if ProcessInfo.processInfo.environment["LONGHAND_BACKUP_DEMO"] == "1" { return ("spec-proj", "writing") }
        guard let page = versions.backupPage, let url = URL(string: page) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        return parts.count >= 2 ? (parts[0], parts[1]) : nil
    }

    @AppStorage(VersionStore.autoCommitKey) private var autoCommit = true
    @AppStorage(VersionStore.autoPushKey) private var autoPush = true

    /// Commit and push by themselves, said once, above whatever the repository's state is.
    private var automatic: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Commit")
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .frame(width: 150, alignment: .leading)
                SquareCheckbox(title: "Automatically", isOn: $autoCommit)
                    .help("Commits 30 seconds after you stop typing. When off, Longhand commits only when you choose Commit or quit.")
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Push")
                    .foregroundStyle(Color(PaperTheme.secondary))
                    .frame(width: 150, alignment: .leading)
                SquareCheckbox(title: "Automatically", isOn: $autoPush)
                    .help("Pushes after every commit. When off, Longhand pushes only when you choose Push or quit.")
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            automatic
            if !versions.available {
                line("Remote", "Open a library to see its repository")
            } else if let place {
                // Said once each: the state with its dot, then where it goes (account / library,
                // both open on GitHub), then when it last went and the button to send it now.
                HStack(alignment: .center, spacing: 12) {
                    Text("GitHub")
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .frame(width: 150, alignment: .leading)
                    Circle()
                        .fill(Color(versions.backupFailed ? PaperTheme.accent : PaperTheme.diffAddedMark))
                        .frame(width: 8, height: 8)
                    Text(versions.backupFailed ? "The last push failed" : "Connected")
                        .foregroundStyle(Color(versions.backupFailed ? PaperTheme.accent : PaperTheme.ink))
                        .padding(.leading, -6)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    GitHubMark(size: 14)
                        .foregroundStyle(Color(PaperTheme.ink))
                    Button(place.account) { open("https://github.com/\(place.account)") }
                        .help("Show this account on GitHub")
                    Text("/")
                        .foregroundStyle(Color(PaperTheme.secondary))
                    Button(place.repository) { if let page = versions.backupPage { open(page) } }
                        .help("View this repository on GitHub")
                }
                .buttonStyle(FramedButtonStyle())
                .padding(.leading, 162)
                actions {
                    Button("Activity…") {
                        versions.sheet = .backup
                        NSApp.windows.first { $0.isMainWindow || $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                    }
                    .help("Recent commits, pushes and fetches")
                }
            } else if versions.hasBackup {
                // Another remote (not GitHub): its state with the dot, then its address.
                HStack(alignment: .center, spacing: 12) {
                    Text("Remote")
                        .foregroundStyle(Color(PaperTheme.secondary))
                        .frame(width: 150, alignment: .leading)
                    Circle()
                        .fill(Color(versions.backupFailed ? PaperTheme.accent : PaperTheme.diffAddedMark))
                        .frame(width: 8, height: 8)
                    Text(versions.backupFailed ? "The last push failed" : "Connected")
                        .foregroundStyle(Color(versions.backupFailed ? PaperTheme.accent : PaperTheme.ink))
                        .padding(.leading, -6)
                    Spacer(minLength: 0)
                }
                if let address = versions.remoteAddress {
                    Text(address)
                        .font(.system(size: Layout.chromeSize).monospaced())
                        .foregroundStyle(Color(PaperTheme.ink))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 162)
                        .help(address)
                    if Git.isFolder(address) {
                        actions {
                            Button("Show in Finder") {
                                let path = address.hasPrefix("file://") ? (URL(string: address)?.path ?? address) : address
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .help("Show the repository’s folder")
                        }
                    }
                }
                actions {
                    Button("Activity…") {
                        versions.sheet = .backup
                        NSApp.windows.first { $0.isMainWindow || $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                    }
                }
            } else {
                line("Remote", "Only on this Mac")
                actions {
                    Button {
                        versions.sheet = .backup
                        NSApp.windows.first { $0.isMainWindow || $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                    } label: {
                        Text("Connect Repository…")
                    }
                }
            }
        }
    }

    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    private func line(_ title: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(Color(PaperTheme.secondary))
                .frame(width: 150, alignment: .leading)
            Text(value)
                .foregroundStyle(Color(warn ? PaperTheme.accent : PaperTheme.ink))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func actions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .buttonStyle(FramedButtonStyle())
            .padding(.leading, 162)
    }
}

/// The theme as a pop-up menu: the chosen one's colours and name. The menu is the Mac's own
/// (so each theme shows its strip of colours), grouped Longhand, Editor Themes, From Novels;
/// the window behind shows each theme as the pointer passes over it, and goes back if none is
/// chosen.
private struct ThemeMenu: View {
    let theme: AppTheme
    let dark: Bool
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button { ThemeMenuController.shared.show(from: anchor.view, current: theme, dark: dark) } label: {
            HStack(spacing: 10) {
                Image(nsImage: ThemeStrip.image(theme, dark: dark))
                Text(theme.title)
                    .foregroundStyle(Color(PaperTheme.ink))
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(PaperTheme.secondary))
            }
            .padding(.horizontal, 8)
            .frame(width: 260, height: Layout.controlHeight)
            .background(Color(PaperTheme.card), in: rounded())
            .roundedFrame(Color(PaperTheme.controlBorder))
            .contentShape(Rectangle())
            .background(AnchorView(anchor: anchor))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Where a menu opens from: the AppKit view behind a SwiftUI control.
final class MenuAnchor {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// Builds and runs the theme menu; as its delegate, previews the theme under the pointer.
@MainActor
final class ThemeMenuController: NSObject, NSMenuDelegate {
    static let shared = ThemeMenuController()
    private var chosen = false

    func show(from view: NSView?, current: AppTheme, dark: Bool) {
        guard let view else { return }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        var currentItem: NSMenuItem?
        for (index, family) in AppTheme.Family.allCases.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: family.rawValue))
            for theme in AppTheme.members(of: family) {
                let item = NSMenuItem(title: theme.darkOnly ? "\(theme.title) (dark only)" : theme.title,
                                      action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = theme.rawValue
                item.image = ThemeStrip.image(theme, dark: dark)
                item.state = theme == current ? .on : .off
                if theme == current { currentItem = item }
                menu.addItem(item)
            }
        }
        chosen = false
        // Opens with the chosen theme over the control, as a pop-up button's menu does.
        menu.popUp(positioning: currentItem, at: NSPoint(x: 0, y: view.bounds.height - 2), in: view)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let theme = AppTheme(rawValue: raw) else { return }
        chosen = true
        AppTheme.choose(theme)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let raw = item?.representedObject as? String, let theme = AppTheme(rawValue: raw) else { return }
        AppTheme.preview(theme)
    }

    func menuDidClose(_ menu: NSMenu) {
        // The choice (if any) arrives after the menu closes: put the kept theme back only if
        // none came.
        DispatchQueue.main.async { [self] in
            if !chosen { AppTheme.endPreview() }
        }
    }
}

/// A theme's colours as a small strip picture (menus show pictures, not views).
enum ThemeStrip {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ theme: AppTheme, dark: Bool) -> NSImage {
        let key = "\(theme.rawValue)-\(dark)"
        if let made = cache[key] { return made }
        let colours = theme.swatch(dark: dark)
        let size = NSSize(width: 40, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let width = rect.width / CGFloat(colours.count)
            for (index, colour) in colours.enumerated() {
                colour.setFill()
                NSRect(x: CGFloat(index) * width, y: 0, width: width + 1, height: rect.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            PaperTheme.controlBorder.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return true
        }
        cache[key] = image
        return image
    }
}

/// A checkbox drawn to match the other controls, with an SF Symbol checkmark.
struct SquareCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 7) {
                ZStack {
                    rounded(Layout.smallRadius + 1).fill(Color(isOn ? PaperTheme.accent : PaperTheme.card))
                    rounded(Layout.smallRadius + 1).strokeBorder(Color(isOn ? PaperTheme.accent : PaperTheme.controlBorder), lineWidth: 1)
                    if isOn {
                        Symbol.checkmark.view(size: 11).foregroundStyle(Color(PaperTheme.card))
                    }
                }
                .frame(width: 14, height: 14)
                // No title when the row's own label already names it.
                if !title.isEmpty { Text(title).foregroundStyle(Color(PaperTheme.ink)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Square segments in one frame, the chosen one pressed in (as the margin's tabs).
struct Segments: View {
    let options: [(value: String, title: String)]
    @Binding var value: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Rectangle().fill(Color(PaperTheme.controlBorder)).frame(width: 1) }
                let selected = option.value == value
                Button { value = option.value } label: {
                    Text(option.title)
                        .fontWeight(selected ? .semibold : .medium)
                        .foregroundStyle(Color(selected ? PaperTheme.ink : PaperTheme.secondary))
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        .background(selected ? Color(PaperTheme.controlOn) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: Layout.chromeSize))
        .frame(height: Layout.controlHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(PaperTheme.controlFill))
        .roundedFrame(Color(PaperTheme.controlBorder), lineWidth: 1)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
