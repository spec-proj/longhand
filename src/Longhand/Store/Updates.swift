import AppKit

/// Telling the writer about a new version (owner, 2026-11-14): Longhand asks GitHub for the
/// latest release of spec-proj/longhand when it opens and once a day, and if it is newer than
/// this copy, the status bar says so, with What's New and Download. It never downloads or
/// installs by itself. The request carries nothing about the writer or their library. Off in
/// Settings › Appearance › Updates; never run by hidden test runs.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    static let key = "checkForUpdates"
    static let releases = URL(string: "https://api.github.com/repos/spec-proj/longhand/releases/latest")!

    struct Release: Equatable {
        /// "0.9.5".
        let version: String
        /// The release's page, with its notes.
        let page: URL
        /// The app's zip, if the release has one.
        let download: URL?
    }

    /// A release newer than this copy, if there is one.
    @Published private(set) var available: Release?

    private var timer: Timer?
    private var checking = false

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// This copy's version ("0.9.4").
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Starts checking: a few seconds after opening (never slowing it), then once a day.
    func start() {
        guard !Snapshot.isBackgroundRun, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Asks GitHub. `userAsked` (Longhand › Check for Updates…) checks even with the setting
    /// off, and says what it found either way.
    func check(userAsked: Bool = false) {
        guard userAsked || Self.enabled, !checking else { return }
        checking = true
        var request = URLRequest(url: Self.releases, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let release = ok ? data.flatMap(Self.release(from:)) : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checking = false
                if let release, Self.isNewer(release.version, than: Self.current) {
                    if self.available != release { self.available = release }
                } else if ok {
                    self.available = nil
                }
                if userAsked { self.report(release, reached: ok) }
            }
        }.resume()
    }

    /// The latest release from GitHub's answer: its tag ("v0.9.5-beta"), page and zip.
    nonisolated static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String
        return Release(version: version(of: tag), page: page, download: zip.flatMap(URL.init(string:)))
    }

    /// "v0.9.5-beta" → "0.9.5", "v0.9.7a-beta" → "0.9.7a" (a letter fixes a mistake within one
    /// number, so it is part of the version, not a build note).
    nonisolated static func version(of tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        return String(text.prefix { $0.isNumber || $0 == "." || $0.isASCII && $0.isLetter })
    }

    /// One number of a version and a letter that may follow it: "7a" → (7, "a").
    nonisolated static func part(of piece: Substring) -> (Int, String) {
        let digits = piece.prefix { $0.isNumber }
        let letter = piece.drop { $0.isNumber }.lowercased()
        return (Int(digits) ?? 0, String(letter))
    }

    /// Whether version `a` comes after `b`, number by number ("0.10.0" after "0.9.4"),
    /// with a letter after the number ("0.9.7a" after "0.9.7", "0.9.8" after "0.9.7a").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map(part(of:))
        let y = b.split(separator: ".").map(part(of:))
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : (0, ""), q = i < y.count ? y[i] : (0, "")
            if p.0 != q.0 { return p.0 > q.0 }
            if p.1 != q.1 { return p.1 > q.1 }
        }
        return false
    }

    /// The answer to Check for Updates…, in a plain alert.
    private func report(_ release: Release?, reached: Bool) {
        let alert = NSAlert()
        if let release = available ?? release, Self.isNewer(release.version, than: Self.current) {
            alert.messageText = "Longhand \(release.version) is available"
            alert.informativeText = "You have \(Self.current). Download the new version, then replace the app in Applications with it."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "What’s New")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn: download()
            case .alertSecondButtonReturn: NSWorkspace.shared.open(release.page)
            default: break
            }
        } else if reached {
            alert.messageText = "Longhand \(Self.current) is the latest version"
            alert.runModal()
        } else {
            alert.messageText = "Couldn’t reach GitHub"
            alert.informativeText = "Check your connection and try again."
            alert.runModal()
        }
    }

    /// Opens the new version's zip (the browser downloads it), or its page if it has none.
    func download() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.download ?? release.page)
    }

    /// Pictures only (`LONGHAND_UPDATE=0.9.9`): show a release as if GitHub had one.
    func pretend(_ version: String) {
        available = Release(version: version, page: URL(string: "https://github.com/spec-proj/longhand/releases")!, download: nil)
    }

    func showNotes() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.page)
    }
}
