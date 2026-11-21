import Foundation
import Darwin
import NXLibraryCore

public struct CloudDriveFolders: Sendable {
    public struct Listing: Sendable {
        public let ticket: UUID
        public let names: [String]
    }

    public struct Library: Sendable, Equatable {
        public let path: String
        public let games: Int
    }

    public struct Sources: Sendable, Equatable {
        public let path: String
        public let games: Int?
    }

    public struct MovePlan: Sendable {
        public let source: String
        public let games: Int
        public let bytes: Int64
        fileprivate let remote: String
        fileprivate let entries: [MoveEntry]
    }

    fileprivate struct MoveEntry: Sendable {
        let file: StorageObject
        let dependencies: [StorageObject]
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
        let backend = try backend(in: folder)
        defer { backend.stopRemoteControl() }
        return try await Self.libraryCount(backend, folders: folders)
    }

    public func discoverLibrary() async throws -> Library? {
        try await Self.discoverLibrary(directories: {
            try await list($0, ticket: UUID()).names
        }, count: { folder, names in
            try await libraryCount(in: folder, folders: names)
        })
    }

    static func discoverLibrary(directories: (String) async throws -> [String],
                                count: (String, [String]) async throws -> Int) async throws -> Library? {
        let root = CloudLibraryPreference.defaultRoot
        guard let names = try await listingIfPresent(root, list: directories) else { return nil }
        let games = try await count(root, names)
        try Task.checkCancellation()
        if games > 0 { return Library(path: root, games: games) }
        let children = names.filter { validName($0) && !SaveLocation.validID($0) }
        guard children.count <= 64 else { throw StorageBackendError.invalidResponse }
        for child in children {
            let path = joining(root, child)
            guard let names = try await listingIfPresent(path, list: directories) else {
                // The folder was listed, but disappeared before we could inspect it.
                throw StorageBackendError.invalidResponse
            }
            let games = try await count(path, names)
            try Task.checkCancellation()
            if games > 0 { return Library(path: path, games: games) }
        }
        return nil
    }

    public func discoverSources(library: String) async throws -> Sources? {
        try await Self.discoverSources(library: library) { folder in
            let output = try await checked(["lsjson", try target(folder), "--recursive", "--max-depth", "2",
                                            "--files-only", "--no-modtime", "--no-mimetype"])
            guard let items = try? JSONDecoder().decode([Item].self, from: Data(output.utf8)) else {
                throw StorageBackendError.invalidResponse
            }
            return items.filter { !$0.IsDir }.map(\.Path)
        }
    }

    static func discoverSources(library: String, files: (String) async throws -> [String]) async throws -> Sources? {
        let candidates = [joining(library, "GameFiles"), joining(library, "Switch/Jeux"), "Games/Switch/Jeux", "Switch/Jeux"]
        var visited = Set<String>()
        for path in candidates where visited.insert(path).inserted {
            guard let names = try await listingIfPresent(path, list: files) else { continue }
            guard names.count <= 10_000 else { throw StorageBackendError.invalidResponse }
            var groups = Set<String>()
            var loose = false
            for name in names {
                try Task.checkCancellation()
                let parts = name.components(separatedBy: "/")
                guard parts.count <= 2, parts.allSatisfy(validName),
                    CloudGameSources.fileExtensions.contains((name as NSString).pathExtension.lowercased())
                else { continue }
                if parts.count == 1 { loose = true }
                else { groups.insert(CloudGameSources.title(in: parts[0])) }
            }
            try Task.checkCancellation()
            // Loose packages may be updates or DLC for the same title; don't guess a count.
            if loose || !groups.isEmpty { return Sources(path: path, games: loose ? nil : groups.count) }
        }
        return nil
    }

    private static func listingIfPresent(_ folder: String,
                                         list: (String) async throws -> [String]) async throws -> [String]? {
        try Task.checkCancellation()
        let result: [String]?
        do { result = try await list(folder) }
        catch StorageBackendError.notFound { result = nil }
        try Task.checkCancellation()
        return result
    }

    static func libraryCount(_ backend: any StorageBackend, folders: [String]) async throws -> Int {
        try await CloudGameArchive(backend: backend).latestManifests(in: folders).count
    }

