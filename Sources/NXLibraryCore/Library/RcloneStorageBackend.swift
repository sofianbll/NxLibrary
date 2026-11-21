import Foundation

public struct RcloneStorageBackend: StorageBackend {
    private static let staging = ".arcane-upload"
    private let remote: String
    private let root: String
    private let executable: URL?
    private let config: URL?

    /// `remote` is a configured rclone name (e.g. `gdrive`) or `:local:` with an absolute `root`.
    /// Credentials and unlocking stay in rclone's configuration, not the arguments or Arcane preferences.
    public init(remote: String, root: String, executable: URL? = nil, config: URL? = nil) {
        self.remote = remote
        self.root = root
        self.executable = executable
        self.config = config
    }

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
        let output = try await run(["lsjson", basePath(), "--recursive", "--files-only", "--hash",
                                    "--exclude", "/\(Self.staging)/**"])
        return try decode([Item].self, from: output).map {
            StorageObject(key: StorageObjectKey($0.path), size: $0.size, hashes: $0.hashes ?? [:])
        }
    }

    public func list(in prefix: StorageObjectKey) async throws -> [StorageObject] {
        let directory = try path(for: prefix)
        let output: String
        do { output = try await run(["lsjson", directory, "--files-only"]) }
        catch StorageBackendError.notFound { return [] }
        return try decode([Item].self, from: output).map {
            StorageObject(key: StorageObjectKey(prefix.value + "/" + $0.path), size: $0.size, hashes: [:])
        }
    }

    public func put(_ source: URL, as object: StorageObject,
                    progress: (@Sendable (StorageProgress) -> Void)?) async throws {
        let final = try path(for: object.key)
        try validateFingerprint(object)
        guard source.isFileURL, isRegularFile(source) else {
            throw StorageBackendError.invalidLocalFile
        }
        guard try await item(at: final) == nil else { throw StorageBackendError.alreadyExists }

        let temporary = try objectPath("\(Self.staging)/\(UUID().uuidString)")
        var createdFinal = false
        do {
            _ = try await run(["copyto", source.path, temporary], progress: progress)
            progress?(StorageProgress(bytesTransferred: object.size, totalBytes: object.size, isVerifying: true))
            try await verify(object, at: temporary)
            // Do not let moveto fall back to streaming data into the final key.
            _ = try await run(["moveto", temporary, final, "--ignore-existing", "--immutable", "--checksum",
                               "--disable", "Copy", "--max-transfer", "0", "--retries", "1"])
            // A skipped move leaves our unique staging object behind, even for identical content.
            createdFinal = try await Task.detached { try await item(at: temporary) == nil }.value
            guard createdFinal else { throw StorageBackendError.alreadyExists }
            try await verify(object, at: final)
        } catch {
            let cleanup = createdFinal ? [final, temporary] : [temporary]
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
        guard try await item(at: source) != nil else { throw StorageBackendError.notFound }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".arcane-download-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch { throw StorageBackendError.invalidLocalFile }
        defer { try? fm.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("file")
        _ = try await run(["copyto", source, temporary.path], progress: progress)
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

    private func verify(_ object: StorageObject, at target: String) async throws {
        guard let item = try await item(at: target, withHashes: true) else { throw StorageBackendError.notFound }
        guard item.size == object.size else { throw StorageBackendError.hashMismatch }
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
        let output = try await run(["lsjson", path, "--stat", "--files-only"] + (withHashes ? ["--hash"] : []))
        return try decode(Item?.self, from: output)
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

    private func run(_ arguments: [String], progress: (@Sendable (StorageProgress) -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        guard let binary = executable ?? Self.findExecutable(), Self.isExecutable(binary) else {
            throw StorageBackendError.backendUnavailable
        }

        let flags = ["--use-json-log", "--stats", "1s", "--stats-log-level", "NOTICE",
                     "--drive-skip-shortcuts", "--local-links=false", "--copy-links=false"]
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
        let size: Int64
        let hashes: [String: String]?

        enum CodingKeys: String, CodingKey { case path = "Path", size = "Size", hashes = "Hashes" }
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
