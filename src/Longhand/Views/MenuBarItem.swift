import AppKit

/// Longhand in the Mac's menu bar (owner, 2026-11-14): the app icon's book, drawn as a template
/// so it takes the menu bar's own colour. A click brings the window forward, or hides Longhand
/// when it is already in front ("it should just toggle the window upon click"); a right-click
/// (or Control-click) shows the menu it always had: where the library stands with Git, the
/// open story, Continue, Commit, Push, Show, Settings and Quit. Hidden in Settings ›
/// Appearance; never put in the menu bar by hidden test runs.
@MainActor
final class MenuBarItem: NSObject {
    static let shared = MenuBarItem()
    static let key = "showMenuBarItem"

    /// Opens a new main window when every window was closed (SwiftUI's `openWindow`, handed
    /// over by the window's content).
    var openWindow: (() -> Void)?

    private var item: NSStatusItem?
    private var observer: NSObjectProtocol?

    private var wanted: Bool { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }

    func start() {
        guard !Snapshot.isBackgroundRun, observer == nil else { return }
        update()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// Puts the item in the menu bar, or takes it out, as the setting says.
    private func update() {
        if wanted, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let image = NSImage(named: "MenuBarIcon")
                image?.isTemplate = true
                button.image = image
                button.toolTip = "Show or hide Longhand"
                button.setAccessibilityLabel("Longhand")
                button.target = self
                button.action = #selector(clicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            self.item = item
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    private var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }
    }

    /// Longhand in front with a window showing: hide it. Otherwise bring the window forward
    /// (out of the Dock if it was minimised), or open one if it was closed. Clicking the menu
    /// bar doesn't make Longhand active, so "in front" is as it was before the click.
    private func toggle() {
        let windows = mainWindows
        if NSApp.isActive, !NSApp.isHidden, windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) {
            NSApp.hide(nil)
            return
        }
        show()
    }

    private func show() {
        NSApp.unhide(nil)
        NSApp.activate()
        if let window = mainWindows.first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        // No window: waking Longhand can make SwiftUI open one by itself. Look again a moment
        // later and open one only if it didn't, so a click never leaves two windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if let window = self.mainWindows.first {
                window.makeKeyAndOrderFront(nil)
            } else {
                self.openWindow?()
            }
        }
    }

    // MARK: - The right-click menu

    private func showMenu() {
        guard let item else { return }
        item.menu = makeMenu()
        item.button?.performClick(nil)   // opens the menu under the item
        item.menu = nil                   // so the next left click toggles again
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled && action != nil
            menu.addItem(entry)
        }
        menu.autoenablesItems = false
        if let store = LonghandAppDelegate.store, let library = store.library {
            let changes = store.versions.changes
            let line = store.versions.sync.line(hasRemote: changes.backup != .none, unpushed: changes.backup == .behind)
            add(line.text, nil, enabled: false)
            if let book = Exporter.book(in: store) {
                let progress = store.targetProgress(of: book)
                add("\(book.title) · \(progress.done.formatted()) \(progress.unit)", nil, enabled: false)
            }
            if case .scene(let url) = store.selection, let scene = store.scene(for: url) {
                add("Continue “\(scene.title)”", #selector(showWindow))
            }
            menu.addItem(.separator())
            add("Commit", #selector(commit))
            add("Push", #selector(push), enabled: changes.backup != .none)
            menu.addItem(.separator())
            add("Show \(library.name)", #selector(showWindow))
        } else {
            add("Open Longhand", #selector(showWindow))
        }
        if let release = Updates.shared.available {
            menu.addItem(.separator())
            add("Download Longhand \(release.version)…", #selector(downloadUpdate))
        }
        menu.addItem(.separator())
        add("Settings…", #selector(settings))
        add("Quit Longhand", #selector(quit))
        return menu
    }

    @objc private func showWindow() { show() }
    @objc private func commit() { LonghandAppDelegate.store?.versions.commitNow(push: false) }
    @objc private func push() { LonghandAppDelegate.store?.versions.commitAndPush() }
    @objc private func settings() {
        NSApp.activate()
        Commands.openSettings()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func downloadUpdate() { Updates.shared.download() }
}