    public static func canMove(from source: String, to destination: String) -> Bool {
        let old = source.lowercased(), new = destination.lowercased()
        guard CloudLibraryPreference.validRoot(old), CloudLibraryPreference.validRoot(new), old != new else { return false }
        for (parent, child) in [(old, new), (new, old)] where child.hasPrefix(parent + "/") {
            guard let subtree = child.dropFirst(parent.count + 1).split(separator: "/").first,
                  !SaveLocation.validID(String(subtree)) else { return false }
        }
        return true
    }

    public func movePlan(from source: String) async throws -> MovePlan {
        try await verifyUniqueFolder(source)
        let items = try await contents(source, recursive: true)
        let paths = Dictionary(grouping: items, by: \.Path)
        let backend = try backend(in: source)
        defer { backend.stopRemoteControl() }
        let archive = CloudGameArchive(backend: backend)
        var archiveTitles = Set<String>()
        var objects: [MoveEntry] = [], manifests: [MoveEntry] = []
        for item in items.sorted(by: { $0.Path < $1.Path }) where !item.IsDir {
            let path = item.Path
            let parts = path.components(separatedBy: "/")
            guard parts.allSatisfy(Self.validName) else { continue }
            if parts.count == 3, SaveLocation.validID(parts[0]), parts[0] == parts[0].uppercased(),
               parts[1] == "manifests", path.hasSuffix(".json") {
                guard Self.uniquePath(path, in: paths) else { throw StorageBackendError.alreadyExists }
                let manifest: CloudGameManifest
                do { manifest = try await archive.readManifest(item.object, titleID: parts[0]) }
                catch CloudArchiveError.invalidManifest { continue }
                archiveTitles.insert(manifest.titleID)
                manifests.append(.init(file: item.object, dependencies: manifest.artifacts.map {
                    $0.object(titleID: manifest.titleID)
                }))
            }
        }
        for item in items where !item.IsDir {
            let parts = item.Path.components(separatedBy: "/")
            if parts.count == 3, archiveTitles.contains(parts[0]), CloudArtifactKind(rawValue: parts[1]) != nil,
               parts[2].range(of: #"^[0-9a-f]{64}\.aar\z"#, options: .regularExpression) != nil {
                objects.append(.init(file: item.object, dependencies: []))
            }
        }
        // Keep each key once even when Drive lists several objects with that name. The mover reports the conflict.
        var seen = Set<StorageObjectKey>()
        let entries = (objects.sorted { $0.file.key.value < $1.file.key.value } + manifests)
            .filter { seen.insert($0.file.key).inserted }
        var bytes: Int64 = 0
        for entry in entries {
            let (total, overflow) = bytes.addingReportingOverflow(entry.file.size)
            guard !overflow, entry.file.size >= 0 else { throw StorageBackendError.invalidResponse }
            bytes = total
        }
        return MovePlan(source: source, games: archiveTitles.count, bytes: bytes, remote: remote, entries: entries)
    }

    /// Run only after confirmation; a skipped key (or manifest with missing dependencies) prevents activation.
    public func move(_ plan: MovePlan, to destination: String,
                     progress: (Int, Int) async throws -> Void) async throws -> [String] {
        guard remote == plan.remote, Self.canMove(from: plan.source, to: destination) else {
            throw StorageBackendError.invalidKey
        }
        try await verifyUniqueFolder(plan.source)
        try await verifyUniqueFolder(destination)
        let sourcePaths = Dictionary(grouping: try await contents(plan.source, recursive: true), by: \.Path)
        var destinationPaths = Dictionary(grouping: try await contents(destination, recursive: true), by: \.Path)
        var conflicts: [String] = []
        var blockedTitles = Set<Substring>()
        try await progress(0, plan.entries.count)
        for (index, entry) in plan.entries.enumerated() {
            try Task.checkCancellation()
            let path = entry.file.key.value
            let title = path.prefix { $0 != "/" }
            if Self.uniquePath(path, in: sourcePaths), Self.uniquePath(path, in: destinationPaths),
               entry.dependencies.isEmpty || (!blockedTitles.contains(title) && entry.dependencies.allSatisfy({
                   Self.uniquePath($0.key.value, in: destinationPaths)
                       && Self.matches($0, destinationPaths[$0.key.value] ?? [])
               })),
               let final = try await moveFile(entry.file, from: plan.source, to: destination) {
                destinationPaths[path] = [final]
            } else {
                conflicts.append(path)
                blockedTitles.insert(title)
            }
            try await progress(index + 1, plan.entries.count)
        }
        return conflicts
    }

