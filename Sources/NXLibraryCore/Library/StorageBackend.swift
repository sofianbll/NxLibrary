import Foundation

/// A backend-relative identifier, not a filesystem URL or a remote specification.
public struct StorageObjectKey: Codable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) { self.value = value }
}

public struct StorageObject: Equatable, Sendable {
    public let key: StorageObjectKey
    public let size: Int64
    /// Lowercase algorithm names (e.g. `sha256`, `md5`) and hexadecimal values.
    public let hashes: [String: String]

    public init(key: StorageObjectKey, size: Int64, hashes: [String: String]) {
        self.key = key
        self.size = size
        self.hashes = hashes
    }
}

public struct StorageProgress: Equatable, Sendable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64

    public init(bytesTransferred: Int64, totalBytes: Int64) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }
}

public enum StorageBackendError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidKey
    case invalidLocalFile
    case invalidFingerprint
    case alreadyExists
    case notFound
    case hashMismatch
    case backendUnavailable
    case processFailed(status: Int32, stderrTail: String)
    case invalidResponse
}

/// Operations throw `CancellationError` when cancelled. Transfer callbacks run off the caller's executor.
public protocol StorageBackend: Sendable {
    func list() async throws -> [StorageObject]
    /// Publishes a new object only after verification. Serialise writers for a key; this is not compare-and-swap.
    func put(_ source: URL, as object: StorageObject, progress: (@Sendable (StorageProgress) -> Void)?) async throws
    /// Downloads to a new local file; does not replace an existing destination.
    func get(_ key: StorageObjectKey, to destination: URL, progress: (@Sendable (StorageProgress) -> Void)?) async throws
    func delete(_ key: StorageObjectKey) async throws
    /// Compares size and a common hash (or hashes the downloaded bytes). Requires an expected SHA-256.
    func verify(_ object: StorageObject) async throws
}

extension StorageBackend {
    public func put(_ source: URL, as object: StorageObject) async throws {
        try await put(source, as: object, progress: nil)
    }

    public func get(_ key: StorageObjectKey, to destination: URL) async throws {
        try await get(key, to: destination, progress: nil)
    }
}
