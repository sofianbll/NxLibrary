import Foundation
import Darwin

public struct CloudDriveFolders: Sendable {
    public struct Listing: Sendable {
        public let ticket: UUID
        public let names: [String]
    }

    private let remote: String
    private let executable: URL
    private let localRoot: URL?
    private let config: URL?
    private let run: RcloneConfiguration.Run

    public init(remote: String, executable: URL, config: URL? = nil) {
        self.init(remote: remote, executable: executable, config: config, run: Self.runCommand)
    }

    init(remote: String, executable: URL, localRoot: URL? = nil, config: URL? = nil,
         run: @escaping RcloneConfiguration.Run = Self.runCommand) {
        self.remote = remote
        self.executable = executable
        self.localRoot = localRoot
        self.config = config
        self.run = run
    }

    public static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.contains("/") && name.lowercased() != ".arcane-upload"
            && CloudLibraryPreference.safePath(name)
    }

    public static func joining(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    public func list(_ folder: String, ticket: UUID) async throws -> Listing {
        let output = try await checked(["lsjson", try target(folder), "--dirs-only", "--max-depth", "1",
                                        "--no-modtime", "--no-mimetype"])
        guard let items = try? JSONDecoder().decode([Item].self, from: Data(output.utf8)) else {
            throw StorageBackendError.invalidResponse
        }
        let names = Set(items.filter(\.IsDir).map(\.Name).filter(Self.validName))
        return Listing(ticket: ticket, names: names.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        })
    }

    public func verifyAccess(to folder: String) async throws {
        let output = try await checked(["lsjson", try target(folder), "--stat"])
        guard (try? JSONDecoder().decode(Item.self, from: Data(output.utf8)))?.IsDir == true else {
            throw RcloneConfiguration.Failure.test
        }
        _ = try await list(folder, ticket: UUID())
    }

    /// Only an explicit confirmation calls this. A lost reply is followed by a read, never another write.
    public func create(_ name: String, in folder: String) async throws {
        guard Self.validName(name) else { throw StorageBackendError.invalidKey }
        let destination = try target(Self.joining(folder, name))
        if try await list(folder, ticket: UUID()).names.contains(name) { return }
        do {
            _ = try await checked(["mkdir", destination])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if try await list(folder, ticket: UUID()).names.contains(name) { return }
            throw error
        }
    }

    public func libraryCount(in folder: String, folders: [String]) async throws -> Int {
        let path = try target(folder)
        let prefix = remote == ":local:" ? remote : remote + ":"
        let backend = RcloneStorageBackend(remote: remote, root: String(path.dropFirst(prefix.count)),
                                          executable: executable, config: config)
        defer { backend.stopRemoteControl() }
        let archive = CloudGameArchive(backend: backend)
        let ids = Set(folders.filter(SaveLocation.validID).map { $0.uppercased() })
        var count = 0
        for id in ids.sorted() {
            try Task.checkCancellation()
            if try await archive.latest(titleID: id) != nil { count += 1 }
        }
        return count
    }

    private struct Item: Decodable {
        let Name: String
        let IsDir: Bool
    }

    private func target(_ folder: String) throws -> String {
        guard folder.isEmpty || folder.components(separatedBy: "/").allSatisfy(Self.validName) else {
            throw StorageBackendError.invalidKey
        }
        if remote == ":local:", let localRoot, localRoot.isFileURL {
            var location = localRoot
            for component in folder.split(separator: "/") {
                location.appendPathComponent(String(component))
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: location.path)) == nil else {
                    throw StorageBackendError.invalidKey
                }
            }
            return remote + location.path
        }
        guard CloudLibraryPreference.validRemote(remote) else { throw StorageBackendError.invalidConfiguration }
        return "\(remote):\(folder)"
    }

    private func checked(_ arguments: [String]) async throws -> String {
        let environment = RcloneConfiguration.environment()
        let flags = ["--drive-skip-shortcuts", "--local-links=false", "--copy-links=false",
                     "--retries", "1", "--low-level-retries", "1", "--contimeout", "5s", "--timeout", "10s"]
        do {
            try Task.checkCancellation()
            let result = try await run(executable, arguments + flags
                + RcloneConfiguration.flags(config: config, environment: environment), environment)
            try Task.checkCancellation()
            if result.status == 3 && arguments.first == "lsjson" { throw StorageBackendError.notFound }
            guard result.status == 0 else { throw RcloneConfiguration.Failure.test }
            return result.stdout
        } catch is CancellationError {
            throw CancellationError()
        } catch StorageBackendError.notFound {
            throw StorageBackendError.notFound
        } catch {
            throw RcloneConfiguration.Failure.test
        }
    }

    private static let runCommand: RcloneConfiguration.Run = { executable, arguments, environment in
        try await SystemCommandRunner().runCancellable(executable, arguments, environment: environment)
    }
}

