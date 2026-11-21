import AppleArchive
import CryptoKit
import Darwin
import Foundation
import NXLibraryCore
import System

/// The archive is teed to rclone and an Apple Archive decoder, never to a local file.
enum CloudArchiveStream {
    struct Result {
        let bytes: Int64
        let sha256: String
        let md5: String
        let entries: [CloudArchiveInventory.Entry]
        let fingerprint: String
    }

    static func send(_ arguments: [String], to sink: Process, kind: CloudArtifactKind,
                     estimatedBytes: Int64, progress: (@Sendable (StorageProgress) -> Void)?) async throws -> Result {
        let archiver = CommandCancellation(), uploader = CommandCancellation()
        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Swift.Result {
                        try pump(arguments, to: sink, kind: kind, estimatedBytes: estimatedBytes, progress: progress,
                                 archiver: archiver, uploader: uploader)
                    })
                }
            }
            try Task.checkCancellation()
            return try result.get()
        } onCancel: {
            archiver.cancel()
            uploader.cancel()
        }
    }

    private static func pump(_ arguments: [String], to sink: Process, kind: CloudArtifactKind,
                             estimatedBytes: Int64, progress: (@Sendable (StorageProgress) -> Void)?,
                             archiver: CommandCancellation, uploader: CommandCancellation) throws -> Result {
        let fromAA = Pipe(), toRclone = Pipe(), toDecoder = Pipe()
        let producer = Process()
        producer.executableURL = URL(fileURLWithPath: "/usr/bin/aa")
        producer.arguments = arguments
        producer.standardInput = FileHandle.nullDevice
        producer.standardError = FileHandle.nullDevice
        producer.standardOutput = fromAA
        sink.standardInput = toRclone
        sink.standardOutput = FileHandle.nullDevice
        sink.standardError = FileHandle.nullDevice

        let send = toRclone.fileHandleForWriting, inspect = toDecoder.fileHandleForWriting
        for writer in [send, inspect] {
            guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CloudArchiveError.invalidArchive }
        }
        try uploader.launch(sink)
        defer { uploader.cancel(); sink.waitUntilExit(); uploader.finish() }
        try archiver.launch(producer)
        defer { archiver.cancel(); producer.waitUntilExit(); archiver.finish() }

        var inventory: Swift.Result<Decoded, Error>?
        let reader = toDecoder.fileHandleForReading
        let decoded = DispatchWorkItem {
            inventory = Swift.Result { try decode(reader, kind: kind) }
            try? reader.close()
        }
        DispatchQueue.global(qos: .utility).async(execute: decoded)
        var sha256 = SHA256(), md5 = Insecure.MD5(), bytes: Int64 = 0
        let start = ProcessInfo.processInfo.systemUptime
        var lastUpdate = -Double.infinity
        do {
            try fromAA.fileHandleForReading.forEachChunk { chunk in
                try inspect.write(contentsOf: chunk)
                try send.write(contentsOf: chunk)
                sha256.update(data: chunk)
                md5.update(data: chunk)
                bytes += Int64(chunk.count)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.25 {
                    lastUpdate = now
                    let speed = Double(bytes) / max(0.001, now - start)
                    progress?(.init(bytesTransferred: bytes, totalBytes: estimatedBytes, bytesPerSecond: speed,
                                    etaSeconds: Double(max(0, estimatedBytes - bytes)) / speed))
                }
            }
        } catch {
            archiver.cancel()
            uploader.cancel()
            try? send.close()
            try? inspect.close()
            decoded.wait()
            if case .failure(let failure) = inventory { throw failure }
            throw error
        }
        try? send.close()
        try? inspect.close()
        decoded.wait()
        producer.waitUntilExit()
        sink.waitUntilExit()
        guard producer.terminationStatus == 0, bytes > 0 else { throw CloudArchiveError.invalidArchive }
        guard sink.terminationStatus == 0 else { throw StorageBackendError.processFailed(status: sink.terminationStatus) }
        guard let inventory else { throw CloudArchiveError.invalidArchive }
        let (entries, fingerprint) = try inventory.get()
        progress?(.init(bytesTransferred: bytes, totalBytes: estimatedBytes))
        return Result(bytes: bytes, sha256: CloudArchiveInventory.hex(sha256.finalize()),
                      md5: CloudArchiveInventory.hex(md5.finalize()), entries: entries, fingerprint: fingerprint)
    }

    private typealias Decoded = (entries: [CloudArchiveInventory.Entry], fingerprint: String)

    private struct Record {
        let entry: CloudArchiveInventory.Entry
        let mtime: timespec
        let attributes: [(String, String)]
        let fileSHA256: String?
    }

    private static func decode(_ input: FileHandle, kind: CloudArtifactKind) throws -> Decoded {
        guard let file = ArchiveByteStream.fileStream(fd: .init(rawValue: input.fileDescriptor), automaticClose: false),
              let unzip = ArchiveByteStream.decompressionStream(readingFrom: file, threadCount: 2),
              let archive = ArchiveStream.decodeStream(readingFrom: unzip) else { throw CloudArchiveError.invalidArchive }
        defer { try? archive.close(); try? unzip.close(); try? file.close() }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 8)
        defer { buffer.deallocate() }
        var records: [Record] = []
        while let record = try autoreleasepool(invoking: { () -> Record? in
            guard let header = try archive.readHeader() else { return nil }
            guard records.count < CloudArchiveInventory.maximumEntries else { throw CloudArchiveError.invalidArchive }
            return try read(header, from: archive, buffer: buffer)
        }) { records.append(record) }
        // Match the local fingerprint's depth-first order, independently of aa's entry order.
        let ordered = records.map { ($0, $0.entry.path.split(separator: "/")) }.sorted { lhs, rhs in
            lhs.1.lexicographicallyPrecedes(rhs.1) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
        var fingerprint = CloudArchiveInventory.ContentFingerprint(kind: kind)
        for (record, _) in ordered {
            fingerprint.entry(record.entry, mtime: record.mtime)
            fingerprint.contents(attributes: record.attributes, fileSHA256: record.fileSHA256)
        }
        let entries = records.map(\.entry)
        _ = try CloudArchiveInventory.validate(entries, kind: kind)
        return (entries, fingerprint.digest)
    }

    private static func read(_ header: ArchiveHeader, from archive: ArchiveStream,
                             buffer: UnsafeMutableRawBufferPointer) throws -> Record {
        func uint(_ key: String) -> UInt64? {
            if case let .uint(_, value)? = header.field(forKey: .init(key)) { return value }
            return nil
        }
        func string(_ key: String) -> String? {
            if case let .string(_, value)? = header.field(forKey: .init(key)) { return value }
            return nil
        }
        guard let path = string("PAT"), let type = uint("TYP").flatMap(UInt8.init(exactly:)),
              let mode = uint("MOD").flatMap(Int.init(exactly:)),
              case let .timespec(_, mtime)? = header.field(forKey: .init("MTM")) else { throw CloudArchiveError.invalidArchive }
        let entry = CloudArchiveInventory.Entry(path: path, type: String(UnicodeScalar(type)),
            size: uint("SIZ").flatMap(Int64.init(exactly:)), link: string("LNK"), mode: mode)
        var attributes: [(String, String)] = [], fileSHA256: String?
        for case let .blob(key, size, _) in header {
            if key == .init("XAT") {
                attributes = try readAttributes(size, from: archive, buffer: buffer)
                continue
            }
            if key == .init("DAT") {
                guard let expected = entry.size, size == UInt64(expected) else { throw CloudArchiveError.invalidArchive }
                fileSHA256 = try digestBlob(size, key: key, from: archive, buffer: buffer)
            } else {
                try readBlob(size, key: key, from: archive, buffer: buffer) { _ in }
            }
        }
        guard entry.type != "F" || fileSHA256 != nil else { throw CloudArchiveError.invalidArchive }
        return Record(entry: entry, mtime: mtime, attributes: attributes, fileSHA256: fileSHA256)
    }

    private static func readBlob(_ size: UInt64, key: ArchiveHeader.FieldKey, from archive: ArchiveStream,
                                 buffer: UnsafeMutableRawBufferPointer, consume: (UnsafeRawBufferPointer) -> Void) throws {
        var remaining = size
        while remaining > 0 {
            let count = min(UInt64(buffer.count), remaining)
            let chunk = UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(Int(count)))
            try archive.readBlob(key: key, into: chunk)
            consume(UnsafeRawBufferPointer(chunk))
            remaining -= count
        }
    }

    private static func digestBlob(_ size: UInt64, key: ArchiveHeader.FieldKey, from archive: ArchiveStream,
                                   buffer: UnsafeMutableRawBufferPointer) throws -> String {
        var hash = SHA256()
        try readBlob(size, key: key, from: archive, buffer: buffer) { hash.update(bufferPointer: $0) }
        return CloudArchiveInventory.hex(hash.finalize())
    }

    private static func readAttributes(_ size: UInt64, from archive: ArchiveStream,
                                       buffer: UnsafeMutableRawBufferPointer) throws -> [(String, String)] {
        let key = ArchiveHeader.FieldKey("XAT")
        var digests: [String: String] = [:], remaining = size
        func read(_ count: Int) throws {
            try archive.readBlob(key: key, into: .init(rebasing: buffer.prefix(count)))
        }
        // AAEntryXATBlob.h: each record starts with its total uint32 size and a NUL-terminated name.
        while remaining > 0 {
            guard remaining >= 5 else { throw CloudArchiveError.invalidArchive }
            try read(4)
            let length = UInt64(UInt32(littleEndian: buffer.load(as: UInt32.self)))
            guard (5...remaining).contains(length) else { throw CloudArchiveError.invalidArchive }
            var name: [UInt8] = [], valueLength = length - 4
            while true {
                guard valueLength > 0, name.count <= XATTR_MAXNAMELEN else { throw CloudArchiveError.invalidArchive }
                try read(1)
                valueLength -= 1
                if buffer[0] == 0 { break }
                name.append(buffer[0])
            }
            let attribute = String(decoding: name, as: UTF8.self)
            switch attribute {
            case "com.apple.provenance", "com.apple.macl":
                try readBlob(valueLength, key: key, from: archive, buffer: buffer) { _ in }
            case "com.apple.quarantine":
                // shortcut: reject oversized quarantine records; support them if macOS emits any over 1 MiB.
                guard valueLength <= buffer.count else { throw CloudArchiveError.invalidArchive }
                if valueLength != 0 { try read(Int(valueLength)) }
                let value = Data(buffer.prefix(Int(valueLength)))
                digests[attribute] = CloudArchiveInventory.attributeDigests(SaveFiles.portableAttributes([attribute: value])).first?.1
            default:
                digests[attribute] = try digestBlob(valueLength, key: key, from: archive, buffer: buffer)
            }
            remaining -= length
        }
        return digests.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
