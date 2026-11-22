import Combine
import Foundation

public struct LocalProfile: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var avatar: Int
    public var portrait: Data?
    public var look: Look
    public fileprivate(set) var favorites: Set<UUID> = []

    public init(id: UUID = UUID(), name: String, avatar: Int = 0, portrait: Data? = nil, look: Look) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.portrait = portrait
        self.look = look
    }

    public struct Look: Codable, Equatable {
        public var theme: String
        public var wallpaper: String?
        public var settingsWallpaper: String?
        public var sizing: BackgroundSizing
        public var order: [String]

        public init(_ settings: AppSettings) {
            theme = settings.colorThemeID
            wallpaper = settings.wallpaperID
            settingsWallpaper = settings.settingsWallpaperID
            sizing = settings.backgroundSizing
            order = settings.spotlightOrder
        }

        public func apply(to settings: inout AppSettings) {
            settings.colorThemeID = theme
            settings.wallpaperID = wallpaper
            settings.settingsWallpaperID = settingsWallpaper
            settings.backgroundSizing = sizing
            settings.spotlightOrder = order
        }
    }
}

/// The first profile inherits the existing catalog favorites and play history without rewriting either file.
public final class LocalProfileStore: ObservableObject {
    public static let maximumPortraitBytes = 4_000_000
    private struct Document: Codable {
        let originalID: UUID
        var activeID: UUID
        var profiles: [LocalProfile]
    }

    @Published private var document: Document?
    @Published public private(set) var failed = false
    private let url: URL
    private let selectionURL: URL

    public var profiles: [LocalProfile] { document?.profiles ?? [] }
    public var active: LocalProfile? { profiles.first { $0.id == document?.activeID } }
    public var originalID: UUID? { document?.originalID }

    public init(directory: URL = AppData.supportRoot, settings: AppSettings, name: String) {
        url = directory.appendingPathComponent("profiles.json")
        selectionURL = directory.appendingPathComponent("profiles-active")
        do { try Self.backup(in: directory) }
        catch { failed = true; return }
        do {
            var saved = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard Set(saved.profiles.map(\.id)).count == saved.profiles.count,
                  saved.profiles.contains(where: { $0.id == saved.activeID }) else {
                failed = true
                return
            }
            if let text = try? String(contentsOf: selectionURL, encoding: .utf8), let id = UUID(uuidString: text),
               saved.profiles.contains(where: { $0.id == id }) {
                saved.activeID = id
            }
            document = saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let initial = LocalProfile(name: name, look: .init(settings))
            _ = save(Document(originalID: initial.id, activeID: initial.id, profiles: [initial]))
        } catch {
            failed = true
        }
    }

    @discardableResult public func choose(_ id: UUID) -> Bool {
        guard var next = document, next.profiles.contains(where: { $0.id == id }) else { return false }
        guard next.activeID != id else { return true }
        do {
            try Data(id.uuidString.utf8).write(to: selectionURL, options: .atomic)
            next.activeID = id
            document = next
            failed = false
            return true
        } catch {
            failed = true
            return false
        }
    }

    @discardableResult public func update(_ value: LocalProfile) -> Bool {
        guard var next = document else { return false }
        var profile = value
        profile.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, profile.name.count <= 32,
              (0..<20).contains(profile.avatar), (profile.portrait?.count ?? 0) <= Self.maximumPortraitBytes else { return false }
        if let index = next.profiles.firstIndex(where: { $0.id == value.id }) {
            profile.favorites = next.profiles[index].favorites
            guard next.profiles[index] != profile else { return true }
            next.profiles[index] = profile
        } else {
            next.profiles.append(profile)
        }
        return save(next)
    }

    @discardableResult public func remove(_ id: UUID) -> Bool {
        guard var next = document, next.profiles.count > 1,
              let index = next.profiles.firstIndex(where: { $0.id == id }) else { return false }
        next.profiles.remove(at: index)
        if next.activeID == id { next.activeID = next.profiles[min(index, next.profiles.count - 1)].id }
        return save(next)
    }

    @discardableResult public func toggleFavorite(_ gameID: UUID) -> Bool {
        guard var next = document, let index = next.profiles.firstIndex(where: { $0.id == next.activeID }) else { return false }
        if next.profiles[index].favorites.remove(gameID) == nil { next.profiles[index].favorites.insert(gameID) }
        return save(next)
    }

    private func save(_ next: Document) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            document = next
            failed = false
            return true
        } catch {
            failed = true
            return false
        }
    }

    /// Publish the original files together, once, without touching the credential store.
    private static func backup(in directory: URL) throws {
        let manager = FileManager.default
        let backup = directory.appendingPathComponent("profiles-migration-backup")
        guard !manager.fileExists(atPath: backup.path) else { return }
        let stage = directory.appendingPathComponent(".profiles-backup-\(UUID().uuidString)")
        try manager.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        for name in ["profiles.json", "profiles-active", "settings.json", "catalog.json", "catalog.json.bak",
                     "library.json", "library.json.bak", "play-sessions.json", "play-sessions-totals.json"] {
            let source = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: source.path) {
                try manager.copyItem(at: source, to: stage.appendingPathComponent(name))
            }
        }
        try manager.moveItem(at: stage, to: backup)
    }
}
