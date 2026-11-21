import XCTest
@testable import NXLibraryCore

final class RcloneConfigurationTests: XCTestCase {
    func testLegacyPreferenceAndDisabledSelection() {
        XCTAssertFalse(CloudLibraryPreference(storage: nil, enabled: nil).enabled)
        XCTAssertEqual(CloudLibraryPreference(storage: "gdrive", enabled: nil).root, "Games")
        let legacy = CloudLibraryPreference(storage: " gdrive:Library/Arcade ", enabled: nil)
        XCTAssertEqual(legacy.remote, "gdrive")
        XCTAssertEqual(legacy.root, "Library/Arcade")
        XCTAssertTrue(legacy.enabled)
        XCTAssertFalse(CloudLibraryPreference(storage: legacy.storage, enabled: false).enabled)
        XCTAssertNil(CloudLibraryPreference(storage: "bad,remote:Games", enabled: nil).remote)
        XCTAssertNil(CloudLibraryPreference(storage: "gdrive:../Games", enabled: nil).remote)
        let folderFirst = CloudLibraryPreference(storage: ":New Games", enabled: nil)
        XCTAssertNil(folderFirst.remote)
        XCTAssertEqual(folderFirst.storage, ":New Games")
    }

    func testSourcesRootDefaultsToLibraryGameFilesOrUsesAnIndependentPath() {
        XCTAssertEqual(CloudLibraryPreference(storage: nil, enabled: nil).sourcesRoot, "Games/GameFiles")
        XCTAssertEqual(CloudLibraryPreference(storage: "drive:Games/Switch/Arcane-nx/", enabled: true).sourcesRoot,
                       "Games/Switch/Arcane-nx/GameFiles")
        for library in ["Games/Switch/Arcane-nx", "Archive/Arcane"] {
            let preference = CloudLibraryPreference(storage: "drive:\(library)", enabled: true, sourcesRoot: "Games/Switch/Jeux")
            XCTAssertEqual(preference.storage, "drive:\(library)")
            XCTAssertEqual(preference.sourcesRoot, "Games/Switch/Jeux")
            XCTAssertEqual(preference.sourcesStorage, "drive:Games/Switch/Jeux")
        }
        for invalid in ["", " ", "../Jeux", "other:Jeux", "/Games/Jeux"] {
            let preference = CloudLibraryPreference(storage: "drive:Archive", enabled: true, sourcesRoot: invalid)
            XCTAssertNil(preference.sourcesRootOverride)
            XCTAssertEqual(preference.sourcesRoot, "Archive/GameFiles")
        }
    }

    func testListParsesFileRemotesAndReportsConfigurationNotNetworkStatus() throws {
        let remotes = try RcloneConfiguration.parseRemotes(Self.list)
        XCTAssertEqual(remotes.map(\.name), ["gdrive", "other drive"])
        XCTAssertEqual(remotes.map(\.type), ["drive", "sftp"])
        let config = CloudLibraryPreference(storage: "gdrive:Games", enabled: false)
        XCTAssertEqual(config.connection(in: remotes), .connected(remotes[0]))
        XCTAssertEqual(config.connection(in: []), .notConnected)
        XCTAssertEqual(config.connection(in: nil), .unknown)
        XCTAssertEqual(CloudLibraryPreference(storage: nil, enabled: true).connection(in: nil), .notConnected)
        XCTAssertThrowsError(try RcloneConfiguration.parseRemotes("gdrive:"))
    }