/// rclone saves update options before OAuth completes. Stage the encrypted file so cancellation or a failed
/// access check cannot break the account Arcane is currently using.
public final class CloudDriveCredentialChange: Sendable {
    public let config: URL
    private let original: URL
    private let baseline: Data

    private init(config: URL, original: URL, baseline: Data) {
        self.config = config
        self.original = original
        self.baseline = baseline
    }

    deinit { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    public static func prepare(remote: String, executable: URL, clientID: String,
                               secret: String) async throws -> CloudDriveCredentialChange {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CloudSetupAssistantDraft.validGoogleClientID(id), RcloneConfiguration.validCredential(password),
              CloudLibraryPreference.validRemote(remote) else { throw RcloneConfiguration.Failure.connect }
        let environment = RcloneConfiguration.environment()
        @Sendable func run(_ args: [String], config: URL? = nil) async throws -> String {
            do {
                let result = try await SystemCommandRunner().runCancellable(executable,
                    args + RcloneConfiguration.flags(config: config, environment: environment), environment: environment)
                guard result.status == 0 else { throw RcloneConfiguration.Failure.connect }
                return result.stdout
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RcloneConfiguration.Failure.connect
            }
        }
        let location = try await run(["config", "file"])
        guard let path = location.split(separator: "\n").last, path.hasPrefix("/") else {
            throw RcloneConfiguration.Failure.configuration
        }
        let original = URL(fileURLWithPath: String(path))
        let staged = try await Task.detached(priority: .utility) { try stage(original) }.value
        _ = try await run(["config", "encryption", "check"], config: staged.config)
        try Task.checkCancellation()
        _ = try await run(["config", "update", remote, "client_id=\(id)", "client_secret=\(password)",
                           "config_refresh_token=true", "config_is_local=true", "--no-output"], config: staged.config)
        return staged
    }

    static func stage(_ original: URL) throws -> CloudDriveCredentialChange {
        let properties = try original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink == false else {
            throw RcloneConfiguration.Failure.configuration
        }
        let baseline = try Data(contentsOf: original)
        guard baseline.starts(with: "# Encrypted rclone configuration File".utf8)
            || baseline.starts(with: "RCLONE_ENCRYPT_V0:".utf8) else { throw RcloneConfiguration.Failure.encryption }
        let directory = original.deletingLastPathComponent().appendingPathComponent(".arcane-rclone-\(UUID())")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let staged = CloudDriveCredentialChange(config: directory.appendingPathComponent("rclone.conf"),
                                                original: original, baseline: baseline)
        guard fm.createFile(atPath: staged.config.path, contents: baseline, attributes: [.posixPermissions: 0o600])
        else { throw RcloneConfiguration.Failure.configuration }
        return staged
    }

    /// Reject a file that rclone or another application changed during the wizard.
    public func apply() throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let properties = try original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink == false,
              try Data(contentsOf: original) == baseline,
              rename(config.path, original.path) == 0 else {
            throw RcloneConfiguration.Failure.configuration
        }
    }
}
