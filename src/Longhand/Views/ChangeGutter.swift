import AppKit
import Combine

/// Works out the change bars for a page (a scene, or a chapter's scenes): each scene's lines
/// compared with the last version's. The comparison runs after a pause in typing, never on a
/// keystroke; the last version's text comes from `ChangeState`, which looks again a moment
/// after each save.
@MainActor
final class ChangeGutter {
    private weak var textView: HighlightTextView?
    private weak var page: CommentPage?
    private let changes: ChangeState
    private let scenes: () -> [URL]
    /// Each scene's text at the last version. No entry: a new scene, which has no bars.
    private var baselines: [URL: String] = [:]
    private var subscription: AnyCancellable?
    private var pending: Task<Void, Never>?

    init(textView: HighlightTextView, page: CommentPage, changes: ChangeState, margin: MarginStore,
         scenes: @escaping () -> [URL]) {
        self.textView = textView
        self.page = page
        self.changes = changes
        self.scenes = scenes
        // A bar opens the Versions tab on that passage, and the page on the scene's changes.
        textView.onChangeBarClicked = { [weak margin, weak changes] bar in
            margin?.showChange(bar)
            if let scene = bar.scene { changes?.openScene?(scene) }
        }
        subscription = changes.$generation.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.readBaselines()
                self?.compute()
            }
        }
    }

    func detach() {
        pending?.cancel()
        subscription = nil
        textView?.changeBars = []
        textView?.onChangeBarClicked = nil
    }

    /// New text on the page (from disk).
    func loaded() {
        pending?.cancel()
        readBaselines()
        compute()
    }

    /// The page was edited: look again once typing pauses.
    func edited() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.compute()
        }
    }

    /// A scene unchanged at the last look is its own baseline, as the page shows it now:
    /// edits made since then show at the next look, a moment after they are saved.
    private func readBaselines() {
        baselines = [:]
        for url in scenes() {
            switch changes.baseline(for: url) {
            case .new: continue
            case .unchanged: baselines[url] = page?.text(of: url)
            case .text(let old): baselines[url] = old
            }
        }
    }

    private func compute() {
        guard let textView, let page else { return }
        var bars: [ChangeBar] = []
        for url in scenes() {
            guard let old = baselines[url], let now = page.text(of: url),
                  !(old as NSString).isEqual(to: now),
                  let start = page.pageRange(scene: url, local: NSRange(location: 0, length: 0))?.location else { continue }
            bars += ChangeBars.bars(old: old, new: now).map { $0.offset(by: start, scene: url) }
        }
        textView.changeBars = bars
    }
}