    func testConnectEncryptsBeforeBrowserAndVerifiesRemote() async throws {
        let fixture = Fixture([
            .ok(Self.list),
            CommandResult(status: 1, stdout: "", stderr: "Error: config file is NOT encrypted"),
            .ok(), .ok(), .ok(),
            .ok(#"[{"name":"gdrive-2","type":"drive","source":"file"}]"#),
        ])
        let remote = try await fixture.client.connect(clientID: "fake-client", secret: "fake-secret")
        XCTAssertEqual(remote.name, "gdrive-2")
        let commands = await fixture.recorder.commands
        let flags = ["--ask-password=false", "--config", fixture.config.path,
                     "--password-command", "/usr/bin/security find-generic-password -a rclone -s rclone-config -w"]
        XCTAssertEqual(commands, [
            ["listremotes", "--json"], ["config", "encryption", "check"],
            ["KEYCHAIN"], ["config", "encryption", "set"], ["config", "encryption", "check"],
            ["config", "create", "gdrive-2", "drive", "client_id=fake-client", "client_secret=fake-secret",
             "scope=drive", "config_is_local=true", "--no-output"],
            ["listremotes", "--json"],
        ].map { $0 == ["KEYCHAIN"] ? $0 : $0 + flags })
    }

    func testEncryptedConfigIsNotChangedAndFailureDropsProcessOutput() async throws {
        let fixture = Fixture([.ok(Self.list), .ok(), CommandResult(status: 1,
            stdout: "fake-secret", stderr: #"{"access_token":"fake-token"}"#)])
        do {
            _ = try await fixture.client.connect(clientID: "fake-client", secret: "fake-secret")
            XCTFail("OAuth failed")
        } catch {
            XCTAssertEqual(error as? RcloneConfiguration.Failure, .connect)
            XCTAssertFalse(error.localizedDescription.contains("fake-"))
        }
        let commands = await fixture.recorder.commands
        XCTAssertEqual(commands.count, 3)
        XCTAssertFalse(commands.contains(["KEYCHAIN"]))
    }

    func testReadOnlyFolderTestRejectsFilesAndDisconnectDeletesOnlyLocalConfig() async throws {
        let folder = Fixture([.ok(#"{"IsDir":true}"#), .ok("synthetic-file"), .ok(), .ok("[]")])
        let config = CloudLibraryPreference(storage: "gdrive:Games", enabled: true)
        try await folder.client.test(config)
        try await folder.client.disconnect("gdrive")
        let commands = await folder.recorder.commands.map { Array($0.prefix(3)) }
        XCTAssertEqual(commands, [["lsjson", "gdrive:Games", "--stat"], ["lsf", "gdrive:Games", "--max-depth"],
                                  ["config", "delete", "gdrive"], ["listremotes", "--json", "--ask-password=false"]])

        let file = Fixture([.ok(#"{"IsDir":false}"#)])
        do {
            try await file.client.test(config)
            XCTFail("A file is not a folder")
        } catch {
            XCTAssertEqual(error as? RcloneConfiguration.Failure, .test)
        }
        let count = await file.recorder.commands.count
        XCTAssertEqual(count, 1)
    }

    private static let list = """
    [
        {"name":"gdrive","type":"drive","source":"file","description":"do not display"},
        {"name":"other drive","type":"sftp","source":"file"},
        {"name":"external","type":"sftp","source":"environment"},
        {"name":"unexpected,options","type":"drive","source":"file"}
    ]
    """

    private struct Fixture {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("rclone.conf")
        let recorder: Recorder
        init(_ replies: [CommandResult]) { recorder = Recorder(replies) }
        var client: RcloneConfiguration {
            let recorder = recorder
            return RcloneConfiguration(executable: URL(fileURLWithPath: "/fake/rclone"), config: config,
                run: { _, args, _ in await recorder.run(args) },
                ensurePassword: { await recorder.recordPassword() })
        }
    }

    private actor Recorder {
        var commands: [[String]] = []
        var replies: [CommandResult]
        init(_ replies: [CommandResult]) { self.replies = replies }
        func run(_ args: [String]) -> CommandResult {
            commands.append(args)
            return replies.isEmpty ? CommandResult(status: 1, stdout: "", stderr: "") : replies.removeFirst()
        }
        func recordPassword() { commands.append(["KEYCHAIN"]) }
    }
}

private extension CommandResult {
    static func ok(_ stdout: String = "") -> Self { .init(status: 0, stdout: stdout, stderr: "") }
}
