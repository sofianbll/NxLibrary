import CryptoKit
import Darwin
import Foundation
import NXLibraryCore

public struct CloudSourcesStatus: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let url: URL
        public let state: CloudArtifactStatus.State
        public let localBytes: Int64?
        public let remoteBytes: Int64?
    }

    public let files: [File]
    public let state: CloudArtifactStatus.State
    public let localBytes: Int64
    public let remoteBytes: Int64
}

public final class CloudGameSources: @unchecked Sendable {
    public typealias Progress = @Sendable (StorageProgress) -> Void

    private let backend: RcloneStorageBackend
    private let trash: @Sendable (URL) throws -> Void
    private let lock = NSLock()
    private var fingerprints: [URL: (stamp: Stamp, md5: String)] = [:]

    public convenience init(backend: RcloneStorageBackend, root: String) {
        self.init(backend: backend, root: root) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }

    init(backend: RcloneStorageBackend, root: String, trash: @escaping @Sendable (URL) throws -> Void) {
        self.backend = backend.atRoot(root)
        self.trash = trash
    }

    public func status(folderName: String, files: [URL]) async throws -> CloudSourcesStatus {
        let selection = try Selection(folderName, files)
        let remote = try await remoteFiles(selection)
        var statuses: [CloudSourcesStatus.File] = []
        for source in selection.files {
            try Task.checkCancellation()
            let item = remote[source.lastPathComponent]
            let local = try stamp(at: source)
            let state: CloudArtifactStatus.State
            if let item {
                if let md5 = item.md5 {
                    if let local {
                        let matches = local.bytes == item.size ? try await hash(source, stamp: local) == md5 : false
                        state = matches ? .synchronized : .newerOnThisMac
                    } else { state = .cloudOnly }
                } else { state = .unknown }
            } else { state = local == nil ? .unknown : .notInCloud }
            statuses.append(.init(url: source, state: state, localBytes: local?.bytes,
                                  remoteBytes: item.flatMap { $0.size >= 0 ? $0.size : nil }))
        }
        try Task.checkCancellation()
        // A missing local and a missing remote file require different actions.
        let states = Set(statuses.map(\.state))
        let state: CloudArtifactStatus.State
        if states.contains(.newerOnThisMac) { state = .newerOnThisMac }
        else if states.contains(.unknown) || states.isEmpty { state = .unknown }
        else if states.contains(.notInCloud) && states.contains(.cloudOnly) { state = .unknown }
        else if states.contains(.notInCloud) { state = .notInCloud }
        else if states.contains(.cloudOnly) { state = .cloudOnly }
        else { state = .synchronized }
        return try .init(files: statuses, state: state, localBytes: total(statuses.compactMap(\.localBytes)),
                         remoteBytes: total(statuses.compactMap(\.remoteBytes)))
    }

    public func upload(folderName: String, files: [URL], progress: Progress?) async throws {
        let selection = try Selection(folderName, files)
        guard let lease = backend.leases.begin(selection.title) else { throw CloudArchiveError.busy }
        defer { backend.leases.end(selection.title, token: lease) }
        let remote = try await remoteFiles(selection)
        var pending: [(URL, Stamp)] = []
        for source in selection.files {
            let local = try stamp(at: source)
            if let item = remote[source.lastPathComponent] {
                guard let md5 = item.md5 else { throw CloudArchiveError.invalidArchive }
                if let local {
                    guard local.bytes == item.size, try await hash(source, stamp: local) == md5 else {
                        throw CloudArchiveError.sourcesConflict
                    }
                }
            } else {
                guard let local else { throw CloudArchiveError.localMissing }
                pending.append((source, local))
            }
        }
        let bytes = try total(pending.map { $0.1.bytes })
        var sent: Int64 = 0
        for (source, stamp) in pending {
            let md5 = try await hash(source, stamp: stamp)
            let key = StorageObjectKey(selection.directory.value + "/" + source.lastPathComponent)
            let object = StorageObject(key: key, size: stamp.bytes, hashes: ["md5": md5])
            do {
                try await backend.putSource(source, as: object, progress: transfer(progress, offset: sent, bytes: bytes, fileBytes: stamp.bytes))
            } catch StorageBackendError.alreadyExists { /* Check the competing copy below. */ }
            catch StorageBackendError.hashMismatch {
                throw CloudArchiveError.invalidArchive
            }
            catch StorageBackendError.publicationFailed {
                throw CloudArchiveError.installFailed
            }
            let item = try await remoteFiles(selection)[source.lastPathComponent]
            guard item?.size == stamp.bytes, item?.md5 == md5 else { throw CloudArchiveError.sourcesConflict }
            sent += stamp.bytes
            progress?(.init(bytesTransferred: sent, totalBytes: bytes))
        }
        try Task.checkCancellation()
    }

