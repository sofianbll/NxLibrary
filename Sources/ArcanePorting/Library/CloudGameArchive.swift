import Darwin
import Foundation
import NXLibraryCore

public enum CloudArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case app, cache
}

public struct CloudArtifactStatus: Equatable, Sendable {
    public struct SkippedRoot: Equatable, Sendable {
        public let path: String
        public let bytes: Int64
    }

    public enum State: Equatable, Sendable {
        case notInCloud, cloudOnly, synchronized, newerOnThisMac, unknown
    }

    public let state: State
    public let hasLocalCopy: Bool
    public let bytes: Int64?
    public let uploadedAt: Date?
    public let skippedRoots: [SkippedRoot]

    /// Presence alone cannot tell whether two copies have the same contents.
    static func availability(local: Bool?, artifact: CloudGameManifest.Artifact?, uploadedAt: Date?) -> Self {
        .init(state: artifact == nil ? .notInCloud : local == false ? .cloudOnly : .unknown,
              hasLocalCopy: local == true, bytes: artifact?.unpackedSize,
              uploadedAt: artifact == nil ? nil : uploadedAt, skippedRoots: [])
    }

    public static func needsUpload(_ statuses: [CloudArtifactKind: Self]) -> Bool {
        CloudArtifactKind.allCases.allSatisfy { statuses[$0]?.hasLocalCopy == true }
            && statuses.values.contains { $0.state == .notInCloud || $0.state == .newerOnThisMac }
    }

    public static func canUploadAlone(_ kind: CloudArtifactKind, statuses: [CloudArtifactKind: Self]) -> Bool {
        guard let copy = statuses[kind], copy.hasLocalCopy else { return false }
        let other = statuses[kind == .app ? .cache : .app]
        if kind == .app, other?.state == .notInCloud {
            return copy.state == .newerOnThisMac || (copy.state == .notInCloud && other?.hasLocalCopy == false)
        }
        if kind == .cache, copy.state == .notInCloud { return other?.state == .synchronized || other?.state == .cloudOnly }
        return copy.state == .newerOnThisMac && other?.uploadedAt != nil
    }
}

public struct CloudArchiveProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case archiving, uploading, verifying, downloading, restoring }
    public let phase: Phase
    public let kind: CloudArtifactKind?
    public let transfer: StorageProgress?

    public init(_ phase: Phase, kind: CloudArtifactKind? = nil, transfer: StorageProgress? = nil) {
        self.phase = phase
        self.kind = kind
        self.transfer = transfer
    }
}

public struct CloudArchiveGame: Sendable {
    public let titleID: String
    public let locations: [CloudArtifactKind: URL]
    public let engineCommit: String?
    let cacheIsRegistered: Bool
    public let sourceSelection: CloudGameSources.ArchivedSelection?

    public init(titleID: String, locations: [CloudArtifactKind: URL], engineCommit: String? = nil,
                cacheIsRegistered: Bool? = nil, sourceSelection: CloudGameSources.ArchivedSelection? = nil) {
        self.titleID = titleID.uppercased()
        self.locations = locations
        self.engineCommit = engineCommit
        self.cacheIsRegistered = cacheIsRegistered ?? (locations[.cache] != nil)
        self.sourceSelection = sourceSelection
    }
}

public struct CloudGameManifest: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable {
        public let kind: CloudArtifactKind
        public let size: Int64
        public let sha256: String
        public let md5: String
        public let unpackedSize: Int64
        public let entryCount: Int
        public let inventorySHA256: String
        public let engineCommit: String?
        public let shaderChain: String?
        public let options: [String: String]

        public func object(titleID: String) -> StorageObject {
            StorageObject(key: StorageObjectKey("\(titleID)/\(kind.rawValue)/\(sha256).aar"),
                          size: size, hashes: ["sha256": sha256, "md5": md5])
        }

        enum CodingKeys: String, CodingKey {
            case kind, size, sha256, md5, options
            case unpackedSize = "unpacked_size", entryCount = "entry_count", inventorySHA256 = "inventory_sha256"
            case engineCommit = "engine_commit", shaderChain = "shader_chain"
        }
    }

    public let version: Int
    public let titleID: String
    public let createdAt: Date
    public let artifacts: [Artifact]
    public let gameName: String?
    public let bundleName: String?
    public let sourceSelection: CloudGameSources.ArchivedSelection?
    public var gameVersion: String? { artifacts.first { $0.kind == .app }?.options["CFBundleShortVersionString"] }
    public var cloudOnlyApp: CloudArtifactStatus? {
        artifacts.first { $0.kind == .app }.map {
            .init(state: .cloudOnly, hasLocalCopy: false, bytes: $0.unpackedSize, uploadedAt: createdAt, skippedRoots: [])
        }
    }

    init(version: Int, titleID: String, createdAt: Date, artifacts: [Artifact],
         gameName: String? = nil, bundleName: String? = nil,
         sourceSelection: CloudGameSources.ArchivedSelection? = nil) {
        self.version = version
        self.titleID = titleID
        self.createdAt = createdAt
        self.artifacts = artifacts
        self.gameName = gameName
        self.bundleName = bundleName
        self.sourceSelection = sourceSelection
    }

    enum CodingKeys: String, CodingKey {
        case version, artifacts
        case titleID = "title_id", createdAt = "created_at"
        case gameName = "game_name", bundleName = "bundle_name"
        case sourceSelection = "source_selection"
    }
}

