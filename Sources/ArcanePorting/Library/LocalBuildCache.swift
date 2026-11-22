import Foundation

/// A game's build cache on this Mac (`<title ID>_build`): what the engine reuses so a rebuild compiles no shader twice.
public enum LocalBuildCache {
    /// The shader chain in a `b-<12 hex>.img` folder (`shader/cache` or an app's `msl`); nil unless there is exactly one.
    public static func chain(in folder: URL) -> String? {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name -> String? in
            guard name.hasPrefix("b-"), name.hasSuffix(".img") else { return nil }
            let id = String(name.dropFirst(2).dropLast(4))
            return id.utf8.count == 12 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? id : nil
        }
        return ids.count == 1 ? ids[0] : nil
    }

    /// The chain of a cache folder; nil when it holds no finished shader image.
    public static func chain(ofCache cache: URL) -> String? {
        chain(in: cache.appendingPathComponent("shader/cache"))
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
