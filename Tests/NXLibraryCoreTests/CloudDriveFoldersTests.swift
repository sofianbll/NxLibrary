import Foundation
import XCTest
@testable import NXLibraryCore

final class CloudDriveFoldersTests: XCTestCase {
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