public enum CloudArchiveError: LocalizedError, Equatable {
    public enum UploadDifference: String {
        case added, removed, type, size, linkTarget, permissions, parentDirectory
    }

    case busy, confirmationRequired, insufficientSpace, unsafePath, localMissing
    case noRemoteCopy, needsFullUpload, invalidManifest, invalidArchive, invalidApp, localChanged, excludedFiles, installFailed
    case sourcesConflict
    case uploadMismatch(CloudArtifactKind, path: String, reason: UploadDifference)

    public var diagnosticDetail: String? {
        guard case .uploadMismatch(let kind, let path, let reason) = self else { return nil }
        return DiagnosticsReport.scrub("Cloud upload: \(kind.rawValue) \(String(reflecting: path)) — \(reason.rawValue)",
                                       home: NSHomeDirectory())
    }

    public var errorDescription: String? {
        switch self {
        case .busy:
            return L10n.text("Close the game and wait for other operations to finish.")
        case .insufficientSpace:
            return L10n.text("Not enough free space on the destination drive.")
        case .invalidApp:
            return L10n.text("The app identity or signature could not be verified.")
        case .excludedFiles:
            return L10n.text("This folder contains files that must stay on this Mac.")
        case .localChanged:
            return L10n.text("The local copy changed. Check it before trying again.")
        case .needsFullUpload:
            return L10n.text("Send both the app and the build cache to create a complete cloud copy.")
        case .sourcesConflict:
            return L10n.text("A game file differs from its cloud copy. No existing copy is replaced.")
        case .uploadMismatch(let kind, let path, _):
            return L10n.format(kind == .app ? "The app changed during upload (%@). Try again."
                               : "The build cache changed during upload (%@). Try again.", [path])
        case .unsafePath, .localMissing:
            return L10n.text("A local folder is missing, unavailable or shared with another game.")
        case .invalidManifest, .invalidArchive:
            return L10n.text("The cloud copy could not be verified.")
        default:
            return L10n.text("The cloud operation could not be completed.")
        }
    }
}

public enum CloudRebuildDecision: Equatable, Sendable {
    case allowed, fullRebuild, missingSources, downloadCache

    static func decide(sourcesAvailable: Bool, remoteCache: Bool, localVerified: Bool,
                       withoutCache: Bool) -> Self {
        if !sourcesAvailable { return .missingSources }
        return remoteCache && !localVerified && !withoutCache ? .downloadCache : .allowed
    }
}

