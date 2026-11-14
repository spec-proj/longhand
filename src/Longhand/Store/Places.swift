import AppKit

/// An editor that can say where you are in it.
@MainActor
protocol PlaceReporter: AnyObject { func reportPlace() }

/// Where you were: for each scene and chapter page, the caret and the first character on show,
/// and the last thing you had open. Kept in `.longhand/places.json` (left out of versions), so
/// switching back to a scene, or opening Longhand again, puts you where you left off.
/// Settings › Editor › "Remember my place" turns it off.
@MainActor
final class Places {
    struct Place: Codable, Equatable {
        /// The caret (start of the selection), in the page's characters.
        var caret: Int
        /// The first character on screen, so the page scrolls back to the same view.
        var top: Int
    }

    private struct File: Codable {
        var places: [String: Place] = [:]
        /// The scene or chapter open last (relative path), and which it was.
        var last: String?
        var lastIsChapter: Bool?
    }

    static let settingKey = "rememberPlace"
    static var enabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// The editor on screen, asked for its place before the file is written.
    weak var reporter: PlaceReporter?

    private var root: URL?
    private var file = File()
    private var dirty = false

    private var fileURL: URL? { root?.appendingPathComponent(".longhand/places.json") }

    func open(root: URL?) {
        save()
        self.root = root?.canonical
        file = File()
        dirty = false
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let read = try? JSONDecoder().decode(File.self, from: data) else { return }
        file = read
    }

    private func key(_ url: URL) -> String? {
        guard let root else { return nil }
        let base = root.path + "/"
        let path = url.canonical.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    func place(for url: URL) -> Place? {
        guard Self.enabled, let key = key(url) else { return nil }
        return file.places[key]
    }

    func record(_ place: Place, for url: URL) {
        guard Self.enabled, let key = key(url), file.places[key] != place else { return }
        file.places[key] = place
        dirty = true
    }

    /// The scene or chapter on screen now, to open first next time.
    func opened(_ selection: Selection?) {
        guard Self.enabled else { return }
        let url: URL, chapter: Bool
        switch selection {
        case .scene(let scene): url = scene; chapter = false
        case .chapter(let page): url = page; chapter = true
        default: return
        }
        guard let key = key(url), file.last != key || file.lastIsChapter != chapter else { return }
        file.last = key
        file.lastIsChapter = chapter
        dirty = true
    }

    /// What to open when the library opens, if it still exists.
    var lastOpened: Selection? {
        guard Self.enabled, let root, let last = file.last else { return nil }
        let url = root.appendingPathComponent(last)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return file.lastIsChapter == true ? .chapter(url) : .scene(url)
    }

    /// Scenes and chapters moved or renamed: their places go with them.
    func relocate(_ moves: [(from: URL, to: URL)]) {
        for move in moves {
            guard let from = key(move.from), let to = key(move.to) else { continue }
            for (path, place) in file.places where path == from || path.hasPrefix(from + "/") {
                file.places[path] = nil
                file.places[to + path.dropFirst(from.count)] = place
                dirty = true
            }
            if let last = file.last, last == from || last.hasPrefix(from + "/") {
                file.last = to + last.dropFirst(from.count)
                dirty = true
            }
        }
    }

    /// Writes the file if anything changed, asking the editor on screen for its place first.
    func save() {
        reporter?.reportPlace()
        guard dirty, let url = fileURL else { return }
        dirty = false
        // Places of scenes that no longer exist are dropped as the file is written.
        if let root {
            file.places = file.places.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.key).path) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension NSTextView {
    /// The caret and the first character on screen.
    var currentPlace: Places.Place {
        let visible = enclosingScrollView?.contentView.documentVisibleRect ?? visibleRect
        let top = characterRange(in: NSRect(x: visible.minX, y: visible.minY + 1, width: visible.width, height: 1)).location
        return Places.Place(caret: selectedRange().location, top: top)
    }

    /// Puts the caret back and scrolls so the same character is at the top of the page.
    func restore(_ place: Places.Place) {
        let length = (string as NSString).length
        let caret = min(max(0, place.caret), length)
        let top = min(max(0, place.top), length)
        setSelectedRange(NSRange(location: caret, length: 0))
        if let textLayoutManager, let target = textRange(for: NSRange(location: top, length: 0)),
           let upTo = NSTextRange(location: textLayoutManager.documentRange.location, end: target.location) {
            // TextKit 2 estimates what it hasn't drawn: lay it out for real so the page lands
            // where it was, not a screen away.
            textLayoutManager.ensureLayout(for: upTo)
            textLayoutManager.textViewportLayoutController.layoutViewport()
        }
        guard let clip = enclosingScrollView?.contentView else { return }
        guard top > 0, let line = lineRects(of: NSRange(location: top, length: 0)).first else {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 0))
            enclosingScrollView?.reflectScrolledClipView(clip)
            return
        }
        let limit = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, line.minY), limit)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}
