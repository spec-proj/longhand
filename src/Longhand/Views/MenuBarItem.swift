import SwiftUI
import AppKit

/// Longhand in the Mac's menu bar (owner, 2026-11-13): where the library stands with Git, the
/// open story, a way back to the scene you were writing, Commit and Push, and the window.
/// Hidden in Settings › Appearance; never shown by hidden test runs.
struct MenuBarMenu: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var sync: SyncStatus
    @ObservedObject var changes: ChangeState
    @Environment(\.openWindow) private var openWindow

    static let key = "showMenuBarItem"

    var body: some View {
        if let library = store.library {
            let line = sync.line(hasRemote: changes.backup != .none, unpushed: changes.backup == .behind)
            Text(line.text)
            if let book = Exporter.book(in: store) {
                Text("\(book.title) · \(Estimate.words(store.wordCount(of: book)))")
            }
            if case .scene(let url) = store.selection, let scene = store.scene(for: url) {
                Button("Continue “\(scene.title)”") { show() }
            }
            Divider()
            Button("Commit") { store.versions.commitNow(push: false) }
                .help("Commit any changes now")
            Button("Push") { store.versions.commitAndPush() }
                .disabled(changes.backup == .none)
                .help("Commit any changes, then push to \(sync.place)")
            Divider()
            Button("Show \(library.name)") { show() }
        } else {
            Button("Open Longhand") { show() }
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Longhand") { NSApp.terminate(nil) }
    }

    /// Brings the window forward, opening one if it was closed.
    private func show() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
