import Darwin
import Foundation

public struct RcloneStorageBackend: StorageBackend {
    private static let staging = ".arcane-upload"
    private static let smallDownloadLimit: Int64 = 64 * 1024
    private static let flags = ["--drive-skip-shortcuts", "--local-links=false", "--copy-links=false"]
    private let remote: String
    private let root: String
    private let executable: URL?
    private let config: URL?
    let control: RcloneRemoteControl
    package let leases: CloudTitleLeases

    /// `remote` is a configured rclone name (e.g. `gdrive`) or `:local:` with an absolute `root`.
    /// Credentials and unlocking stay in rclone's configuration, not the arguments or Arcane preferences.
    public init(remote: String, root: String, executable: URL? = nil, config: URL? = nil) {
        self.init(remote: remote, root: root, executable: executable, config: config,
                  control: RcloneRemoteControl(), leases: CloudTitleLeases())
    }

    private init(remote: String, root: String, executable: URL?, config: URL?,
                 control: RcloneRemoteControl, leases: CloudTitleLeases) {
        self.remote = remote
        self.root = root
        self.executable = executable
        self.config = config
        self.control = control
        self.leases = leases
    }

    package func atRoot(_ root: String) -> Self {
        Self(remote: remote, root: root, executable: executable, config: config, control: control, leases: leases)
    }

    /// Ends the RC session when the cloud configuration is replaced or the app quits.
    public func stopRemoteControl() { control.stop() }

    public static func findExecutable() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (["/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init))
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("rclone") }
            .first(where: isExecutable)
    }

