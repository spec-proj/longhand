import Foundation

/// Folders in the Library: plain folders on disk that hold stories, shown as groups. What a
/// folder is for is the writer's business. One level only.
///
///     Library/
///       The Estuary Books/          a folder
///         01 The Salt Road/         a story inside it
///           01 Low Water/…
///       02 Notes for a Second Book/ a story at the top
///
/// A folder at the top of the library is a group when either
/// - it is listed in `.longhand/folders.json` (made with New Folder, so it may be empty), or
/// - its shape says so: no folder straight inside it holds a scene, but a folder one level
///   further down does (stories dragged into a folder in the Finder).
/// Everything else at the top is a story, as before. Both the library scan and the versions'
/// own look at the disk use this one rule.
enum LibraryFolders {
    static func listURL(_ root: URL) -> URL {
        root.appendingPathComponent(".longhand/folders.json")
    }

    /// The folders made with New Folder, by name.
    static func listed(_ root: URL) -> [String] {
        guard let data = try? Data(contentsOf: listURL(root)),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    static func setListed(_ names: [String], in root: URL) {
        let url = listURL(root)
        let unique = Array(Set(names)).sorted()
        if unique.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(unique) { try? data.write(to: url, options: .atomic) }
    }

    /// The names of the top-level folders that are groups.
    static func groups(in root: URL) -> Set<String> {
        var groups = Set(listed(root).filter { isDirectory(root.appendingPathComponent($0)) })
        for name in visible(root) where !groups.contains(name) {
            if looksLikeGroup(root.appendingPathComponent(name)) { groups.insert(name) }
        }
        return groups
    }

    /// No child folder holds a scene, and a grandchild folder does.
    private static func looksLikeGroup(_ folder: URL) -> Bool {
        let children = visible(folder).filter { $0 != StoryFolders.notes && $0 != StoryFolders.boneyard }.map { folder.appendingPathComponent($0) }.filter(isDirectory)
        guard !children.isEmpty else { return false }
        for child in children where holdsScene(child) { return false }
        for child in children {
            for name in visible(child) where name != StoryFolders.notes && name != StoryFolders.boneyard {
                let grandchild = child.appendingPathComponent(name)
                if isDirectory(grandchild), holdsScene(grandchild) { return true }
            }
        }
        return false
    }

    private static func holdsScene(_ folder: URL) -> Bool {
        visible(folder).contains { ProseFile.isProse($0) }
    }

    private static func visible(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
