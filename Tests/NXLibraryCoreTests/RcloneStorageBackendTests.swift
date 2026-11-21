import Foundation
import XCTest
@testable import NXLibraryCore

final class RcloneStorageBackendTests: XCTestCase {
    func testProgressParsesStderrStatsWithNullableETAAndFractionalSpeed() throws {
        let line = #"{"level":"notice","msg":"Transferred","stats":{"bytes":270000000,"totalBytes":645000000,"speed":3100000.25,"eta":121,"transferring":[{"name":"fixture"}]}}"#
        let progress = try XCTUnwrap(RcloneStorageBackend.transferProgress(from: line))
        XCTAssertEqual(progress.bytesTransferred, 270_000_000)
        XCTAssertEqual(progress.totalBytes, 645_000_000)
        XCTAssertEqual(progress.bytesPerSecond, 3_100_000.25)
        XCTAssertEqual(progress.etaSeconds, 121)
        XCTAssertEqual(RcloneStorageBackend.transferProgress(from: #"{"msg":"","stats":{"bytes":2,"totalBytes":9,"eta":null,"speed":0}}"#),
                       StorageProgress(bytesTransferred: 2, totalBytes: 9))
        XCTAssertEqual(RcloneStorageBackend.transferProgress(from: #"{"msg":"","stats":{"bytes":2,"totalBytes":8,"eta":null,"speed":0,"transferring":[{"speed":3}]}}"#),
                       StorageProgress(bytesTransferred: 2, totalBytes: 8, bytesPerSecond: 3, etaSeconds: 2))
        XCTAssertNil(RcloneStorageBackend.transferProgress(from: #"{"msg":"not a stats line"}"#))
    }
    func testObjectRoundTripAndTransferProgress() async throws {
        let fixture = try Fixture()
        let bytesSent = expectation(description: "rclone reports transferred bytes")
        bytesSent.assertForOverFulfill = false
        let before = try await fixture.backend.list()
        XCTAssertEqual(before, [])

        try await fixture.backend.put(fixture.source, as: fixture.object) { progress in
            if !progress.isVerifying, progress.bytesTransferred == 4, progress.totalBytes == 4 { bytesSent.fulfill() }
        }
        await fulfillment(of: [bytesSent], timeout: 2)

        let listed = try await fixture.backend.list()
        XCTAssertEqual(listed.map(\.key), [fixture.object.key])
        XCTAssertEqual(listed.first?.size, 4)
        XCTAssertEqual(listed.first?.hashes["sha256"], fixture.object.hashes["sha256"])
        try await fixture.backend.verify(fixture.object)
        try await fixture.backend.get(fixture.object.key, to: fixture.download)
        XCTAssertEqual(try Data(contentsOf: fixture.download), Data("abc\n".utf8))
        try await fixture.backend.delete(fixture.object.key)
        let after = try await fixture.backend.list()
        XCTAssertEqual(after, [])
    }

    func testMissingObjectAndUnavailableBackendAreDistinct() async throws {
        let fixture = try Fixture()
        await assertError(.notFound) { try await fixture.backend.get(fixture.object.key, to: fixture.download) }
        await assertError(.notFound) { try await fixture.backend.verify(fixture.object) }
        await assertError(.notFound) { try await fixture.backend.delete(fixture.object.key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.download.path))
        let unavailable = RcloneStorageBackend(remote: ":local:", root: fixture.remote.path,
                                               executable: fixture.remote.appendingPathComponent("no-rclone"),
                                               config: URL(fileURLWithPath: "/dev/null"))
        await assertError(.backendUnavailable) { _ = try await unavailable.list() }
        let missingRemote = RcloneStorageBackend(remote: "missing-fixture", root: "not-used",
                                                 config: URL(fileURLWithPath: "/dev/null"))
        await assertError(.backendUnavailable) { _ = try await missingRemote.list() }
    }

    func testHashMismatchDoesNotPublishAndExistingObjectsAreNotReplaced() async throws {
        let fixture = try Fixture()
        let wrong = StorageObject(key: fixture.object.key, size: fixture.object.size,
                                  hashes: ["sha256": String(repeating: "0", count: 64)])
        await assertError(.hashMismatch) { try await fixture.backend.put(fixture.source, as: wrong) }
        let afterMismatch = try await fixture.backend.list()
        XCTAssertEqual(afterMismatch, [])
        try fixture.assertStagingEmpty()

        try await fixture.backend.put(fixture.source, as: fixture.object)
        await assertError(.hashMismatch) { try await fixture.backend.verify(wrong) }
        await assertError(.alreadyExists) { try await fixture.backend.put(fixture.source, as: fixture.object) }
        try await fixture.backend.verify(fixture.object)
    }

    func testVerificationDownloadsSHA256EvenWhenRemoteMD5Matches() async throws {
        let fixture = try Fixture()
        let config = fixture.directory.appendingPathComponent("rclone-test.conf")
        try Data("[fixture]\ntype = local\nhashes = md5\n".utf8).write(to: config)
        let backend = RcloneStorageBackend(remote: "fixture", root: fixture.remote.path, config: config)
        let md5 = "0bee89b07a248e27c83fc3d5951213c1"
        let wrong = StorageObject(key: fixture.object.key, size: fixture.object.size,
                                  hashes: ["sha256": String(repeating: "0", count: 64), "md5": md5])
        try await backend.put(fixture.source, as: fixture.object)
        let listed = try await backend.list()
        XCTAssertEqual(listed.first?.hashes, ["md5": md5])
        try await backend.verify(fixture.object)
        await assertError(.hashMismatch) { try await backend.verify(wrong) }
    }

    func testFailedFinalVerificationDeletesOnlyAnObjectThisPutCreated() async throws {
        for concurrentWriter in [false, true] {
            let fixture = try Fixture()
            let binary = try XCTUnwrap(RcloneStorageBackend.findExecutable())
            let final = fixture.remote.appendingPathComponent(fixture.object.key.value)
            let shim = fixture.directory.appendingPathComponent("rclone-shim")
            // For the real local backend, corrupt the result of a fresh move or put a different
            // writer's file at the destination after the initial stat but before the move.
            let mutate = "printf 'bad\\n' > \"$target\""
            let script = """
                #!/bin/sh
                real=\(shellQuoted(binary.path))
                if [ "$1" = moveto ]; then
                    target=${3#:local:}
                    \(concurrentWriter ? "/bin/mkdir -p \"${target%/*}\" || exit 1\n    " + mutate : "")
                    "$real" "$@" || exit $?
                    \(concurrentWriter ? ":" : mutate)
                else
                    exec "$real" "$@"
                fi
                """
            try Data(script.utf8).write(to: shim)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            let backend = RcloneStorageBackend(remote: ":local:", root: fixture.remote.path,
                                               executable: shim, config: URL(fileURLWithPath: "/dev/null"))
            await assertError(concurrentWriter ? .alreadyExists : .hashMismatch) {
                try await backend.put(fixture.source, as: fixture.object)
            }
            if concurrentWriter {
                XCTAssertEqual(try Data(contentsOf: final), Data("bad\n".utf8))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            }
            try fixture.assertStagingEmpty()
        }
    }

    func testCancellationBeforePublicationCleansStaging() async throws {
        let fixture = try Fixture()
        let copying = expectation(description: "rclone sends progress before publishing")
        copying.assertForOverFulfill = false
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let transfer = Task {
            try await fixture.backend.put(fixture.source, as: fixture.object) { progress in
                if progress.bytesTransferred > 0 {
                    copying.fulfill()
                    _ = resume.wait(timeout: .now() + 5)
                }
            }
        }
        await fulfillment(of: [copying], timeout: 4)
        let beforeCancel = try await fixture.backend.list()
        XCTAssertEqual(beforeCancel, [])
        let staging = fixture.remote.appendingPathComponent(".arcane-upload", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path).count, 1)
        transfer.cancel()
        resume.signal()
        do {
            try await transfer.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let afterCancel = try await fixture.backend.list()
            XCTAssertEqual(afterCancel, [])
            try fixture.assertStagingEmpty()
        }
    }

    func testRejectsTraversalAndRcloneConnectionStrings() async throws {
        let fixture = try Fixture()
        await assertError(.invalidKey) { try await fixture.backend.delete(StorageObjectKey("../fixture")) }
        try FileManager.default.createSymbolicLink(at: fixture.remote.appendingPathComponent("outside"),
                                                   withDestinationURL: fixture.directory)
        await assertError(.invalidKey) { try await fixture.backend.delete(StorageObjectKey("outside/fixture file")) }
        let inline = RcloneStorageBackend(remote: ":local,links:", root: fixture.remote.path,
                                          config: URL(fileURLWithPath: "/dev/null"))
        await assertError(.invalidConfiguration) { _ = try await inline.list() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    private func assertError(_ expected: StorageBackendError, file: StaticString = #filePath, line: UInt = #line,
                             operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StorageBackendError, expected, file: file, line: line)
        }
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private final class Fixture {
        let directory: URL
        let remote: URL
        let source: URL
        let download: URL
        let backend: RcloneStorageBackend
        let object = StorageObject(key: StorageObjectKey("title/artifact with spaces.aar"), size: 4,
                                   hashes: ["sha256": "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb"])

        init() throws {
            let config = URL(fileURLWithPath: "/dev/null")
            guard RcloneStorageBackend.findExecutable() != nil else {
                throw XCTSkip("rclone absent from /opt/homebrew/bin and PATH; local integration test skipped")
            }
            let fm = FileManager.default
            directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            remote = directory.appendingPathComponent("remote root", isDirectory: true)
            source = directory.appendingPathComponent("fixture file")
            download = directory.appendingPathComponent("download file")
            backend = RcloneStorageBackend(remote: ":local:", root: remote.path, config: config)
            try fm.createDirectory(at: remote, withIntermediateDirectories: true)
            try Data("abc\n".utf8).write(to: source)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func assertStagingEmpty() throws {
            let staging = remote.appendingPathComponent(".arcane-upload", isDirectory: true)
            let fm = FileManager.default
            if fm.fileExists(atPath: staging.path) {
                XCTAssertEqual(try fm.contentsOfDirectory(atPath: staging.path), [])
            }
        }
    }
}
