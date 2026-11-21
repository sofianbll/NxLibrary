import CryptoKit
import Darwin
import Foundation
import NXLibraryCore

/// `aa list` is checked before extracting. A separate filesystem fingerprint checks what was actually restored.
enum CloudArchiveInventory {
    struct Entry: Decodable, Equatable {
        let path: String
        let type: String
        let size: Int64?
        let link: String?
        let mode: Int

        enum CodingKeys: String, CodingKey { case path = "PAT", type = "TYP", size = "SIZ", link = "LNK", mode = "MOD" }
    }

    struct Snapshot {
        let entries: [Entry]
        let bytes: Int64
        let sha256: String
        let withoutRootMtime: String?
        let hasExcludedFiles: Bool
        let skippedRoots: [String]

        var isSkippedOnly: Bool { entries.count == 1 && !skippedRoots.isEmpty && !hasExcludedFiles }
    }

    static let maximumEntries = 100_000
    static let cacheFingerprintOption = "cache_inventory_without_root_mtime"
    static let excludedNames = ["prod.keys", "title.keys", "dev.keys", "keys.txt"]

    static let excludedPaths = ["run/save", "Contents/Resources/run/save"]
    private static let skippedCacheRoots = ["obsolete", "nsp"]

    static func isExcluded(_ path: String, _ kind: CloudArtifactKind) -> Bool {
        let lower = path.lowercased()
        return excludedNames.contains(where: { lower.split(separator: "/").contains(Substring($0)) })
            || excludedPaths.contains { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "/") }
            || (kind == .cache && skippedCacheRoots.contains { lower == $0 || lower.hasPrefix($0 + "/") })
    }

    static func validate(_ entries: [Entry], kind: CloudArtifactKind) throws -> Int64 {
        var types: [String: String] = [:]
        var bytes: Int64 = 0
        for entry in entries {
            let path = entry.path
            let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
            guard (path.isEmpty ? entry.type == "D" : SaveFiles.validRelative(path)),
                  (0...0o777).contains(entry.mode), !isExcluded(path, kind), types.updateValue(entry.type, forKey: normalized) == nil
            else { throw CloudArchiveError.unsafePath }
            switch entry.type {
            case "D": break
            case "F":
                guard let size = entry.size, size >= 0, size <= Int64.max - bytes else {
                    throw CloudArchiveError.invalidArchive
                }
                bytes += size
            case "L":
                guard let target = entry.link, safeLink(target, at: path, kind: kind) else {
                    throw CloudArchiveError.unsafePath
                }
            default: throw CloudArchiveError.unsafePath
            }
        }
        guard types[""] == "D" else { throw CloudArchiveError.invalidArchive }
        for entry in entries where !entry.path.isEmpty {
            let parent = entry.path.split(separator: "/").dropLast().joined(separator: "/")
            guard types[parent.precomposedStringWithCanonicalMapping.lowercased()] == "D" else {
                throw CloudArchiveError.unsafePath
            }
        }
        return bytes
    }

    private static func safeLink(_ target: String, at path: String, kind: CloudArtifactKind) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var parts = Array(path.split(separator: "/").dropLast())
        var descended = false
        for component in target.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                // Traversing back through a link after following it can escape the root.
                guard !descended, !parts.isEmpty else { return false }
                parts.removeLast()
            } else {
                descended = true
                parts.append(component)
            }
        }
        return !isExcluded(parts.joined(separator: "/"), kind)
    }

    static func scan(_ root: URL, kind: CloudArtifactKind) throws -> Snapshot {
        try scan(root, kind: kind, includeContents: true)
    }

    static func signature(_ root: URL, kind: CloudArtifactKind) throws -> Snapshot {
        try scan(root, kind: kind, includeContents: false)
    }

    static func fingerprintKey(_ root: URL, kind: CloudArtifactKind) -> String {
        hex(SHA256.hash(data: Data("\(kind.rawValue):\(root.path)".utf8)))
    }

    private static func scan(_ root: URL, kind: CloudArtifactKind, includeContents: Bool) throws -> Snapshot {
        var entries: [Entry] = []
        var hash = SHA256()
        var withoutRootMtime = includeContents && kind == .cache ? SHA256() : nil
        var hasExcludedFiles = false
        var skippedRoots: [String] = []
        let device = try node(at: root).st_dev
        func field(_ value: String, rootMtime: Bool = false) {
            let prefix = Data("\(value.utf8.count):".utf8)
            let data = Data(value.utf8)
            hash.update(data: prefix)
            hash.update(data: data)
            if !rootMtime {
                withoutRootMtime?.update(data: prefix)
                withoutRootMtime?.update(data: data)
            }
        }
        func visit(_ url: URL, path: String) throws {
            try Task.checkCancellation()
            if isExcluded(path, kind) {
                if kind == .cache, skippedCacheRoots.contains(path.lowercased()),
                   try node(at: url).st_mode & S_IFMT == S_IFDIR {
                    skippedRoots.append(path)
                } else {
                    hasExcludedFiles = true
                }
                return
            }
            let st = try node(at: url)
            guard st.st_dev == device, st.st_mode & 0o7000 == 0,
                  entries.count < maximumEntries else { throw CloudArchiveError.unsafePath }
            let type: String
            switch st.st_mode & S_IFMT {
            case S_IFDIR: type = "D"
            case S_IFREG: type = "F"
            case S_IFLNK: type = "L"
            default: throw CloudArchiveError.unsafePath
            }
            guard !path.isEmpty || type == "D" else { throw CloudArchiveError.unsafePath }
            let link = type == "L" ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            entries.append(Entry(path: path, type: type, size: type == "F" ? st.st_size : nil,
                                 link: link, mode: Int(st.st_mode & 0o777)))
            for value in [path, type, String(st.st_mode & 0o777)] { field(value) }
            field(String(st.st_mtimespec.tv_sec), rootMtime: path.isEmpty)
            field(String(st.st_mtimespec.tv_nsec), rootMtime: path.isEmpty)
            field(link ?? "")
            if includeContents {
                let attrs = try SaveFiles.attributes(url)
                field(String(attrs.count))
                for (key, data) in attrs.sorted(by: { $0.key < $1.key }) {
                    field(key)
                    field(hex(SHA256.hash(data: data)))
                }
                if type == "F" { field(try hashes(at: url, includeMD5: false)["sha256"]!) }
            } else {
                // ctime also catches xattr and same-size edits with a preserved mtime.
                for value in [String(st.st_dev), String(st.st_ino), String(st.st_size),
                              String(st.st_ctimespec.tv_sec), String(st.st_ctimespec.tv_nsec)] { field(value) }
            }
            if type == "D" {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .sorted(by: { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }) {
                    try visit(child, path: path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent)
                }
            }
        }
        try visit(root, path: "")
        return try Snapshot(entries: entries, bytes: validate(entries, kind: kind),
                            sha256: hex(hash.finalize()), withoutRootMtime: withoutRootMtime.map { hex($0.finalize()) },
                            hasExcludedFiles: hasExcludedFiles, skippedRoots: skippedRoots)
    }

    static func node(at url: URL) throws -> stat {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { throw CloudArchiveError.localMissing }
            throw CloudArchiveError.unsafePath
        }
        return st
    }

    static func hashes(at url: URL, includeMD5: Bool = true) throws -> [String: String] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CloudArchiveError.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat(), sha = SHA256(), md5 = Insecure.MD5()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw CloudArchiveError.unsafePath }
        try handle.forEachChunk { chunk in
            try Task.checkCancellation()
            sha.update(data: chunk)
            if includeMD5 { md5.update(data: chunk) }
        }
        var hashes = ["sha256": hex(sha.finalize())]
        if includeMD5 { hashes["md5"] = hex(md5.finalize()) }
        return hashes
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
