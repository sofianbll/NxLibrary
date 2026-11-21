import Darwin
import Foundation
import NXLibraryCore

public enum CloudArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case app, cache
}

public enum CloudAppAvailability: Equatable {
    case unknown, cloudCopy, cloudOnly

    public init(remote: Set<CloudArtifactKind>?, localApp: Bool?) {
        if remote?.contains(.app) == true { self = localApp == false ? .cloudOnly : .cloudCopy }
        else { self = .unknown }
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

    public init(titleID: String, locations: [CloudArtifactKind: URL], engineCommit: String? = nil) {
        self.titleID = titleID.uppercased()
        self.locations = locations
        self.engineCommit = engineCommit
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

    enum CodingKeys: String, CodingKey {
        case version, artifacts
        case titleID = "title_id", createdAt = "created_at"
    }
}

public enum CloudArchiveError: LocalizedError, Equatable {
    public enum UploadDifference: String {
        case added, removed, type, size, linkTarget, permissions, parentDirectory
    }

    case busy, confirmationRequired, insufficientSpace, unsafePath, localMissing
    case noRemoteCopy, invalidManifest, invalidArchive, invalidApp, localChanged, excludedFiles, installFailed
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
    case allowed, missingSources, downloadCache

    static func decide(sourcesAvailable: Bool, remoteCache: Bool, localVerified: Bool,
                       withoutCache: Bool) -> Self {
        if !sourcesAvailable { return .missingSources }
        return remoteCache && !localVerified && !withoutCache ? .downloadCache : .allowed
    }
}

public actor CloudGameArchive {
    public typealias Progress = @Sendable (CloudArchiveProgress) -> Void
    private typealias Artifact = CloudGameManifest.Artifact
    private static let manifestLimit = 64 * 1024
    private let backend: any StorageBackend
    private let capacity: @Sendable (URL) -> Int64?
    private let trash: @Sendable (URL) throws -> Void
    private var activeTitles: [String: UUID] = [:]

    public init(backend: any StorageBackend) {
        self.init(backend: backend, trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }

    internal init(backend: any StorageBackend,
                  capacity: @escaping @Sendable (URL) -> Int64? = {
                      (try? FileManager.default.attributesOfFileSystem(forPath: $0.path)[.systemFreeSize] as? NSNumber)?.int64Value
                  },
                  trash: @escaping @Sendable (URL) throws -> Void) {
        self.backend = backend
        self.capacity = capacity
        self.trash = trash
    }

    /// An unavailable or unsafe path is not an absent directory.
    public func localStatus(_ game: CloudArchiveGame) -> [CloudArtifactKind: Bool] {
        var status: [CloudArtifactKind: Bool] = [:]
        for kind in CloudArtifactKind.allCases {
            guard let url = try? location(kind, for: game),
                  let parent = try? CloudArchiveInventory.node(at: url.deletingLastPathComponent()),
                  parent.st_mode & S_IFMT == S_IFDIR else { continue }
            do {
                if let node = try existingNode(at: url) {
                    if node.st_mode & S_IFMT == S_IFDIR { status[kind] = true }
                } else { status[kind] = false }
            } catch { continue }
        }
        return status
    }

    /// Hold the same title lease as upload, free and restore until the engine exits.
    public func beginBuild(titleID: String) throws -> UUID {
        try begin(titleID.uppercased())
    }

    public func endBuild(titleID: String, token: UUID) {
        let title = titleID.uppercased()
        if activeTitles[title] == token { activeTitles[title] = nil }
    }

    public func checkRebuild(_ game: CloudArchiveGame, sourcesAvailable: Bool, withoutCache: Bool)
        async throws -> (decision: CloudRebuildDecision, verifiedCache: URL?) {
        guard sourcesAvailable else { return (.missingSources, nil) }
        guard !withoutCache else { return (.allowed, nil) }
        let artifact = try await latest(titleID: game.titleID)?.artifacts.first { $0.kind == .cache }
        let cache = try? location(.cache, for: game)
        let verified = artifact.flatMap { artifact in
            cache.flatMap { url in
                (try? CloudArchiveInventory.scan(url, kind: .cache).sha256) == artifact.inventorySHA256 ? url : nil
            }
        }
        return (.decide(sourcesAvailable: sourcesAvailable, remoteCache: artifact != nil,
                        localVerified: verified != nil, withoutCache: withoutCache), verified)
    }

    public func latest(titleID: String) async throws -> CloudGameManifest? {
        let title = titleID.uppercased()
        guard SaveLocation.validID(title) else { throw CloudArchiveError.unsafePath }
        let directory = StorageObjectKey("\(title)/manifests")
        guard let newest = try await backend.list(in: directory)
            .filter({ $0.key.value.hasPrefix(directory.value + "/") && $0.key.value.hasSuffix(".json") })
            .max(by: { $0.key.value < $1.key.value }) else { return nil }
        let name = newest.key.value.dropFirst(directory.value.count + 1).dropLast(5)
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 16, Int64(parts[0]) != nil, Self.isHex(String(parts[1]), count: 64),
              (1...Int64(Self.manifestLimit)).contains(newest.size) else { throw CloudArchiveError.invalidManifest }
        let stage = try staging(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: stage) }
        let file = stage.appendingPathComponent("manifest.json")
        try await backend.get(newest.key, to: file)
        let data = try SaveFiles.readRegular(file, limit: Self.manifestLimit)
        guard Int64(data.count) == newest.size,
              try CloudArchiveInventory.hashes(at: file, includeMD5: false)["sha256"] == String(parts[1])
        else { throw CloudArchiveError.invalidManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(CloudGameManifest.self, from: data),
              manifest.version == 1, manifest.titleID == title,
              manifest.artifacts.map(\.kind) == CloudArtifactKind.allCases,
              manifest.artifacts.allSatisfy({
                  $0.size > 0 && $0.unpackedSize >= 0 && (1...CloudArchiveInventory.maximumEntries).contains($0.entryCount)
                      && Self.isHex($0.sha256, count: 64) && Self.isHex($0.inventorySHA256, count: 64)
                      && Self.isHex($0.md5, count: 32)
              }) else { throw CloudArchiveError.invalidManifest }
        return manifest
    }

    public func upload(_ game: CloudArchiveGame, progress: Progress? = nil) async throws -> CloudGameManifest {
        _ = try begin(game.titleID)
        defer { activeTitles[game.titleID] = nil }
        let snapshots = try CloudArtifactKind.allCases.map { kind in
            progress?(.init(.archiving, kind: kind))
            let source = try location(kind, for: game)
            let snapshot = try CloudArchiveInventory.scan(source, kind: kind)
            guard !snapshot.hasExcludedFiles else { throw CloudArchiveError.excludedFiles }
            return (source, snapshot)
        }
        var artifacts: [Artifact] = []
        for (index, kind) in CloudArtifactKind.allCases.enumerated() {
            progress?(.init(.archiving, kind: kind))
            let (source, initial) = snapshots[index]
            let parent = source.deletingLastPathComponent()
            let volume = try CloudArchiveInventory.node(at: parent)
            try requireSpace(in: parent, bytes: initial.bytes, entries: initial.entries.count)
            let stage = try staging(in: parent)
            defer { try? FileManager.default.removeItem(at: stage) }
            let archive = stage.appendingPathComponent("item.aar")
            let exclusions = CloudArchiveInventory.excludedPaths(kind).flatMap { ["-exclude-path", $0] }
                + CloudArchiveInventory.excludedNames.flatMap { ["-exclude-name", $0] }
            _ = try await command("aa", ["archive", "-d", source.path, "-o", archive.path, "-a", "lzfse", "-x",
                                         "-include-field", "siz"] + exclusions)
            progress?(.init(.verifying, kind: kind))
            let listed = try await inventory(in: archive, kind: kind)
            if let (path, reason) = firstDifference(from: initial.entries, to: listed) {
                throw CloudArchiveError.uploadMismatch(kind, path: path.isEmpty ? "." : path, reason: reason)
            }
            guard (try? sameDirectory(volume, at: parent)) == true else {
                throw CloudArchiveError.uploadMismatch(kind, path: "..", reason: .parentDirectory)
            }
            try requireSpace(in: parent, bytes: initial.bytes, entries: initial.entries.count)
            let check = stage.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            let info = try await unpack(archive, to: check, kind: kind, titleID: game.titleID,
                                        listed: listed, fingerprint: initial.sha256)
            let hashes = try CloudArchiveInventory.hashes(at: archive)
            let artifact = Artifact(kind: kind, size: try CloudArchiveInventory.node(at: archive).st_size,
                                    sha256: hashes["sha256"]!, md5: hashes["md5"]!,
                                    unpackedSize: initial.bytes, entryCount: initial.entries.count,
                                    inventorySHA256: initial.sha256, engineCommit: info["DMCommit"] ?? game.engineCommit,
                                    shaderChain: shaderChain(at: check, kind: kind),
                                    options: info.filter { ["DMLanguage", "CFBundleShortVersionString"].contains($0.key) })
            let object = artifact.object(titleID: game.titleID)
            let update = transfer(progress, phase: .uploading, kind: kind, total: object.size)
            try await put(archive, object: object, progress: update, beforeVerify: {
                progress?(.init(.verifying, kind: kind))
            })
            artifacts.append(artifact)
        }
        progress?(.init(.verifying))
        let now = Date()
        let manifest = CloudGameManifest(version: 1, titleID: game.titleID, createdAt: now, artifacts: artifacts)
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
        // The wire timestamp has second resolution.
        return CloudGameManifest(version: manifest.version, titleID: manifest.titleID,
                                 createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)), artifacts: artifacts)
    }

    public func free(_ kind: CloudArtifactKind, for game: CloudArchiveGame, confirmed: Bool,
                     beforeMutation: @Sendable () throws -> Void = {}) async throws {
        guard confirmed else { throw CloudArchiveError.confirmationRequired }
        _ = try begin(game.titleID)
        defer { activeTitles[game.titleID] = nil }
        let target = try location(kind, for: game)
        let parent = target.deletingLastPathComponent()
        let volume = try CloudArchiveInventory.node(at: parent)
        let before = try CloudArchiveInventory.node(at: target)
        let artifact = try await remoteArtifact(kind, game)
        let object = artifact.object(titleID: game.titleID)
        try await backend.verify(StorageObject(key: object.key, size: object.size, hashes: ["sha256": artifact.sha256]))
        let snapshot = try CloudArchiveInventory.scan(target, kind: kind)
        guard !snapshot.hasExcludedFiles else { throw CloudArchiveError.excludedFiles }
        guard snapshot.sha256 == artifact.inventorySHA256, try sameDirectory(volume, at: parent),
              try sameNode(before, at: target) else { throw CloudArchiveError.localChanged }
        try beforeMutation()
        try Task.checkCancellation()
        try trash(target)
    }

    /// Publishes in one same-volume rename. An existing copy is retained in the private staging directory.
    /// The UI only downloads missing artifacts; a caller that explicitly replaces gets the previous copy's location.
    @discardableResult
    public func restore(_ kind: CloudArtifactKind, for game: CloudArchiveGame,
                        onlyIfMissing: Bool = false, progress: Progress? = nil,
                        beforeMutation: @Sendable () throws -> Void = {}) async throws -> URL? {
        _ = try begin(game.titleID)
        defer { activeTitles[game.titleID] = nil }
        progress?(.init(.verifying, kind: kind))
        let destination = try location(kind, for: game)
        let parent = destination.deletingLastPathComponent()
        let volume = try CloudArchiveInventory.node(at: parent)
        let previous = try existingNode(at: destination)
        guard previous.map({ $0.st_mode & S_IFMT == S_IFDIR && !onlyIfMissing }) ?? true else {
            throw CloudArchiveError.unsafePath
        }
        if kind == .cache, previous != nil, try CloudArchiveInventory.scan(destination, kind: .cache).hasExcludedFiles {
            throw CloudArchiveError.excludedFiles
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
        guard renamex_np(incoming.path, destination.path, UInt32(flags)) == 0 else { throw CloudArchiveError.installFailed }
        if previous != nil {
            keepStage = true
            try? FileManager.default.removeItem(at: archive)
            return incoming
        }
        return nil
    }

    private func begin(_ titleID: String) throws -> UUID {
        guard SaveLocation.validID(titleID) else { throw CloudArchiveError.unsafePath }
        guard activeTitles[titleID] == nil else { throw CloudArchiveError.busy }
        let token = UUID()
        activeTitles[titleID] = token
        return token
    }

    private func remoteArtifact(_ kind: CloudArtifactKind, _ game: CloudArchiveGame) async throws -> Artifact {
        guard let artifact = try await latest(titleID: game.titleID)?.artifacts.first(where: { $0.kind == kind }) else {
            throw CloudArchiveError.noRemoteCopy
        }
        return artifact
    }

    private func location(_ kind: CloudArtifactKind, for game: CloudArchiveGame) throws -> URL {
        guard let url = game.locations[kind], url.isFileURL else { throw CloudArchiveError.localMissing }
        let original = url.standardizedFileURL
        let parent = original.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path != "/", kind == .app ? original.pathExtension.lowercased() == "app"
              : original.lastPathComponent.uppercased() == "\(game.titleID)_BUILD" else {
            throw CloudArchiveError.unsafePath
        }
        return parent.appendingPathComponent(original.lastPathComponent, isDirectory: true)
    }

    private func existingNode(at url: URL) throws -> stat? {
        do { return try CloudArchiveInventory.node(at: url) }
        catch CloudArchiveError.localMissing { return nil }
    }

    private func sameNode(_ old: stat?, at url: URL) throws -> Bool {
        let current = try existingNode(at: url)
        guard let old, let current else { return old == nil && current == nil }
        return old.st_dev == current.st_dev && old.st_ino == current.st_ino
            && old.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec && old.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec
    }

    private func sameDirectory(_ old: stat, at url: URL) throws -> Bool {
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
              !result.hasExcludedFiles else { throw CloudArchiveError.invalidArchive }
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
        let file = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? SaveFiles.readRegular(file, limit: 1_048_576),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (info["DMTitleID"] as? String)?.uppercased() == titleID else { throw CloudArchiveError.invalidApp }
        _ = try await command("codesign", ["--verify", "--deep", "--strict", app.path], failure: .invalidApp)
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

    private func put(_ file: URL, object: StorageObject, progress: (@Sendable (StorageProgress) -> Void)?,
                     beforeVerify: () -> Void = {}) async throws {
        do { try await backend.put(file, as: object, progress: progress) }
        catch StorageBackendError.alreadyExists { /* Reuse only after checking the exact object. */ }
        beforeVerify()
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
