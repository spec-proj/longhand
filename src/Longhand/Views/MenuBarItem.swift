import AppKit

/// Longhand in the Mac's menu bar (owner, 2026-11-14: "it should just toggle the window upon
/// click"): the app icon's book, drawn as a template so it takes the menu bar's own colour. A
/// click brings the window forward, or hides Longhand when it is already in front. No menu.
/// Hidden in Settings › Appearance; never put in the menu bar by hidden test runs.
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
                button.action = #selector(toggle)
            }
            self.item = item
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Longhand in front with a window showing: hide it. Otherwise bring the window forward
    /// (out of the Dock if it was minimised), or open one if it was closed. Clicking the menu
    /// bar doesn't make Longhand active, so "in front" is as it was before the click.
    @objc private func toggle() {
        let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }
        if NSApp.isActive, !NSApp.isHidden, windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) {
            NSApp.hide(nil)
            return
        }
        NSApp.unhide(nil)
        NSApp.activate()
        if let window = windows.first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
    }
}