    public func download(folderName: String, files: [URL], progress: Progress?) async throws {
        let selection = try Selection(folderName, files)
        guard let lease = backend.leases.begin(selection.title) else { throw CloudArchiveError.busy }
        defer { backend.leases.end(selection.title, token: lease) }
        let pending = try await downloads(selection)
        let bytes = try total(pending.map { $0.1.size })
        var received: Int64 = 0
        for (destination, item) in pending {
            try Task.checkCancellation()
            let parent = destination.deletingLastPathComponent()
            let directory = try Stamp.directory(parent)
            let staging = parent.appendingPathComponent(".arcane-sources-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let candidate = staging.appendingPathComponent("file")
            // Use the cancellable CLI for every payload, not an RC job that can outlive its caller.
            try await backend.get(item.key, to: candidate,
                                  progress: transfer(progress, offset: received, bytes: bytes, fileBytes: item.size) ?? { _ in })
            progress?(.init(bytesTransferred: received + item.size, totalBytes: bytes, isVerifying: true))
            guard let snapshot = try stamp(at: candidate), snapshot.bytes == item.size,
                  try await hash(candidate, stamp: snapshot, fresh: true) == item.md5 else {
                throw CloudArchiveError.invalidArchive
            }
            guard try Stamp.directory(parent) == directory else { throw CloudArchiveError.localChanged }
            try Task.checkCancellation()
            if renamex_np(candidate.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { throw CloudArchiveError.localChanged }
                throw CloudArchiveError.installFailed
            }
            received += item.size
            progress?(.init(bytesTransferred: received, totalBytes: bytes))
        }
        try Task.checkCancellation()
    }

    public func free(folderName: String, files: [URL], confirmed: Bool) async throws -> Int64 {
        guard confirmed else { throw CloudArchiveError.confirmationRequired }
        let selection = try Selection(folderName, files)
        guard let lease = backend.leases.begin(selection.title) else { throw CloudArchiveError.busy }
        defer { backend.leases.end(selection.title, token: lease) }
        let remote = try await remoteFiles(selection)
        var verified: [(URL, Stamp, String)] = []
        for source in selection.files {
            guard let local = try stamp(at: source) else { continue }
            guard let item = remote[source.lastPathComponent] else { throw CloudArchiveError.noRemoteCopy }
            guard let md5 = item.md5 else { throw CloudArchiveError.invalidArchive }
            guard local.bytes == item.size, try await hash(source, stamp: local, fresh: true) == md5 else {
                throw CloudArchiveError.sourcesConflict
            }
            verified.append((source, local, md5))
        }
        let bytes = try total(verified.map { $0.1.bytes })
        for (source, snapshot, md5) in verified {
            let item = try await remoteFiles(selection)[source.lastPathComponent]
            guard item?.md5 == md5, item?.size == snapshot.bytes else { throw CloudArchiveError.sourcesConflict }
            guard try stamp(at: source) == snapshot else { throw CloudArchiveError.localChanged }
            try Task.checkCancellation()
            try trash(source)
        }
        try Task.checkCancellation()
        return bytes
    }

    public func downloadSize(folderName: String, files: [URL]) async throws -> Int64 {
        try await total(downloads(Selection(folderName, files)).map { $0.1.size })
    }

    private func downloads(_ selection: Selection) async throws -> [(URL, StorageObject)] {
        let remote = try await remoteFiles(selection)
        return try selection.files.compactMap { source in
            try Task.checkCancellation()
            guard try stamp(at: source) == nil else { return nil }
            guard let item = remote[source.lastPathComponent] else { throw CloudArchiveError.noRemoteCopy }
            guard item.md5 != nil else { throw CloudArchiveError.invalidArchive }
            return (source, item)
        }
    }

    private func remoteFiles(_ selection: Selection) async throws -> [String: StorageObject] {
        try Task.checkCancellation()
        let selected = Set(selection.files.map(\.lastPathComponent))
        let entries = try await backend.list(in: selection.directory, withHashes: true)
        try Task.checkCancellation()
        var items: [String: StorageObject] = [:]
        for item in entries {
            let name = String(item.key.value.dropFirst(selection.directory.value.count + 1))
            guard selected.contains(name) else { continue }
            // Drive permits duplicate names. None of their paths is safe to use.
            items[name] = items[name] == nil ? item : StorageObject(key: item.key, size: -1, hashes: [:])
        }
        return items
    }

    private func total(_ sizes: [Int64]) throws -> Int64 {
        try sizes.reduce(0) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard size >= 0, !overflow else { throw CloudArchiveError.invalidArchive }
            return sum
        }
    }