public actor CloudGameArchive {
    public typealias Progress = @Sendable (CloudArchiveProgress) -> Void
    private typealias Artifact = CloudGameManifest.Artifact
    private typealias Fingerprint = CloudArchiveFingerprintCache.Fingerprint
    private static let manifestLimit = 64 * 1024
    private let backend: any StorageBackend
    private let capacity: @Sendable (URL) -> Int64?
    private let trash: @Sendable (URL) throws -> Void
    private let leases: CloudTitleLeases
    private let fingerprints: CloudArchiveFingerprintCache

    public init(backend: any StorageBackend) {
        self.init(backend: backend, trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                  fingerprints: .shared)
    }

    internal init(backend: any StorageBackend,
                  capacity: @escaping @Sendable (URL) -> Int64? = {
                      (try? FileManager.default.attributesOfFileSystem(forPath: $0.path)[.systemFreeSize] as? NSNumber)?.int64Value
                  },
                  trash: @escaping @Sendable (URL) throws -> Void,
                  fingerprints: CloudArchiveFingerprintCache = .init()) {
        self.backend = backend
        self.leases = (backend as? RcloneStorageBackend)?.leases ?? CloudTitleLeases()
        self.capacity = capacity
        self.trash = trash
        self.fingerprints = fingerprints
    }

    /// A failed manifest read is distinct from a successful lookup with no manifest.
    public func copyStatuses(_ game: CloudArchiveGame, manifest lookup: Result<CloudGameManifest?, Error>)
        async throws -> [CloudArtifactKind: CloudArtifactStatus] {
        let manifest = try? lookup.get()
        let readable: Bool
        if case .success = lookup { readable = manifest.map { $0.titleID == game.titleID } ?? true }
        else { readable = false }
        let cached = await fingerprints.entries()
        let worker = Task.detached(priority: .utility) {
            var statuses: [CloudArtifactKind: CloudArtifactStatus] = [:]
            var fingerprints: [String: Fingerprint] = [:]
            for kind in CloudArtifactKind.allCases {
                try Task.checkCancellation()
                let artifact = readable ? manifest?.artifacts.first { $0.kind == kind } : nil
                var state = CloudArtifactStatus.State.unknown
                var local = false
                var bytes = artifact?.unpackedSize
                var skippedRoots: [CloudArtifactStatus.SkippedRoot] = []
                if kind == .cache, readable, artifact == nil, !game.cacheIsRegistered, game.locations[.cache] == nil {
                    state = .notInCloud
                }
                if let url = try? self.location(kind, for: game),
                   let parent = try? CloudArchiveInventory.node(at: url.deletingLastPathComponent()),
                   parent.st_mode & S_IFMT == S_IFDIR {
                    do {
                        guard try self.existingNode(at: url) != nil else {
                            let confirmed = (try? self.sameDirectory(parent, at: url.deletingLastPathComponent())) == true
                            let missing: CloudArtifactStatus.State = artifact == nil ? .notInCloud : .cloudOnly
                            statuses[kind] = .init(state: readable && confirmed ? missing : .unknown,
                                                   hasLocalCopy: false, bytes: bytes,
                                                   uploadedAt: artifact == nil ? nil : manifest?.createdAt, skippedRoots: [])
                            continue
                        }
                        let signature = try CloudArchiveInventory.signature(url, kind: kind)
                        skippedRoots = signature.skippedRoots.map {
                            .init(path: $0, bytes: DirectorySize.bytes(at: url.appendingPathComponent($0), includingHidden: true))
                        }
                        if signature.isSkippedOnly {
                            if readable { state = artifact == nil ? .notInCloud : .cloudOnly }
                        } else if !signature.hasExcludedFiles {
                            bytes = signature.bytes
                            local = true
                            if let artifact {
                                if signature.bytes != artifact.unpackedSize || signature.entries.count != artifact.entryCount {
                                    state = .newerOnThisMac
                                } else {
                                    let key = CloudArchiveInventory.fingerprintKey(url, kind: kind)
                                    let fingerprint: Fingerprint
                                    if let previous = cached[key], previous.signature == signature.sha256 {
                                        fingerprint = previous
                                    } else {
                                        let snapshot = try CloudArchiveInventory.scan(url, kind: kind)
                                        let after = try CloudArchiveInventory.signature(url, kind: kind)
                                        guard !snapshot.hasExcludedFiles, !after.hasExcludedFiles, signature.sha256 == after.sha256 else {
                                            throw CloudArchiveError.localChanged
                                        }
                                        fingerprint = .init(signature: signature.sha256, sha256: snapshot.sha256,
                                                            withoutRootMtime: snapshot.withoutRootMtime)
                                        fingerprints[key] = fingerprint
                                    }
                                    state = fingerprint.matches(artifact) ? .synchronized : .newerOnThisMac
                                }
                            } else if readable {
                                state = .notInCloud
                            }
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        local = false
                    }
                }
                statuses[kind] = .init(state: state, hasLocalCopy: local, bytes: bytes,
                                       uploadedAt: artifact == nil ? nil : manifest?.createdAt, skippedRoots: skippedRoots)
            }
            return (statuses, fingerprints)
        }
        let (statuses, fresh) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        await fingerprints.save(fresh)
        return statuses
    }

    @MainActor public static func checkCatalogAvailability<Game>(_ games: [Game], titleID: (Game) -> String?,
                                                                visit: (Game) async throws -> Void) async rethrows {
        for game in games {
            guard !Task.isCancelled else { return }
            guard titleID(game).map(SaveLocation.validID) == true else { continue }
            try await visit(game)
        }
    }

    /// Hold the same title lease as upload, free and restore until the engine exits.
    public func beginBuild(titleID: String) throws -> UUID {
        try begin(titleID.uppercased())
    }

    public func endBuild(titleID: String, token: UUID) {
        leases.end(titleID.uppercased(), token: token)
    }

    public func checkRebuild(_ game: CloudArchiveGame, sourcesAvailable: Bool, withoutCache: Bool)
        async throws -> (decision: CloudRebuildDecision, verifiedCache: URL?) {
        guard sourcesAvailable else { return (.missingSources, nil) }
        guard !withoutCache else { return (.allowed, nil) }
        let manifest = try await latest(titleID: game.titleID)
        let artifact = manifest?.artifacts.first { $0.kind == .cache }
        if manifest != nil, artifact == nil { return (.fullRebuild, nil) }
        let cache = try? location(.cache, for: game)
        let verified: URL? = artifact.flatMap { artifact in
            cache.flatMap { url in
                guard let snapshot = try? CloudArchiveInventory.scan(url, kind: .cache),
                      !snapshot.hasExcludedFiles, !snapshot.isSkippedOnly,
                      Fingerprint(signature: "", sha256: snapshot.sha256,
                                  withoutRootMtime: snapshot.withoutRootMtime).matches(artifact) else { return nil }
                return url
            }
        }
        return (.decide(sourcesAvailable: sourcesAvailable, remoteCache: artifact != nil,
                        localVerified: verified != nil, withoutCache: withoutCache), verified)
    }

    public func latestManifests() async throws -> [CloudGameManifest] {
        let folders = try await backend.rootDirectories()
        // Uploads use uppercase IDs as case-sensitive storage keys.
        let titles = Set(folders.filter { SaveLocation.validID($0) && $0 == $0.uppercased() })
        guard titles.count <= 2_000 else { throw StorageBackendError.invalidResponse }
        var manifests: [CloudGameManifest] = []
        for title in titles.sorted() {
            try Task.checkCancellation()
            if let manifest = try await latest(titleID: title) { manifests.append(manifest) }
        }
        try Task.checkCancellation()
        return manifests
    }

    public func latest(titleID: String, expectingArchive: Bool = false) async throws -> CloudGameManifest? {
        let title = titleID.uppercased()
        guard SaveLocation.validID(title) else { throw CloudArchiveError.unsafePath }
        let directory = StorageObjectKey("\(title)/manifests")
        let entries: [StorageObject]
        do { entries = try await backend.list(in: directory) }
        catch CloudLibraryFailure.folderMissing {
            // The per-title manifests folder is implicit until the first archive is published.
            if expectingArchive { throw CloudLibraryFailure.folderMissing }
            _ = try await backend.rootDirectories()
            return nil
        }
        guard let newest = entries
            .filter({ $0.key.value.hasPrefix(directory.value + "/") && $0.key.value.hasSuffix(".json") })
            .max(by: { $0.key.value < $1.key.value }) else { return nil }
        return try await readManifest(newest, titleID: title)
    }

    /// Fetch just the newest manifest; local availability uses a single stat per registered artifact.
    public func availability(_ game: CloudArchiveGame, expectingArchive: Bool = false) async throws -> [CloudArtifactKind: CloudArtifactStatus] {
        let manifest = try await latest(titleID: game.titleID, expectingArchive: expectingArchive)
        try Task.checkCancellation()
        return Dictionary(uniqueKeysWithValues: CloudArtifactKind.allCases.map { kind in
            let local: Bool?
            if let url = game.locations[kind] {
                do {
                    let node = try CloudArchiveInventory.node(at: url)
                    local = node.st_mode & S_IFMT == S_IFDIR ? true : nil
                } catch CloudArchiveError.localMissing { local = false }
                catch { local = nil }
            } else { local = false }
            return (kind, .availability(local: local, artifact: manifest?.artifacts.first { $0.kind == kind },
                                        uploadedAt: manifest?.createdAt))
        })
    }

    func readManifest(_ object: StorageObject, titleID title: String) async throws -> CloudGameManifest {
        let prefix = "\(title)/manifests/"
        guard SaveLocation.validID(title), object.key.value.hasPrefix(prefix),
              object.key.value.hasSuffix(".json") else { throw CloudArchiveError.invalidManifest }
        let name = object.key.value.dropFirst(prefix.count).dropLast(5)
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 16, Int64(parts[0]) != nil, Self.isHex(String(parts[1]), count: 64),
              (1...Int64(Self.manifestLimit)).contains(object.size) else { throw CloudArchiveError.invalidManifest }
        let stage = try staging(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: stage) }
        let file = stage.appendingPathComponent("manifest.json")
        try await backend.get(object.key, to: file)
        let data = try SaveFiles.readRegular(file, limit: Self.manifestLimit)
        guard Int64(data.count) == object.size,
              try CloudArchiveInventory.hashes(at: file, includeMD5: false)["sha256"] == String(parts[1])
        else { throw CloudArchiveError.invalidManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(CloudGameManifest.self, from: data),
              manifest.version == 1, manifest.titleID == title,
              [[.app], CloudArtifactKind.allCases].contains(manifest.artifacts.map(\.kind)),
              manifest.artifacts.allSatisfy({
                  $0.size > 0 && $0.unpackedSize >= 0 && (1...CloudArchiveInventory.maximumEntries).contains($0.entryCount)
                      && Self.isHex($0.sha256, count: 64) && Self.isHex($0.inventorySHA256, count: 64)
                      && Self.isHex($0.md5, count: 32)
              }) else { throw CloudArchiveError.invalidManifest }
        return manifest
    }

    public func upload(_ game: CloudArchiveGame, progress: Progress? = nil) async throws -> CloudGameManifest {
        try await upload(game, kinds: Set(CloudArtifactKind.allCases), progress: progress)
    }

    public func upload(_ game: CloudArchiveGame, kinds: Set<CloudArtifactKind>, progress: Progress? = nil) async throws -> CloudGameManifest {
        let lease = try begin(game.titleID)
        defer { leases.end(game.titleID, token: lease) }
        guard let uploader = backend as? RcloneStorageBackend else { throw StorageBackendError.backendUnavailable }
        let selected = CloudArtifactKind.allCases.filter { kinds.contains($0) }
        guard !selected.isEmpty else { throw CloudArchiveError.needsFullUpload }
        var artifacts: [Artifact] = []
        var gameName: String?, bundleName: String?
        var sourceSelection = game.sourceSelection
        if selected.count == 1 {
            do {
                let previous = try await latest(titleID: game.titleID)
                if let retained = previous?.artifacts.first(where: { !kinds.contains($0.kind) }) {
                    progress?(.init(.verifying))
                    try await backend.verify(retained.object(titleID: game.titleID))
                    artifacts.append(retained)
                    gameName = previous?.gameName
                    bundleName = previous?.bundleName
                } else {
                    guard selected == [.app], try previous != nil || hasNoLocalCache(game) else {
                        throw CloudArchiveError.needsFullUpload
                    }
                }
                sourceSelection = sourceSelection ?? previous?.sourceSelection
            } catch CloudArchiveError.invalidManifest, StorageBackendError.notFound, StorageBackendError.hashMismatch {
                throw CloudArchiveError.needsFullUpload
            }
        }
        let snapshots = try selected.map { kind in
            progress?(.init(.archiving, kind: kind))
            let source = try location(kind, for: game)
            let parent = try CloudArchiveInventory.node(at: source.deletingLastPathComponent())
            let signature = try CloudArchiveInventory.signature(source, kind: kind)
            let snapshot = try CloudArchiveInventory.scan(source, kind: kind)
            guard !snapshot.hasExcludedFiles, !signature.hasExcludedFiles else { throw CloudArchiveError.excludedFiles }
            guard !snapshot.isSkippedOnly else { throw CloudArchiveError.localMissing }
            return (source, parent, snapshot, signature.sha256)
        }
        var staged: [(RcloneStorageBackend.ArchiveUpload, Artifact)] = []
        var pending: [RcloneStorageBackend.ArchiveUpload] = []
        do {
            for (index, kind) in selected.enumerated() {
                progress?(.init(.archiving, kind: kind))
                let (source, parent, initial, signature) = snapshots[index]
                let temporary = try uploader.archiveUpload()
                pending.append(temporary)
                let update = transfer(progress, phase: .uploading, kind: kind, total: initial.bytes)
                // Omit -o: aa treats a literal "-" as a filename, not stdout.
                let stream = try await CloudArchiveStream.send(
                    ["archive", "-d", source.path, "-a", "lzfse", "-t", "2", "-x", "-include-field", "siz"]
                        + CloudArchiveInventory.archiveExclusions(kind),
                    to: uploader.archiveUploadProcess(to: temporary), kind: kind, estimatedBytes: initial.bytes, progress: update)
                progress?(.init(.verifying, kind: kind))
                if let (path, reason) = firstDifference(from: initial.entries, to: stream.entries) {
                    throw CloudArchiveError.uploadMismatch(kind, path: path.isEmpty ? "." : path, reason: reason)
                }
                guard (try? sameDirectory(parent, at: source.deletingLastPathComponent())) == true else {
                    throw CloudArchiveError.uploadMismatch(kind, path: "..", reason: .parentDirectory)
                }
                guard stream.fingerprint == initial.sha256 else { throw CloudArchiveError.localChanged }
                let info = kind == .app ? try await verifiedApp(source, titleID: game.titleID) : [:]
                let chain = shaderChain(at: source, kind: kind)
                try Task.checkCancellation()
                guard try CloudArchiveInventory.signature(source, kind: kind).sha256 == signature else {
                    throw CloudArchiveError.localChanged
                }
                if kind == .app {
                    gameName = info["CFBundleDisplayName"] ?? info["CFBundleName"]
                        ?? source.deletingPathExtension().lastPathComponent
                    bundleName = source.lastPathComponent
                }
                var options = info.filter { ["DMLanguage", "CFBundleShortVersionString"].contains($0.key) }
                // A skipped directory can change the cache root mtime without changing the archived files.
                options[CloudArchiveInventory.cacheFingerprintOption] = initial.withoutRootMtime
                let artifact = Artifact(kind: kind, size: stream.bytes, sha256: stream.sha256, md5: stream.md5,
                                        unpackedSize: initial.bytes, entryCount: initial.entries.count,
                                        inventorySHA256: initial.sha256, engineCommit: info["DMCommit"] ?? game.engineCommit,
                                        shaderChain: chain, options: options)
                try await uploader.verifyArchive(artifact.object(titleID: game.titleID), staged: temporary)
                staged.append((temporary, artifact))
                artifacts.append(artifact)
            }
            for (temporary, artifact) in staged {
                try await uploader.publishArchive(artifact.object(titleID: game.titleID), staged: temporary)
            }
        } catch {
            await uploader.discardArchives(pending)
            if error as? StorageBackendError == .publicationFailed { throw CloudArchiveError.installFailed }
            throw error
        }
        if artifacts.first?.kind == .cache { artifacts.swapAt(0, 1) }
        progress?(.init(.verifying))
        let now = Date()
        let manifest = CloudGameManifest(version: 1, titleID: game.titleID,
                                         createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
                                         artifacts: artifacts, gameName: gameName, bundleName: bundleName,
                                         sourceSelection: sourceSelection)
        let stage = try staging(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: stage) }
        let file = stage.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= Self.manifestLimit else { throw CloudArchiveError.invalidManifest }
        try data.write(to: file)
        let hashes = try CloudArchiveInventory.hashes(at: file)
        let timestamp = String(format: "%016lld", Int64(now.timeIntervalSince1970 * 1000))
        let key = StorageObjectKey("\(game.titleID)/manifests/\(timestamp)-\(hashes["sha256"]!).json")
        try await put(file, object: StorageObject(key: key, size: Int64(data.count), hashes: hashes), progress: nil)
        return manifest
    }

    public func free(_ kind: CloudArtifactKind, for game: CloudArchiveGame, confirmed: Bool,
                     beforeMutation: @Sendable () throws -> Void = {}) async throws {
        guard confirmed else { throw CloudArchiveError.confirmationRequired }
        let lease = try begin(game.titleID)
        defer { leases.end(game.titleID, token: lease) }
        let target = try location(kind, for: game)
        let parent = target.deletingLastPathComponent()
        let volume = try CloudArchiveInventory.node(at: parent)
        let before = try CloudArchiveInventory.node(at: target)
        let artifact = try await remoteArtifact(kind, game)
        let object = artifact.object(titleID: game.titleID)
        try await backend.verify(StorageObject(key: object.key, size: object.size, hashes: ["sha256": artifact.sha256]))
        let snapshot = try CloudArchiveInventory.scan(target, kind: kind)
        guard !snapshot.hasExcludedFiles else { throw CloudArchiveError.excludedFiles }
        guard !snapshot.isSkippedOnly else { throw CloudArchiveError.localMissing }
        guard Fingerprint(signature: "", sha256: snapshot.sha256, withoutRootMtime: snapshot.withoutRootMtime).matches(artifact),
              try sameDirectory(volume, at: parent),
              try sameNode(before, at: target) else { throw CloudArchiveError.localChanged }
        try beforeMutation()
        try Task.checkCancellation()
        if snapshot.skippedRoots.isEmpty {
            try trash(target)
        } else {
            let stage = try staging(in: parent)
            let bucket = stage.appendingPathComponent(target.lastPathComponent, isDirectory: true)
            var keepStage = false
            defer { if !keepStage { try? FileManager.default.removeItem(at: stage) } }
            try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: false)
            let roots = snapshot.entries.map(\.path).filter { !$0.isEmpty && !$0.contains("/") }
            try moving(roots, from: target, to: bucket, keepStage: &keepStage) { try trash(bucket) }
        }
    }

    private func hasNoLocalCache(_ game: CloudArchiveGame) throws -> Bool {
        guard game.locations[.cache] != nil else { return !game.cacheIsRegistered }
        let cache = try location(.cache, for: game)
        let parent = try CloudArchiveInventory.node(at: cache.deletingLastPathComponent())
        if try existingNode(at: cache) == nil { return try sameDirectory(parent, at: cache.deletingLastPathComponent()) }
        let signature = try CloudArchiveInventory.signature(cache, kind: .cache)
        return signature.isSkippedOnly
    }

    /// Publishes in one same-volume rename. An existing copy is retained in the private staging directory.
    /// The UI only downloads missing artifacts; a caller that explicitly replaces gets the previous copy's location.
    @discardableResult
    public func restore(_ kind: CloudArtifactKind, for game: CloudArchiveGame,
                        onlyIfMissing: Bool = false, progress: Progress? = nil,
                        beforeMutation: @Sendable () throws -> Void = {}) async throws -> URL? {
        let lease = try begin(game.titleID)
        defer { leases.end(game.titleID, token: lease) }
        progress?(.init(.verifying, kind: kind))
        let destination = try location(kind, for: game)
        let parent = destination.deletingLastPathComponent()
        let volume = try CloudArchiveInventory.node(at: parent)
        let previous = try existingNode(at: destination)
        guard previous.map({ $0.st_mode & S_IFMT == S_IFDIR }) ?? true else {
            throw CloudArchiveError.unsafePath
        }
        let existing = kind == .cache && previous != nil ? try CloudArchiveInventory.signature(destination, kind: .cache) : nil
        guard existing?.hasExcludedFiles != true else { throw CloudArchiveError.excludedFiles }
        let skippedOnly = existing?.isSkippedOnly == true
        guard previous == nil || !onlyIfMissing || skippedOnly else {
            throw CloudArchiveError.unsafePath
        }
        let artifact = try await remoteArtifact(kind, game)
        try requireSpace(in: parent, bytes: artifact.unpackedSize, entries: artifact.entryCount, archive: artifact.size)
        let stage = try staging(in: parent)
        var keepStage = false
        defer { if !keepStage { try? FileManager.default.removeItem(at: stage) } }
        let archive = stage.appendingPathComponent("item.aar")
        try await backend.get(artifact.object(titleID: game.titleID).key, to: archive,
                              progress: transfer(progress, phase: .downloading, kind: kind, total: artifact.size))
        progress?(.init(.verifying, kind: kind))
        guard try CloudArchiveInventory.node(at: archive).st_size == artifact.size,
              try CloudArchiveInventory.hashes(at: archive, includeMD5: false)["sha256"] == artifact.sha256
        else { throw StorageBackendError.hashMismatch }
        let entries = try await inventory(in: archive, kind: kind)
        guard entries.count == artifact.entryCount,
              try CloudArchiveInventory.validate(entries, kind: kind) == artifact.unpackedSize
        else { throw CloudArchiveError.invalidArchive }
        try requireSpace(in: parent, bytes: artifact.unpackedSize, entries: artifact.entryCount)
        let incoming = stage.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        progress?(.init(.restoring, kind: kind))
        _ = try await unpack(archive, to: incoming, kind: kind, titleID: game.titleID,
                             listed: entries, fingerprint: artifact.inventorySHA256)
        try beforeMutation()
        guard try sameDirectory(volume, at: parent),
              try sameNode(previous, at: destination) else { throw CloudArchiveError.localChanged }
        try Task.checkCancellation()
        let flags = previous == nil ? RENAME_EXCL : RENAME_SWAP
        try moving(existing?.skippedRoots ?? [], from: destination, to: incoming, keepStage: &keepStage) {
            guard renamex_np(incoming.path, destination.path, UInt32(flags)) == 0 else { throw CloudArchiveError.installFailed }
        }
        // An external writer may have added data while the old directory was still live.
        if previous != nil, !skippedOnly || rmdir(incoming.path) != 0 {
            keepStage = true
            try? FileManager.default.removeItem(at: archive)
            return incoming
        }
        return nil
    }

    private func moving(_ names: [String], from source: URL, to target: URL, keepStage: inout Bool,
                        publish: () throws -> Void) throws {
        guard !names.isEmpty else { return try publish() }
        let before = try CloudArchiveInventory.node(at: target)
        var moved: [String] = []
        do {
            for name in names {
                guard renamex_np(source.appendingPathComponent(name).path, target.appendingPathComponent(name).path,
                                 UInt32(RENAME_EXCL)) == 0 else { throw CloudArchiveError.installFailed }
                moved.append(name)
            }
            var times = [before.st_atimespec, before.st_mtimespec]
            guard utimensat(AT_FDCWD, target.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw CloudArchiveError.installFailed
            }
            try publish()
        } catch {
            for name in moved.reversed() {
                if renamex_np(target.appendingPathComponent(name).path, source.appendingPathComponent(name).path,
                              UInt32(RENAME_EXCL)) != 0 { keepStage = true }
            }
            throw error
        }
    }

    private func begin(_ titleID: String) throws -> UUID {
        guard SaveLocation.validID(titleID) else { throw CloudArchiveError.unsafePath }
        guard let lease = leases.begin(titleID) else { throw CloudArchiveError.busy }
        return lease
    }

    private func remoteArtifact(_ kind: CloudArtifactKind, _ game: CloudArchiveGame) async throws -> Artifact {
        guard let artifact = try await latest(titleID: game.titleID)?.artifacts.first(where: { $0.kind == kind }) else {
            throw CloudArchiveError.noRemoteCopy
        }
        return artifact
    }

    private nonisolated func location(_ kind: CloudArtifactKind, for game: CloudArchiveGame) throws -> URL {
        guard let url = game.locations[kind], url.isFileURL else { throw CloudArchiveError.localMissing }
        let original = url.standardizedFileURL
        let parent = original.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path != "/", kind == .app ? original.pathExtension.lowercased() == "app"
              : original.lastPathComponent.uppercased() == "\(game.titleID)_BUILD" else {
            throw CloudArchiveError.unsafePath
        }
        return parent.appendingPathComponent(original.lastPathComponent, isDirectory: true)
    }

    private nonisolated func existingNode(at url: URL) throws -> stat? {
        do { return try CloudArchiveInventory.node(at: url) }
        catch CloudArchiveError.localMissing { return nil }
    }

    private func sameNode(_ old: stat?, at url: URL) throws -> Bool {
        let current = try existingNode(at: url)
        guard let old, let current else { return old == nil && current == nil }
        return old.st_dev == current.st_dev && old.st_ino == current.st_ino
            && old.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec && old.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec
    }

    private nonisolated func sameDirectory(_ old: stat, at url: URL) throws -> Bool {
        try SaveFiles.safePath(url)
        let current = try CloudArchiveInventory.node(at: url)
        return current.st_mode & S_IFMT == S_IFDIR && old.st_dev == current.st_dev && old.st_ino == current.st_ino
    }

    private func staging(in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(".arcane-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func requireSpace(in directory: URL, bytes: Int64, entries: Int, archive: Int64 = 0) throws {
        let overhead = Int64(entries) * 16_384 + 1_048_576
        guard bytes <= Int64.max - overhead, archive <= Int64.max - overhead - bytes,
              let free = capacity(directory), free >= bytes + overhead + archive else {
            throw CloudArchiveError.insufficientSpace
        }
    }

    private func inventory(in archive: URL, kind: CloudArtifactKind) async throws -> [CloudArchiveInventory.Entry] {
        let result = try await command("aa", ["list", "-i", archive.path, "-list-format", "json"])
        guard let entries = try? JSONDecoder().decode([CloudArchiveInventory.Entry].self, from: Data(result.utf8)),
              entries.count <= CloudArchiveInventory.maximumEntries else { throw CloudArchiveError.invalidArchive }
        _ = try CloudArchiveInventory.validate(entries, kind: kind)
        return entries
    }

    private func unpack(_ archive: URL, to incoming: URL, kind: CloudArtifactKind, titleID: String,
                        listed: [CloudArchiveInventory.Entry], fingerprint: String) async throws -> [String: String] {
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        _ = try await command("aa", ["extract", "-i", archive.path, "-d", incoming.path,
                                    "-exclude-field", "uid,gid,flg,acl"])
        let result = try CloudArchiveInventory.scan(incoming, kind: kind)
        guard ordered(result.entries) == ordered(listed), result.sha256 == fingerprint,
              !result.hasExcludedFiles, result.skippedRoots.isEmpty else { throw CloudArchiveError.invalidArchive }
        return kind == .app ? try await verifiedApp(incoming, titleID: titleID) : [:]
    }

    private func ordered(_ entries: [CloudArchiveInventory.Entry]) -> [CloudArchiveInventory.Entry] {
        entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private func firstDifference(from initial: [CloudArchiveInventory.Entry], to listed: [CloudArchiveInventory.Entry])
        -> (String, CloudArchiveError.UploadDifference)? {
        let before = ordered(initial), after = ordered(listed)
        for (old, new) in zip(before, after) where old != new {
            if old.path != new.path {
                return old.path.utf8.lexicographicallyPrecedes(new.path.utf8)
                    ? (old.path, .removed) : (new.path, .added)
            }
            if old.type != new.type { return (old.path, .type) }
            if old.size != new.size { return (old.path, .size) }
            if old.link != new.link { return (old.path, .linkTarget) }
            return (old.path, .permissions)
        }
        if before.count > after.count { return (before[after.count].path, .removed) }
        if after.count > before.count { return (after[before.count].path, .added) }
        return nil
    }

    private func verifiedApp(_ app: URL, titleID: String) async throws -> [String: String] {
        let info = try ImportService.verifiedIdentity(of: app, titleID: titleID)
        _ = try await command("codesign", ImportService.signatureArguments(for: app), failure: .invalidApp)
        return info.compactMapValues { $0 as? String }
    }

    private func shaderChain(at source: URL, kind: CloudArtifactKind) -> String? {
        let folder = source.appendingPathComponent(kind == .app ? "Contents/Resources/msl" : "shader/cache")
        let matches = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.compactMap { name -> String? in
            guard name.hasPrefix("b-"), name.hasSuffix(".img") else { return nil }
            let id = String(name.dropFirst(2).dropLast(4))
            return Self.isHex(id, count: 12) ? id : nil
        }
        return matches?.count == 1 ? matches?.first : nil
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func command(_ tool: String, _ args: [String], failure: CloudArchiveError = .invalidArchive) async throws -> String {
        let result = try await SystemCommandRunner().runCancellable(URL(fileURLWithPath: "/usr/bin/" + tool), args, environment: nil)
        guard result.status == 0 else { throw failure }
        return result.stdout
    }

    private func put(_ file: URL, object: StorageObject, progress: (@Sendable (StorageProgress) -> Void)?) async throws {
        do { try await backend.put(file, as: object, progress: progress) }
        catch StorageBackendError.alreadyExists { /* Reuse only after checking the exact object. */ }
        try await backend.verify(object)
    }

    private func transfer(_ progress: Progress?, phase: CloudArchiveProgress.Phase, kind: CloudArtifactKind,
                          total: Int64) -> (@Sendable (StorageProgress) -> Void)? {
        guard let progress else { return nil }
        progress(.init(phase, kind: kind, transfer: StorageProgress(bytesTransferred: 0, totalBytes: total)))
        return { value in
            progress(value.isVerifying ? .init(.verifying, kind: kind) : .init(phase, kind: kind, transfer: value))
        }
    }
}
