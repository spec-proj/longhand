import Foundation

/// An author as a manuscript's title page gives them. Set up in Settings › Authors; a story's
/// page picks one, which fills in the story's author details.
struct AuthorProfile: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var penName = ""
    var address = ""
    var email = ""
    var phone = ""
    /// The author's earlier books, as a title page or "Also by" lists them (owner, 2026-11-13:
    /// it belongs to the author, not to each story).
    var previousWorks = ""

    init(id: String = UUID().uuidString, name: String = "", penName: String = "", address: String = "",
         email: String = "", phone: String = "", previousWorks: String = "") {
        self.id = id
        self.name = name
        self.penName = penName
        self.address = address
        self.email = email
        self.phone = phone
        self.previousWorks = previousWorks
    }

    /// Every field may be missing in a file from an older Longhand.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        penName = try container.decodeIfPresent(String.self, forKey: .penName) ?? ""
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        previousWorks = try container.decodeIfPresent(String.self, forKey: .previousWorks) ?? ""
    }

    /// The name a reader sees: the pen name if there is one, else the name.
    var byline: String {
        [penName, name].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }

    /// What menus call it: the name, else the pen name.
    var title: String {
        let shown = [name, penName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return shown ?? "New Author"
    }

    /// The same details, whatever the id.
    func matches(_ info: SceneInfo) -> Bool {
        func same(_ a: String, _ b: String?) -> Bool {
            a.trimmingCharacters(in: .whitespacesAndNewlines) == (b ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return same(name, info.authorName) && same(penName, info.authorPenName) && same(address, info.authorAddress)
            && same(email, info.authorEmail) && same(phone, info.authorPhone)
    }
}

extension SceneInfo {
    /// Fills the story's author details from a profile (or clears them).
    mutating func setAuthor(_ profile: AuthorProfile?) {
        func value(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        authorProfile = profile?.id
        authorName = value(profile?.name)
        authorPenName = value(profile?.penName)
        authorAddress = value(profile?.address)
        authorEmail = value(profile?.email)
        authorPhone = value(profile?.phone)
    }
}

/// The authors set up on this Mac, kept in `~/Library/Application Support/Longhand/authors.json`
/// (not in a library: one writer, many libraries). A story keeps a copy of its author's
/// details as well as the profile's id, so export and another Mac still have them; the copy
/// is refreshed from the profile whenever the story's page opens.
///
/// Hidden runs (tests, screenshots) start empty and never write the file.
@MainActor
final class AuthorProfiles: ObservableObject {
    static let shared = AuthorProfiles()

    @Published private(set) var all: [AuthorProfile] = []
    private let file: URL?

    init() {
        let hidden = CommandLine.arguments.contains { ["--selftest", "--snapshot", "--perftest", "--export-sample"].contains($0) }
        if hidden {
            file = nil
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Longhand", isDirectory: true)
            file = folder?.appendingPathComponent("authors.json")
            if let file, let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode([AuthorProfile].self, from: data) {
                all = saved
            }
        }
    }

    func profile(_ id: String?) -> AuthorProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    @discardableResult
    func add(_ profile: AuthorProfile = AuthorProfile()) -> AuthorProfile {
        all.append(profile)
        save()
        return profile
    }

    func update(_ profile: AuthorProfile) {
        guard let index = all.firstIndex(where: { $0.id == profile.id }), all[index] != profile else { return }
        all[index] = profile
        save()
    }

    func remove(_ id: String) {
        all.removeAll { $0.id == id }
        save()
    }

    /// A story whose author was removed from Settings (or set up on another Mac): it keeps
    /// the details it has, and no profile is made for them again.
    static let detached = ""

    /// Brings a story's author into line with the profiles, returning the details to keep:
    /// - a story whose profile exists takes the profile's current details;
    /// - a story whose profile is gone keeps its details, marked as on their own;
    /// - a story with details from before profiles existed gets a profile made from them,
    ///   or the one that already matches.
    func settle(_ info: SceneInfo) -> SceneInfo {
        var next = info
        if let found = profile(info.authorProfile) {
            var profile = found
            // Previous works were once kept on each story: they move to its author, added to
            // what the author already has, never lost.
            let works = (info.previousWorks ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !works.isEmpty {
                let have = profile.previousWorks.trimmingCharacters(in: .whitespacesAndNewlines)
                if !have.contains(works) { profile.previousWorks = have.isEmpty ? works : have + "\n" + works }
                update(profile)
                next.previousWorks = nil
            }
            if !profile.matches(info) { next.setAuthor(profile) }
        } else if let id = info.authorProfile {
            if info.hasNoAuthor { next.authorProfile = nil }
            else if id != Self.detached { next.authorProfile = Self.detached }
        } else if !info.hasNoAuthor {
            let profile = all.first { $0.matches(info) } ?? add(AuthorProfile(
                name: info.authorName ?? "", penName: info.authorPenName ?? "", address: info.authorAddress ?? "",
                email: info.authorEmail ?? "", phone: info.authorPhone ?? "", previousWorks: info.previousWorks ?? ""))
            next.authorProfile = profile.id
            if profile.previousWorks == (info.previousWorks ?? "") { next.previousWorks = nil }
        }
        return next
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(all) { try? data.write(to: file, options: .atomic) }
    }
}