    private func transfer(_ progress: Progress?, offset: Int64, bytes: Int64, fileBytes: Int64) -> Progress? {
        guard let progress else { return nil }
        progress(.init(bytesTransferred: offset, totalBytes: bytes))
        return { update in
            progress(.init(bytesTransferred: offset + min(fileBytes, update.bytesTransferred), totalBytes: bytes,
                           bytesPerSecond: update.bytesPerSecond, isVerifying: update.isVerifying))
        }
    }

    private func stamp(at url: URL) throws -> Stamp? {
        do {
            try SaveFiles.safePath(url)
            return try Stamp(CloudArchiveInventory.node(at: url))
        } catch CloudArchiveError.localMissing { return nil }
        catch is SaveFailure { throw CloudArchiveError.unsafePath }
    }

    private func hash(_ url: URL, stamp: Stamp, fresh: Bool = false) async throws -> String {
        try Task.checkCancellation()
        if !fresh, let cached = lock.withLock({ fingerprints[url] }), cached.stamp == stamp { return cached.md5 }
        let worker = Task.detached(priority: .utility) {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw CloudArchiveError.localChanged }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat(), md5 = Insecure.MD5()
            guard fstat(fd, &info) == 0, try Stamp(info) == stamp else { throw CloudArchiveError.localChanged }
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                md5.update(data: bytes)
            }
            guard fstat(fd, &info) == 0, try Stamp(info) == stamp else { throw CloudArchiveError.localChanged }
            return md5.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let digest = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard try self.stamp(at: url) == stamp else { throw CloudArchiveError.localChanged }
        if !fresh {
            lock.withLock {
                if fingerprints.count >= 256 { fingerprints.removeAll() }
                fingerprints[url] = (stamp, digest)
            }
        }
        return digest
    }

    private struct Stamp: Equatable, Sendable {
        let bytes: Int64
        let device: dev_t
        let inode: ino_t
        let mtimeSeconds: Int
        let mtimeNanos: Int
        let ctimeSeconds: Int
        let ctimeNanos: Int

        init(_ node: stat) throws {
            guard node.st_mode & S_IFMT == S_IFREG else { throw CloudArchiveError.unsafePath }
            (bytes, device, inode) = (node.st_size, node.st_dev, node.st_ino)
            (mtimeSeconds, mtimeNanos) = (node.st_mtimespec.tv_sec, node.st_mtimespec.tv_nsec)
            (ctimeSeconds, ctimeNanos) = (node.st_ctimespec.tv_sec, node.st_ctimespec.tv_nsec)
        }

        static func directory(_ url: URL) throws -> (dev_t, ino_t) {
            do { try SaveFiles.safePath(url) }
            catch { throw CloudArchiveError.unsafePath }
            let node = try CloudArchiveInventory.node(at: url)
            guard node.st_mode & S_IFMT == S_IFDIR else { throw CloudArchiveError.unsafePath }
            return (node.st_dev, node.st_ino)
        }
    }

    static let directory = "Switch/Jeux"
    static let fileExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]

    static func title(in folder: String) -> String {
        let suffix = folder.suffix(18)
        let id = String(suffix.dropFirst().dropLast())
        return suffix.first == "[" && suffix.last == "]" && SaveLocation.validID(id) ? id.uppercased() : folder
    }

    private struct Selection {
        let title: String
        let directory: StorageObjectKey
        let files: [URL]

        init(_ folder: String, _ urls: [URL]) throws {
            guard Self.safeName(folder) else { throw CloudArchiveError.unsafePath }
            directory = StorageObjectKey(CloudGameSources.directory + "/" + folder)
            title = CloudGameSources.title(in: folder)
            var names: [String: URL] = [:]
            var files: [URL] = []
            for url in urls {
                guard url.isFileURL, !url.hasDirectoryPath,
                      !url.pathComponents.contains(".."), Self.safeName(url.lastPathComponent),
                      CloudGameSources.fileExtensions.contains(url.pathExtension.lowercased()) else {
                    throw CloudArchiveError.unsafePath
                }
                let file = url.standardizedFileURL
                let name = file.lastPathComponent
                if let existing = names[name] {
                    guard existing == file else { throw CloudArchiveError.unsafePath }
                } else {
                    names[name] = file
                    files.append(file)
                }
            }
            self.files = files
        }

        private static func safeName(_ name: String) -> Bool {
            !name.isEmpty && !name.contains("/") && CloudLibraryPreference.safePath(name)
        }
    }
}

extension StorageObject {
    var md5: String? {
        guard size >= 0, let hash = hashes["md5"], hash.utf8.count == 32,
              hash.utf8.allSatisfy({ "0123456789abcdefABCDEF".utf8.contains($0) }) else { return nil }
        return hash.lowercased()
    }
}