    public static func isExecutable(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.isExecutableFile(atPath: url.path)
            && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    public func list() async throws -> [StorageObject] {
        let base = try basePath()
        let exclude = "/\(Self.staging)/**"
        let items: [Item]
        if let output = try await rc("operations/list", [
            "fs": base, "remote": "", "opt": ["recurse": true, "filesOnly": true, "showHash": true],
            "_filter": ["ExcludeRule": [exclude]],
        ]) {
            items = try decode(ListResult.self, from: output).list
        } else {
            let output = try await run(["lsjson", base, "--recursive", "--files-only", "--hash", "--exclude", exclude])
            items = try decode([Item].self, from: output)
        }
        return items.map {
            StorageObject(key: StorageObjectKey($0.path), size: $0.size, hashes: $0.hashes ?? [:])
        }
    }

    public func list(in prefix: StorageObjectKey) async throws -> [StorageObject] {
        try await list(in: prefix, withHashes: false)
    }

    public func rootDirectories() async throws -> [String] {
        let base = try basePath()
        let items: [Item]
        if let output = try await rc("operations/list", [
            "fs": base, "remote": "", "opt": ["dirsOnly": true, "noModTime": true, "noMimeType": true],
        ]) {
            items = try decode(ListResult.self, from: output).list
        } else {
            let output = try await run(["lsjson", base, "--dirs-only", "--no-modtime", "--no-mimetype",
                                        "--retries", "1", "--low-level-retries", "1", "--contimeout", "5s", "--timeout", "10s"])
            items = try decode([Item].self, from: output)
        }
        return items.map(\.name)
    }

    package func list(in prefix: StorageObjectKey, withHashes: Bool) async throws -> [StorageObject] {
        let directory = try path(for: prefix)
        let items: [Item]
        do {
            if let output = try await rc("operations/list", [
                "fs": basePath(), "remote": prefix.value, "opt": ["filesOnly": !withHashes, "showHash": withHashes],
            ]) {
                items = try decode(ListResult.self, from: output).list
            } else {
                let output = try await run(["lsjson", directory, withHashes ? "--hash" : "--files-only"])
                items = try decode([Item].self, from: output)
            }
        } catch StorageBackendError.notFound { return [] }
        return items.map {
            StorageObject(key: StorageObjectKey(prefix.value + "/" + $0.name), size: $0.size, hashes: $0.hashes ?? [:])
        }
    }

    public func put(_ source: URL, as object: StorageObject,
                    progress: (@Sendable (StorageProgress) -> Void)?) async throws {
        try validateFingerprint(object)
        try await put(source, as: object, md5Only: false, progress: progress)
    }

    package struct ArchiveUpload: Sendable {
        fileprivate let path: String
    }

    package func archiveUpload() throws -> ArchiveUpload {
        try .init(path: objectPath("\(Self.staging)/\(UUID().uuidString)"))
    }

    package func archiveUploadProcess(to upload: ArchiveUpload) throws -> Process {
        let sink = Process()
        sink.executableURL = try binary()
        let environment = RcloneConfiguration.environment()
        sink.environment = environment
        // An unsupported remote must fail rather than let rcat spool an unknown-size stream to disk.
        sink.arguments = ["rcat", upload.path, "--temp-dir", "/dev/null", "--buffer-size", "0",
                          "--streaming-upload-cutoff", "1M", "--drive-chunk-size", "8M", "--retries", "1"]
            + Self.flags + RcloneConfiguration.flags(config: config, environment: environment)
        return sink
    }

    package func verifyArchive(_ object: StorageObject, staged upload: ArchiveUpload) async throws {
        try validateFingerprint(object)
        try await verify(object, at: upload.path, md5Only: true)
    }

    package func publishArchive(_ object: StorageObject, staged upload: ArchiveUpload) async throws {
        let final = try path(for: object.key)
        if try await item(at: final) == nil {
            if remote == ":local:" {
                let destination = URL(fileURLWithPath: String(final.dropFirst(remote.count)))
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Task.checkCancellation()
                if renamex_np(String(upload.path.dropFirst(remote.count)), destination.path, UInt32(RENAME_EXCL)) != 0,
                   errno != EEXIST { throw StorageBackendError.publicationFailed }
            } else {
                _ = try await run(["moveto", upload.path, final, "--ignore-existing", "--immutable", "--checksum",
                                   "--disable", "Copy", "--max-transfer", "0", "--retries", "1"])
            }
        }
        try await verify(object, at: final, md5Only: true)
        if remote != ":local:" {
            let directory = StorageObjectKey(object.key.value.split(separator: "/").dropLast().joined(separator: "/"))
            guard try await list(in: directory).filter({ $0.key == object.key }).count == 1 else {
                throw StorageBackendError.invalidResponse
            }
        }
        if try await item(at: upload.path) != nil {
            _ = try await run(["deletefile", upload.path])
        }
    }

    package func discardArchives(_ uploads: [ArchiveUpload]) async {
        await Task.detached {
            for upload in uploads {
                _ = try? await run(["deletefile", upload.path, "--retries", "1", "--low-level-retries", "1",
                                    "--contimeout", "5s", "--timeout", "5s"])
            }
        }.value
    }

    package func putSource(_ source: URL, as object: StorageObject,
                   progress: (@Sendable (StorageProgress) -> Void)?) async throws {
        guard object.size >= 0, isHex(object.hashes["md5"], length: 32) else {
            throw StorageBackendError.invalidFingerprint
        }
        try await put(source, as: object, md5Only: true, progress: progress)
    }

    private func put(_ source: URL, as object: StorageObject, md5Only: Bool,
                     progress: (@Sendable (StorageProgress) -> Void)?) async throws {
        let final = try path(for: object.key)
        guard source.isFileURL, isRegularFile(source) else {
            throw StorageBackendError.invalidLocalFile
        }
        guard try await item(at: final) == nil else { throw StorageBackendError.alreadyExists }

        let temporary = try objectPath("\(Self.staging)/\(UUID().uuidString)")
        var createdFinal = false
        do {
            _ = try await run(["copyto", source.path, temporary], progress: progress)
            progress?(StorageProgress(bytesTransferred: object.size, totalBytes: object.size, isVerifying: true))
            try await verify(object, at: temporary, md5Only: md5Only)
            if md5Only && remote == ":local:" {
                // rclone's local Move uses a replacing rename, so make the local publication exclusive.
                let destination = URL(fileURLWithPath: String(final.dropFirst(remote.count)))
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Task.checkCancellation()
                guard renamex_np(String(temporary.dropFirst(remote.count)), destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw StorageBackendError.alreadyExists }
                    throw StorageBackendError.publicationFailed
                }
                createdFinal = true
            } else {
                // Do not let moveto fall back to streaming data into the final key.
                _ = try await run(["moveto", temporary, final, "--ignore-existing", "--immutable", "--checksum",
                                   "--disable", "Copy", "--max-transfer", "0", "--retries", "1"])
                // A skipped move leaves our unique staging object behind, even for identical content.
                createdFinal = try await Task.detached { try await item(at: temporary) == nil }.value
            }
            guard createdFinal else { throw StorageBackendError.alreadyExists }
            // The sources service verifies the published entry in a fresh directory listing for duplicates.
            if !md5Only { try await verify(object, at: final) }
        } catch {
            let cleanup = createdFinal && !md5Only ? [final, temporary] : [temporary]
            await Task.detached {
                for target in cleanup {
                    _ = try? await run(["deletefile", target, "--retries", "1", "--low-level-retries", "1",
                                        "--contimeout", "5s", "--timeout", "5s"])
                }
            }.value
            throw error
        }
    }

