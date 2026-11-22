import Foundation
import Darwin

/// A game's build cache on this Mac (`<title ID>_build`): what the engine reuses so a rebuild compiles no shader twice.
public enum LocalBuildCache {
    /// The shader chain in a `b-<12 hex>.img` folder (`shader/cache` or an app's `msl`); nil unless there is exactly one.
    public static func chain(in folder: URL) -> String? {
        try? readChain(in: folder)
    }

    private static func readChain(in folder: URL) throws -> String? {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        let ids = names.compactMap { name -> String? in
            guard name.hasPrefix("b-"), name.hasSuffix(".img") else { return nil }
            let id = String(name.dropFirst(2).dropLast(4))
            return id.utf8.count == 12 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? id : nil
        }
        return ids.count == 1 ? ids[0] : nil
    }

    public static func readChain(ofCache cache: URL) throws -> String? {
        let parts = cache.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            _ = try CloudArchiveInventory.node(at: URL(fileURLWithPath: "/Volumes/\(parts[2])"))
        }
        for directory in [cache, cache.appendingPathComponent("shader"), cache.appendingPathComponent("shader/cache")] {
            do {
                guard try CloudArchiveInventory.node(at: directory).st_mode & S_IFMT == S_IFDIR else {
                    throw CloudArchiveError.unsafePath
                }
            } catch CloudArchiveError.localMissing { return nil }
        }
        let folder = cache.appendingPathComponent("shader/cache")
        guard let chain = try readChain(in: folder) else { return nil }
        let image = try CloudArchiveInventory.node(at: folder.appendingPathComponent("b-\(chain).img"))
        guard image.st_mode & S_IFMT == S_IFREG, image.st_size > 0 else { throw CloudArchiveError.localChanged }
        return chain
    }

    public static func matchesInstalledApp(_ cache: URL, app: URL?) throws -> Bool {
        guard let app, let chain = try readChain(ofCache: cache) else { return false }
        return try readChain(in: app.appendingPathComponent("Contents/Resources/msl")) == chain
    }

    /// The chain of a cache folder; nil when it holds no finished shader image.
    public static func chain(ofCache cache: URL) -> String? {
        chain(in: cache.appendingPathComponent("shader/cache"))
    }

    /// The game's cache folder when it holds a finished shader image: the one a rebuild falls back on when the
    /// cloud can't be read or its cache download failed. A missing, empty or ambiguous folder is not a cache.
    public static func usable(atPath path: String?) -> URL? {
        path.map { URL(fileURLWithPath: $0) }.flatMap { chain(ofCache: $0) == nil ? nil : $0 }
    }

    /// Shaders the cache holds, from the engine's own "28,603 of 28,603 shaders ready" line.
    public static func shaderCount(ofCache cache: URL) -> Int? {
        guard let chain = chain(ofCache: cache),
              let text = try? String(contentsOf: cache.appendingPathComponent("shader/mac-b-\(chain).key"), encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.contains(" shaders ready") }),
              let ready = line.components(separatedBy: " of ").first else { return nil }
        return Int(ready.filter(\.isNumber))
    }

    /// A finished build's work folder becomes the game's cache; the cache it replaces goes to the Trash.
    public static func adopt(_ work: URL, as cache: URL,
                             retire: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let fm = FileManager.default
        guard work.standardizedFileURL != cache.standardizedFileURL, fm.fileExists(atPath: work.path) else { return }
        if fm.fileExists(atPath: cache.path) { try retire(cache) }
        try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: work, to: cache)
    }
}
