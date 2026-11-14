import Foundation

extension URL {
    /// macOS reports `/private/var/...` for scanned files but `/var/...` for paths we build,
    /// so every URL the app compares must be canonicalised first.
    ///
    /// Resolving asks the disk about every folder on the way (~8 system calls), and views ask
    /// for it on every redraw, so results for files that exist are remembered.
    var canonical: URL {
        let path = self.path
        if let known = CanonicalPaths.shared.lookup(path) { return known }
        let resolved = standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: resolved.path) {
            CanonicalPaths.shared.remember(path, resolved)
        }
        return resolved
    }
}

/// The remembered `canonical` URLs. Only existing files are kept (a missing file resolves
/// differently once it exists), and the table empties itself when it grows large.
final class CanonicalPaths: @unchecked Sendable {
    static let shared = CanonicalPaths()
    private var table: [String: URL] = [:]
    private let lock = NSLock()

    func lookup(_ path: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return table[path]
    }

    func remember(_ path: String, _ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if table.count > 20_000 { table.removeAll(keepingCapacity: true) }
        table[path] = url
    }

    /// After files move or vanish: forget everything (cheap; it refills as views ask).
    func forget() {
        lock.lock(); defer { lock.unlock() }
        table.removeAll(keepingCapacity: true)
    }
}

extension String {
    /// A scene file's text, whatever it was saved as. Longhand writes UTF-8, but a file made
    /// in another app can be in an older encoding (Windows Latin, UTF-16…). Read as nothing,
    /// such a scene opened blank, and the first words typed replaced the file. So: UTF-8,
    /// else what the Mac works out, else Latin-1 (which reads any bytes). Nil only when the
    /// file can't be read at all.
    static func prose(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        var converted: NSString?
        let found = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false],
                                            convertedString: &converted, usedLossyConversion: nil)
        if found != 0, let converted { return converted as String }
        return String(data: data, encoding: .isoLatin1)
    }
}

enum FileNaming {
    /// Reads "03 The Long Road" as (3, "The Long Road"). Files without a prefix sort first
    /// and keep their whole name as the title.
    static func decode(_ raw: String) -> (order: Int, title: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2, let order = Int(parts[0]) {
            return (order, String(parts[1]))
        }
        return (0, trimmed.isEmpty ? "Untitled" : trimmed)
    }

    static func name(order: Int, title: String) -> String {
        String(format: "%02d %@", order, sanitized(title))
    }

    static func sanitized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "/", with: "-")
        text = text.replacingOccurrences(of: ":", with: "-")
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\r", with: " ")
        if text.count > 80 { text = String(text.prefix(80)) }
        if text.hasPrefix(".") { text = "_" + text.dropFirst() }
        if text.isEmpty { text = "Untitled" }
        return text
    }

    /// Never overwrite. "01 Scene.md" becomes "01 Scene 2.md" if that name is taken.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var counter = 2

        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