    public func get(_ key: StorageObjectKey, to destination: URL,
                    progress: (@Sendable (StorageProgress) -> Void)?) async throws {
        let source = try path(for: key)
        guard destination.isFileURL else { throw StorageBackendError.invalidLocalFile }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw StorageBackendError.alreadyExists }
        guard let item = try await item(at: source) else { throw StorageBackendError.notFound }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".arcane-download-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch { throw StorageBackendError.invalidLocalFile }
        defer { try? fm.removeItem(at: staging) }
        let temporary: URL
        if progress == nil, (1...Self.smallDownloadLimit).contains(item.size),
           try await rc("operations/copyfile", [
               "srcFs": basePath(), "srcRemote": key.value, "dstFs": ":local:" + staging.path, "dstRemote": "rc",
           ]) != nil {
            temporary = staging.appendingPathComponent("rc")
        } else {
            // A lost RC response can leave a partial download; the CLI uses a separate staging file.
            temporary = staging.appendingPathComponent("file")
            _ = try await run(["copyto", source, temporary.path], progress: progress)
        }
        try Task.checkCancellation()
        guard isRegularFile(temporary) else { throw StorageBackendError.invalidResponse }
        do { try fm.moveItem(at: temporary, to: destination) }
        catch let error as CocoaError where error.code == .fileWriteFileExists { throw StorageBackendError.alreadyExists }
        catch { throw StorageBackendError.invalidLocalFile }
    }

    public func delete(_ key: StorageObjectKey) async throws {
        _ = try await run(["deletefile", path(for: key)])
    }

    public func verify(_ object: StorageObject) async throws {
        try validateFingerprint(object)
        try await verify(object, at: path(for: object.key))
    }

    private func verify(_ object: StorageObject, at target: String, md5Only: Bool = false) async throws {
        guard let item = try await item(at: target, withHashes: true) else { throw StorageBackendError.notFound }
        guard item.size == object.size else { throw StorageBackendError.hashMismatch }
        if md5Only {
            guard isHex(item.hashes?["md5"], length: 32) else { throw StorageBackendError.hashMismatch }
            guard item.hashes?["md5"]?.lowercased() == object.hashes["md5"]?.lowercased() else {
                throw StorageBackendError.hashMismatch
            }
            return
        }
        let expected = object.hashes["sha256"]?.lowercased()
        if let actual = item.hashes?["sha256"], !actual.isEmpty {
            guard actual.lowercased() == expected else { throw StorageBackendError.hashMismatch }
            return
        }
        let output = try await run(["hashsum", "SHA-256", target, "--download"])
        let lines = output.split(separator: "\n")
        guard lines.count == 1, let digest = lines[0].split(separator: " ", maxSplits: 1).first,
              isHex(String(digest), length: 64) else { throw StorageBackendError.invalidResponse }
        guard digest.lowercased() == expected else {
            throw StorageBackendError.hashMismatch
        }
    }

    private func item(at path: String, withHashes: Bool = false) async throws -> Item? {
        let base = try basePath()
        let relative = String(path.dropFirst(base.count + (base.hasSuffix("/") ? 0 : 1)))
        if let output = try await rc("operations/stat", [
            "fs": base, "remote": relative, "opt": ["filesOnly": true, "showHash": withHashes],
        ]) { return try decode(StatResult.self, from: output).item }
        let output = try await run(["lsjson", path, "--stat", "--files-only"] + (withHashes ? ["--hash"] : []))
        return try decode(Item?.self, from: output)
    }

    private func rc(_ operation: String, _ parameters: [String: Any]) async throws -> String? {
        guard let binary = executable ?? Self.findExecutable(), Self.isExecutable(binary) else { return nil }
        let environment = RcloneConfiguration.environment()
        return try await control.call(operation, parameters, executable: binary, environment: environment,
            flags: Self.flags + RcloneConfiguration.flags(config: config, environment: environment))
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func validateFingerprint(_ object: StorageObject) throws {
        guard object.size >= 0, isHex(object.hashes["sha256"], length: 64),
              object.hashes["md5"].map({ isHex($0, length: 32) }) ?? true else {
            throw StorageBackendError.invalidFingerprint
        }
    }

    private func isHex(_ value: String?, length: Int) -> Bool {
        guard let value else { return false }
        return value.utf8.count == length && value.utf8.allSatisfy { "0123456789abcdefABCDEF".utf8.contains($0) }
    }

    private func path(for key: StorageObjectKey) throws -> String {
        let components = key.value.components(separatedBy: "/")
        guard !components.contains(""), CloudLibraryPreference.safePath(key.value),
              components.first?.lowercased() != Self.staging else {
            throw StorageBackendError.invalidKey
        }
        return try objectPath(key.value)
    }

    private func objectPath(_ key: String) throws -> String {
        let base = try basePath()
        if remote == ":local:" {
            var candidate = URL(fileURLWithPath: root, isDirectory: true)
            for component in key.split(separator: "/") {
                candidate.appendPathComponent(String(component))
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                    throw StorageBackendError.invalidKey
                }
            }
        }
        return base + (base.hasSuffix("/") ? "" : "/") + key
    }

    private func basePath() throws -> String {
        let name = remote.hasSuffix(":") ? String(remote.dropLast()) : remote
        guard CloudLibraryPreference.validRoot(root), config?.isFileURL != false,
              remote == ":local:" ? root.hasPrefix("/") && root != "/" :
                  CloudLibraryPreference.validRemote(name)
        else { throw StorageBackendError.invalidConfiguration }
        return (remote == ":local:" ? remote : name + ":") + root
    }

    private func binary() throws -> URL {
        guard let binary = executable ?? Self.findExecutable(), Self.isExecutable(binary) else {
            throw StorageBackendError.backendUnavailable
        }
        return binary
    }

    private func run(_ arguments: [String], progress: (@Sendable (StorageProgress) -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        let binary = try binary()
        let flags = ["--use-json-log", "--stats", "1s", "--stats-log-level", "NOTICE"] + Self.flags
        let environment = RcloneConfiguration.environment()
        let command = arguments + flags + RcloneConfiguration.flags(config: config, environment: environment)
        let result: CommandResult
        do {
            result = try await SystemCommandRunner().runCancellable(binary, command, environment: environment) { line in
                if let progress, let update = Self.transferProgress(from: line) { progress(update) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StorageBackendError.backendUnavailable
        }
        switch result.status {
        case 0: return result.stdout
        case 3, 4: throw StorageBackendError.notFound
        default:
            let messages: [String] = result.stderr.split(whereSeparator: \.isNewline).suffix(8).compactMap {
                guard let log = try? JSONDecoder().decode(Log.self, from: Data($0.utf8)) else { return String($0) }
                guard log.stats == nil else { return nil }
                return log.message
            }
            if messages.contains(where: {
                $0.contains("Failed to create file system") || $0.contains("Failed to load config")
            }) { throw StorageBackendError.backendUnavailable }
            // OAuth responses in stderr can contain credentials even outside recognizable keys.
            throw StorageBackendError.processFailed(status: result.status)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(output.utf8)) }
        catch { throw StorageBackendError.invalidResponse }
    }

    static func transferProgress(from line: String) -> StorageProgress? {
        guard let stats = (try? JSONDecoder().decode(Log.self, from: Data(line.utf8)))?.stats,
              stats.bytes >= 0, stats.totalBytes > 0 else { return nil }
        let speed = [stats.speed, stats.transferring?.first?.speed].compactMap { $0 }.first { $0.isFinite && $0 > 0 }
        let eta = stats.eta ?? speed.map { Double(max(0, stats.totalBytes - stats.bytes)) / $0 }
        return StorageProgress(bytesTransferred: min(stats.bytes, stats.totalBytes), totalBytes: stats.totalBytes,
                               bytesPerSecond: speed, etaSeconds: eta)
    }

    private struct Item: Decodable {
        let path: String
        let name: String
        let size: Int64
        let hashes: [String: String]?

        enum CodingKeys: String, CodingKey { case path = "Path", name = "Name", size = "Size", hashes = "Hashes" }
    }

    private struct ListResult: Decodable { let list: [Item] }
    private struct StatResult: Decodable {
        let item: Item?
        private enum CodingKeys: CodingKey { case item }
        init(from decoder: Decoder) throws {
            item = try decoder.container(keyedBy: CodingKeys.self).decode(Item?.self, forKey: .item)
        }
    }

    private struct Log: Decodable {
        struct Stats: Decodable {
            struct Active: Decodable { let speed: Double? }
            let bytes: Int64
            let totalBytes: Int64
            let speed: Double?
            let eta: Double?
            let transferring: [Active]?
        }

        let message: String
        let stats: Stats?

        enum CodingKeys: String, CodingKey { case message = "msg", stats }
    }
}
