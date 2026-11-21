import Foundation
import OSLog
import NXLibraryCore

public enum CloudLibraryItem: String, Codable, CaseIterable, Hashable, Sendable {
    case app, cache, sources

    public init(_ kind: CloudArtifactKind) { self = kind == .app ? .app : .cache }
    public var artifact: CloudArtifactKind? {
        switch self {
        case .app: return .app
        case .cache: return .cache
        case .sources: return nil
        }
    }
}

public enum CloudLibraryAction: Codable, Equatable, Sendable {
    case upload(CloudArtifactKind? = nil)
    case free(Set<CloudLibraryItem>)
    case restore(CloudArtifactKind)
    case restoreBuildCache
    case uploadSources
    case downloadSources

    public func resumableFree(synchronized: Set<CloudLibraryItem>) -> Self? {
        guard case .free(let items) = self else { return nil }
        let remaining = items.intersection(synchronized)
        return remaining.isEmpty ? nil : .free(remaining)
    }
}

/// Profile-local snapshot, with the interrupted operation at the head of the FIFO.
public final class CloudTransferQueue: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: UUID
        public let action: CloudLibraryAction

        public init(id: UUID, action: CloudLibraryAction) {
            self.id = id
            self.action = action
        }
    }

    private struct Snapshot: Codable {
        let version: Int
        let entries: [Entry]
    }

    private let file: URL
    private let io = DispatchQueue(label: "local.nxlibrary.cloud-transfer-queue", qos: .utility)
    private static let log = Logger(subsystem: "local.nxlibrary", category: "cloud-transfer-queue")

    public init(file: URL = AppData.supportRoot.appendingPathComponent("cloud-transfer-queue.json")) {
        self.file = file
    }

    public func load() async -> [Entry] {
        await withCheckedContinuation { continuation in
            io.async {
                do {
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: self.file))
                    if snapshot.version == 1 {
                        continuation.resume(returning: snapshot.entries)
                        return
                    }
                    Self.log.error("Unsupported cloud transfer queue version")
                } catch where (error as NSError).code == NSFileReadNoSuchFileError && (error as NSError).domain == NSCocoaErrorDomain {
                    // No queue has been written in this profile.
                } catch {
                    Self.log.error("Could not read the cloud transfer queue")
                }
                continuation.resume(returning: [])
            }
        }
    }

    public func save(_ entries: [Entry]) {
        io.async {
            do {
                try FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Snapshot(version: 1, entries: entries)).write(to: self.file, options: .atomic)
            } catch {
                Self.log.error("Could not save the cloud transfer queue")
            }
        }
    }

    public func flush() async {
        await withCheckedContinuation { continuation in io.async { continuation.resume() } }
    }

    public static func restoring(_ entries: [Entry], gameIDs: Set<UUID>) -> [Entry] {
        var remaining = gameIDs
        return entries.filter { remaining.remove($0.id) != nil }
    }
}
