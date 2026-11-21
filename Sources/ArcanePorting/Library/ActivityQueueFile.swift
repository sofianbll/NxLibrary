import Foundation
import OSLog

/// The activity queues and history share the profiled, atomic snapshot format.
package final class ActivityQueueFile<Entry: Codable & Sendable>: Sendable {
    private struct DecodedEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    private struct Snapshot: Decodable {
        let version: Int
        let entries: [DecodedEntry]
    }

    private struct WriteSnapshot: Encodable {
        let version = 1
        let entries: [Entry]
    }

    private let file: URL
    private let io = DispatchQueue(label: "local.nxlibrary.activity-queue", qos: .utility)
    private let log = Logger(subsystem: "local.nxlibrary", category: "activity-queue")
    // Only the serial IO queue accesses this flag. Do not erase a file from a newer version
    // or replace an unreadable snapshot with a seemingly valid empty one.
    private let canWrite = OSAllocatedUnfairLock(initialState: true)

    package init(file: URL) { self.file = file }

    package func load() async -> [Entry] {
        await withCheckedContinuation { continuation in
            io.async {
                do {
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: self.file))
                    if snapshot.version == 1 {
                        continuation.resume(returning: snapshot.entries.compactMap(\.entry))
                        return
                    }
                    self.log.error("Unsupported activity snapshot version")
                    self.canWrite.withLock { $0 = false }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    // No snapshot has been written in this profile.
                } catch {
                    self.log.error("Could not read the activity snapshot")
                    self.canWrite.withLock { $0 = false }
                }
                continuation.resume(returning: [])
            }
        }
    }

    package func save(_ entries: [Entry]) {
        io.async {
            guard self.canWrite.withLock({ $0 }) else { return }
            do {
                try FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(WriteSnapshot(entries: entries)).write(to: self.file, options: .atomic)
            } catch {
                self.log.error("Could not save the activity snapshot")
            }
        }
    }

    package func flush() async {
        await withCheckedContinuation { continuation in io.async { continuation.resume() } }
    }
}
