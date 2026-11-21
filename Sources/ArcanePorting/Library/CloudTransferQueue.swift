import Foundation
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

public enum CloudQuitDecision: Equatable {
    case quit, cancel, confirm, flush

    public static func resolve(isWorking: Bool = false, hasQueueWrites: Bool = false,
                               isQuitting: Bool = false, cleanupComplete: Bool = false,
                               relaunchScheduled: Bool = false) -> Self {
        if cleanupComplete { return .quit }
        if isQuitting { return .cancel }
        if isWorking { return relaunchScheduled ? .cancel : .confirm }
        return hasQueueWrites ? .flush : .quit
    }
}

/// Profile-local snapshot, with the interrupted operation at the head of the FIFO.
public final class CloudTransferQueue: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: UUID
        public let action: CloudLibraryAction
        package let token: UUID?
        package let storage: String?

        public init(id: UUID, action: CloudLibraryAction) {
            self.init(id: id, action: action, token: nil, storage: nil)
        }

        package init(id: UUID, action: CloudLibraryAction, token: UUID?, storage: String?) {
            self.id = id
            self.action = action
            self.token = token
            self.storage = storage
        }
    }

    private let store: ActivityQueueFile<Entry>

    public init(file: URL = AppData.supportRoot.appendingPathComponent("cloud-transfer-queue.json")) {
        store = ActivityQueueFile(file: file)
    }

    public func load() async -> [Entry] { await store.load() }
    public func save(_ entries: [Entry]) { store.save(entries) }
    public func flush() async { await store.flush() }

    public static func restoring(_ entries: [Entry], gameIDs: Set<UUID>) -> [Entry] {
        var remaining = gameIDs
        var tokens = Set<UUID>()
        return entries.filter {
            guard remaining.contains($0.id), $0.token.map({ tokens.insert($0).inserted }) ?? true else { return false }
            remaining.remove($0.id)
            return true
        }
    }
}