    private func moveFile(_ file: StorageObject, from source: String, to destination: String) async throws -> Item? {
        let key = file.key.value
        let old = try target(Self.joining(source, key))
        let new = try target(Self.joining(destination, key))
        let parts = key.components(separatedBy: "/")
        let parent = parts.dropLast().joined(separator: "/")
        let name = parts.last
        func siblings(_ root: String) async throws -> [Item] {
            try await contents(Self.joining(root, parent), recursive: false).filter { $0.Name == name }
        }
        let current = try await siblings(source)
        let existing = try await siblings(destination)
        if current.isEmpty { return Self.matches(file, existing) ? existing.first : nil }
        guard Self.matches(file, current) else { return nil }
        if !existing.isEmpty {
            guard Self.matches(file, existing),
                  current[0].ID.map({ $0 != existing[0].ID }) ?? true else { return nil }
            _ = try await checked(["deletefile", old])
        } else if remote == ":local:" {
            // The local rclone Move uses a replacing rename.
            let path = String(new.dropFirst(remote.count))
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Task.checkCancellation()
            guard renamex_np(String(old.dropFirst(remote.count)), path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { return nil }
                throw CloudArchiveError.installFailed
            }
        } else {
            _ = try await checked(["moveto", old, new, "--ignore-existing", "--immutable", "--checksum",
                                   "--disable", "Copy", "--max-transfer", "0"])
        }
        let final = try await siblings(destination)
        let remaining = try await siblings(source)
        return Self.matches(file, final) && remaining.isEmpty ? final.first : nil
    }

    private static func matches(_ file: StorageObject, _ items: [Item]) -> Bool {
        items.count == 1 && !items[0].IsDir && file.size == items[0].Size
            && file.md5 != nil && file.md5 == items[0].object.md5
    }

    private static func uniquePath(_ path: String, in listing: [String: [Item]]) -> Bool {
        var prefix = ""
        let parts = path.components(separatedBy: "/")
        for (index, part) in parts.enumerated() {
            prefix = joining(prefix, part)
            guard let items = listing[prefix] else { continue }
            if items.count != 1 || items[0].IsDir != (index < parts.count - 1) { return false }
        }
        return true
    }

    private func verifyUniqueFolder(_ folder: String) async throws {
        _ = try target(folder)
        guard !folder.isEmpty else { throw StorageBackendError.invalidKey }
        var parent = ""
        for name in folder.components(separatedBy: "/") {
            let matches = try await contents(parent, recursive: false, hashes: false).filter { $0.Name == name }
            guard matches.count == 1, matches[0].IsDir else { throw StorageBackendError.invalidKey }
            parent = Self.joining(parent, name)
        }
    }

    private func contents(_ folder: String, recursive: Bool, hashes: Bool = true) async throws -> [Item] {
        let scope = recursive ? ["--recursive", "--max-depth", "3", "--exclude", "/.arcane-upload/**"] : []
        let hashing = hashes ? ["--hash-type", "MD5"] : []
        do {
            let output = try await checked(["lsjson", try target(folder), "--no-modtime", "--no-mimetype"] + scope + hashing)
            return try JSONDecoder().decode([Item].self, from: Data(output.utf8))
        } catch StorageBackendError.notFound { return [] }
    }

    private func backend(in folder: String) throws -> RcloneStorageBackend {
        let path = try target(folder)
        let prefix = remote == ":local:" ? remote : remote + ":"
        return RcloneStorageBackend(remote: remote, root: String(path.dropFirst(prefix.count)),
                                    executable: executable, config: config)
    }

    private struct Item: Decodable {
        let Name: String
        let IsDir: Bool
        let path: String?
        let size: Int64?
        let Hashes: [String: String]?
        let ID: String?

        enum CodingKeys: String, CodingKey { case Name, IsDir, Hashes, ID, path = "Path", size = "Size" }
        var Path: String { path ?? Name }
        var Size: Int64 { size ?? -1 }
        var object: StorageObject {
            StorageObject(key: StorageObjectKey(Path), size: Size,
                          hashes: (Hashes ?? [:]).reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value })
        }
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
        try await RcloneConfiguration.authorizeDrive(executable: executable, config: staged.config,
            environment: environment, name: remote, clientID: id, secret: password, replacing: true)
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
