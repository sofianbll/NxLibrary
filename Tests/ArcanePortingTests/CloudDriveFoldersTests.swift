import Foundation
import XCTest
@testable import NXLibraryCore
@testable import ArcanePorting

final class CloudDriveFoldersTests: XCTestCase {
    func testSavedMoveCanBeCancelledThenRetryReusesTheDestinationCopy() async throws {
        let title = "0100123456789ABC"
        let name = String(repeating: "a", count: 64) + ".aar"
        let hash = String(repeating: "b", count: 32)
        let key = "\(title)/app/\(name)"
        let payload = """
        {"source":"Old","remote":"fixture","games":1,"bytes":7,"entries":[
          {"file":{"key":{"value":"\(key)"},"size":7,"hashes":{"md5":"\(hash)"}},"dependencies":[]}]}
        """
        let plan = try JSONDecoder().decode(CloudDriveFolders.MovePlan.self, from: Data(payload.utf8))
        let saved = try JSONEncoder().encode(LibraryMoveRequest(plan: plan, destination: "New"))
        let restored = try JSONDecoder().decode(LibraryMoveRequest.self, from: saved)
        let drive = CloudDriveFolders(remote: "fixture", executable: URL(fileURLWithPath: "/synthetic/rclone"),
                                      config: URL(fileURLWithPath: "/dev/null")) { _, args, _ in
            XCTAssertEqual(args[0], "lsjson", "The verified destination copy must not be moved again")
            let listing: String
            switch args[1] {
            case "fixture:": listing = #"[{"Name":"Old","IsDir":true},{"Name":"New","IsDir":true}]"#
            case "fixture:New": listing = #"[{"Name":"\#(name)","Path":"\#(key)","IsDir":false}]"#
            case "fixture:New/\(title)/app":
                listing = #"[{"Name":"\#(name)","Size":7,"IsDir":false,"Hashes":{"MD5":"\#(hash)"}}]"#
            default: listing = "[]"
            }
            return .init(status: 0, stdout: listing, stderr: "")
        }
        do {
            _ = try await drive.move(restored.plan, to: restored.destination) { done, total in
                XCTAssertEqual(done, 0)
                XCTAssertEqual(total, 1)
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        var progress = [Int]()
        let conflicts = try await drive.move(restored.plan, to: restored.destination) { done, _ in
            progress.append(done)
        }
        XCTAssertEqual(progress, [0, 1])
        XCTAssertEqual(conflicts, [])
        let invalid = try JSONDecoder().decode(CloudDriveFolders.MovePlan.self,
            from: Data(payload.replacingOccurrences(of: key, with: "\(title)/GameFiles/test.nsp").utf8))
        do {
            _ = try await drive.move(invalid, to: "New") { _, _ in XCTFail("Invalid entry reached progress") }
            XCTFail("Only archive keys can be restored from disk")
        } catch StorageBackendError.invalidKey {}
    }

    func testArchiveManifestWaitsForObjectsOnResumeAndMoveLeavesGameFilesInPlace() async throws {
        try await withMoveFixture { drive, root in
            let title = "0100123456789ABC"
            let old = root.appendingPathComponent("Old")
            let new = root.appendingPathComponent("New")
            let fm = FileManager.default
            let payload = root.appendingPathComponent("payload")
            try Data("archive".utf8).write(to: payload)
            let hashes = try CloudArchiveInventory.hashes(at: payload)
            let sha = try XCTUnwrap(hashes["sha256"]), md5 = try XCTUnwrap(hashes["md5"])
            let artifacts = CloudArtifactKind.allCases.map {
                CloudGameManifest.Artifact(kind: $0, size: 7, sha256: sha, md5: md5, unpackedSize: 1,
                    entryCount: 1, inventorySHA256: sha, engineCommit: nil, shaderChain: nil, options: [:])
            }
            let manifest = CloudGameManifest(version: 1, titleID: title, createdAt: Date(), artifacts: artifacts)
            let manifestDir = old.appendingPathComponent("\(title)/manifests")
            try fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let staged = root.appendingPathComponent("fixture.json")
            try encoder.encode(manifest).write(to: staged)
            let checksum = try XCTUnwrap(CloudArchiveInventory.hashes(at: staged)["sha256"])
            let manifestPath = "\(title)/manifests/0000000000000001-\(checksum).json"
            try fm.moveItem(at: staged, to: old.appendingPathComponent(manifestPath))
            let keys = artifacts.map { $0.object(titleID: title).key.value }.sorted()
            for key in keys {
                let target = old.appendingPathComponent(key)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: payload, to: target)
            }
            let gameFiles = ["Switch/Jeux/Other/game.nsp", "GameFiles/Test [\(title)]/game.xci"]
            for path in gameFiles {
                let source = old.appendingPathComponent(path)
                try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: payload, to: source)
            }
            let clash = new.appendingPathComponent(keys[1])
            try fm.createDirectory(at: clash.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("changed".utf8).write(to: clash)
            let plan = try await drive.movePlan(from: "Old")
            XCTAssertEqual(plan.games, 1)
            XCTAssertEqual(plan.bytes, 14 + (try CloudArchiveInventory.node(at: old.appendingPathComponent(manifestPath)).st_size))
            do {
                _ = try await drive.move(plan, to: "New") { done, _ in
                    if done == 1 { throw CancellationError() }
                }
                XCTFail("Expected cancellation")
            } catch is CancellationError {}
            XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent(keys[0]).path))
            XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent(keys[1]).path))
            let conflicts = try await drive.move(plan, to: "New") { done, total in
                if done < total {
                    XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent(manifestPath).path))
                }
            }
            XCTAssertEqual(conflicts, [keys[1], manifestPath])
            XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent(manifestPath).path))
            XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent(keys[0]).path))
            try fm.removeItem(at: clash)
            let resumed = try await drive.movePlan(from: "Old")
            let remaining = try await drive.move(resumed, to: "New") { _, _ in }
            XCTAssertEqual(remaining, [])
            let count = try await drive.libraryCount(in: "New", folders: [title])
            XCTAssertEqual(count, 1)
            XCTAssertFalse(fm.fileExists(atPath: old.appendingPathComponent(manifestPath).path))
            for path in gameFiles {
                XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent(path)), Data("archive".utf8))
                XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent(path).path))
            }
        }
    }

    private func withMoveFixture(_ body: (CloudDriveFolders, URL) async throws -> Void) async throws {
        guard let executable = RcloneStorageBackend.findExecutable() else { throw XCTSkip("rclone is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        for name in ["Old", "New"] { try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false) }
        try await body(CloudDriveFolders(remote: ":local:", executable: executable, localRoot: root,
                                        config: root.appendingPathComponent("rclone.conf")), root)
    }

    func testListAndExplicitCreateWithLocalRemote() async throws {
        guard let executable = RcloneStorageBackend.findExecutable() else { throw XCTSkip("rclone is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("file"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Existing"), withIntermediateDirectories: false)
        let drive = CloudDriveFolders(remote: ":local:", executable: executable, localRoot: root,
                                     config: root.appendingPathComponent("rclone.conf"))
        let ticket = UUID()
        let listing = try await drive.list("", ticket: ticket)
        XCTAssertEqual(listing.ticket, ticket)
        XCTAssertEqual(listing.names, ["Existing"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Arcane").path))
        try await drive.create("Arcane", in: "")
        try await drive.create("Arcane", in: "")
        let names = try await drive.list("", ticket: UUID()).names
        XCTAssertEqual(names, ["Arcane", "Existing"])
        try await drive.verifyAccess(to: "Arcane")
        let titleID = "0100123456789ABC"
        let count = try await drive.libraryCount(in: "Arcane", folders: [titleID])
        XCTAssertEqual(count, 0)
        let manifests = root.appendingPathComponent("Arcane/0100123456789ABC/manifests")
        try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: manifests.appendingPathComponent("invalid.json"))
        do {
            _ = try await drive.libraryCount(in: "Arcane", folders: [titleID])
            XCTFail("An invalid manifest cannot become a zero-game library")
        } catch CloudArchiveError.invalidManifest {}
        try FileManager.default.removeItem(at: manifests.appendingPathComponent("invalid.json"))
        let manifest = CloudGameManifest(version: 1, titleID: titleID, createdAt: Date(),
            artifacts: CloudArtifactKind.allCases.map {
                .init(kind: $0, size: 1, sha256: String(repeating: "a", count: 64),
                      md5: String(repeating: "b", count: 32), unpackedSize: 1, entryCount: 1,
                      inventorySHA256: String(repeating: "c", count: 64), engineCommit: nil, shaderChain: nil, options: [:])
            })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let staged = root.appendingPathComponent("fixture.json")
        try encoder.encode(manifest).write(to: staged)
        let checksum = try XCTUnwrap(CloudArchiveInventory.hashes(at: staged)["sha256"])
        try FileManager.default.moveItem(at: staged, to: manifests.appendingPathComponent("0000000000000001-\(checksum).json"))
        let found = try await drive.libraryCount(in: "Arcane", folders: [titleID, titleID.lowercased(), "Other"])
        XCTAssertEqual(found, 1)
    }

    func testLostMkdirResponseIsReconciledWithoutResubmitting() async throws {
        let calls = Calls()
        let drive = CloudDriveFolders(remote: "drive", executable: URL(fileURLWithPath: "/rclone")) { _, args, _ in
            await calls.run(args[0])
        }
        try await drive.create("Arcane", in: "")
        let commands = await calls.commands
        XCTAssertEqual(commands, ["lsjson", "mkdir", "lsjson"])
    }

    func testConfigReplacementRejectsExternalEditAndKeepsPreviousFileUntilApply() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("rclone.conf")
        let first = Data("RCLONE_ENCRYPT_V0:\nfirst".utf8)
        let candidate = Data("RCLONE_ENCRYPT_V0:\ncandidate".utf8)
        let external = Data("RCLONE_ENCRYPT_V0:\nexternal".utf8)
        try first.write(to: original)
        let stale = try CloudDriveCredentialChange.stage(original)
        try candidate.write(to: stale.config)
        XCTAssertEqual(try Data(contentsOf: original), first)
        try external.write(to: original)
        XCTAssertThrowsError(try stale.apply())
        XCTAssertEqual(try Data(contentsOf: original), external)
        let fresh = try CloudDriveCredentialChange.stage(original)
        try candidate.write(to: fresh.config)
        try fresh.apply()
        XCTAssertEqual(try Data(contentsOf: original), candidate)
    }

    private actor Calls {
        var commands: [String] = []
        func run(_ command: String) -> CommandResult {
            commands.append(command)
            if command == "mkdir" { return .init(status: 1, stdout: "", stderr: "lost response") }
            return .init(status: 0, stdout: commands.count == 1 ? "[]" : #"[{"Name":"Arcane","IsDir":true}]"#, stderr: "")
        }
    }
}
