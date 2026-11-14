import SwiftUI
import AppKit

/// Quitting without seeming to freeze (owner, 2026-11-14): macOS is asked to wait while the
/// session is committed and pushed in the background; if that takes more than a moment, a
/// small card says what's happening ("Committing…", "Pushing to GitHub…"), and after a few
/// seconds of pushing offers Quit Now (the commit is already on this Mac).
final class LonghandAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `LonghandApp` as it starts.
    @MainActor static weak var store: LibraryStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard !Snapshot.isBackgroundRun, let store = Self.store, store.library != nil else { return .terminateNow }
            QuitProgress.shared.begin(store: store)
            return .terminateLater
        }
    }
}

@MainActor
final class QuitProgress: ObservableObject {
    static let shared = QuitProgress()

    @Published var pushing = false
    @Published var place = "GitHub"
    @Published var offerQuitNow = false
    private var panel: NSPanel?
    private var finished = false

    func begin(store: LibraryStore) {
        finished = false
        pushing = false
        offerQuitNow = false
        place = store.versions.sync.place
        // Never left waiting: whatever happens, Longhand quits after 15 seconds (the push
        // itself stops at 10).
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.end() }
        // Shown only if the work takes more than a moment (most quits are quicker).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.finished else { return }
            self.show()
        }
        store.finishForQuit(stage: { [weak self] pushes in
            self?.pushing = pushes
            if pushes {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, !self.finished else { return }
                    self.offerQuitNow = true
                }
            }
        }, done: { [weak self] in
            self?.end()
        })
    }

    /// Quit Now: the commit is made; the push is left for next time.
    func end() {
        guard !finished else { return }
        finished = true
        panel?.orderOut(nil)
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func show() {
        let view = NSHostingView(rootView: QuitCard(progress: self))
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // Over the middle of Longhand's window, or the screen's if it was closed.
        let host = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: host.midX - size.width / 2, y: host.midY - size.height / 2))
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

struct QuitCard: View {
    @ObservedObject var progress: QuitProgress

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Symbol.syncing.view(size: 14, weight: .semibold)
                    .symbolEffect(.rotate, options: .repeat(.continuous))
                    .foregroundStyle(Color(PaperTheme.secondary))
                Text(progress.pushing ? "Pushing to \(progress.place)…" : "Committing…")
                    .font(.system(size: Layout.chromeSize, weight: .medium))
                    .foregroundStyle(Color(PaperTheme.ink))
                    .fixedSize()
            }
            if progress.offerQuitNow {
                Button("Quit Now") { progress.end() }
                    .buttonStyle(SquareButtonStyle())
                    .help("Your work is committed on this Mac; it goes up with Longhand’s next push")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(minWidth: 240)
        .background(Color(PaperTheme.paper), in: rounded(Layout.panelRadius))
        .overlay(rounded(Layout.panelRadius).strokeBorder(Color(PaperTheme.cardBorder), lineWidth: 1))
        .animation(.default, value: progress.offerQuitNow)
        .animation(.default, value: progress.pushing)
    }
}
