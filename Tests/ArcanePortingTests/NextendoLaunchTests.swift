import XCTest
@testable import NXLibraryCore
@testable import ArcanePorting

final class NextendoLaunchTests: XCTestCase {
    private func networkSetting(online: Bool) throws -> LauncherSetting {
        let option = online ? #",["nextendo","Nextendo (online)"]"# : ""
        let json = """
        {"env":"DM_NETWORK","kind":"choice","section":"Game","label":"Network","default":"offline",
         "options":[["offline","Offline"],["lan","LAN"],["ldn","Local wireless"]\(option)]}
        """
        let setting = try JSONDecoder().decode(LauncherSetting.self, from: Data(json.utf8))
        return try XCTUnwrap(NextendoLaunch.networkSetting(in: [setting]))
    }

    func testNetworkIsAnOrdinaryEngineChoice() throws {
        let setting = try networkSetting(online: true)
        let snapshot = GameSettingsSnapshot(settings: [setting], values: ["DM_NETWORK": "offline"], fixed: [])
        XCTAssertEqual(snapshot.extraSettings, [setting])
        XCTAssertEqual(GameSettingValues.stepped(setting, from: "ldn", by: 1), "nextendo")
        XCTAssertEqual(GameSettingValues.stepped(try networkSetting(online: false), from: "ldn", by: 1), "offline")
        XCTAssertNil(NextendoLaunch.networkSetting(in: []))
    }

    func testOnlySupportedOnlinePlayAddsClientIDWithoutReplacingNetworkChoice() async throws {
        let setting = try networkSetting(online: true)
        for (setting, mode) in [(setting, "offline"), (setting, "ldn"), (setting, "lan"),
                                (try networkSetting(online: false), "nextendo")] {
            let environment = try await NextendoLaunch.environment(setting: setting, mode: mode, clientID: nil) { _ in
                XCTFail("Offline, local and unsupported launches must not contact Nextendo")
                return false
            }
            XCTAssertEqual(environment, [:])
        }
        let online = try await NextendoLaunch.environment(setting: setting, mode: "nextendo", clientID: "sample-client") { client in
            XCTAssertEqual(client, "sample-client")
            return true
        }
        XCTAssertEqual(online, ["DM_NEXTENDO_CLIENT_ID": "sample-client"])
    }

    func testSignedOutOnlinePlayIsBlocked() async throws {
        let setting = try networkSetting(online: true)
        do {
            _ = try await NextendoLaunch.environment(setting: setting, mode: "nextendo", clientID: "sample-client") { _ in false }
            XCTFail("Missing session should block the supported online launch")
        } catch let error as NextendoError { XCTAssertEqual(error, .signedOut) }
    }

    func testEngineProbeRequiresBuildFlagAndActualSetting() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("NextendoEngine-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        let cli = repo.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        let table = repo.appendingPathComponent("dm/games/settings.tsv")
        for url in [cli, table] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        XCTAssertFalse(NextendoLaunch.engineSupportsSignIn(at: repo))
        try Data("ap.add_argument('--nextendo')\n".utf8).write(to: cli)
        try Data("# DM_NETWORK\tchoice\tnextendo=Nextendo\n".utf8).write(to: table)
        XCTAssertFalse(NextendoLaunch.engineSupportsSignIn(at: repo))
        try Data("DM_NETWORK\tchoice\toffline=Offline,nextendo=Nextendo?build:DM_NEXTENDO\r\n".utf8).write(to: table)
        XCTAssertTrue(NextendoLaunch.engineSupportsSignIn(at: repo))
    }

    func testSearchAndChangedDoNotSurfaceUnsupportedConnection() {
        var settings = AppSettings()
        settings.nextendoClientID = "sample-client"
        XCTAssertTrue(SettingsCatalog.search("Nextendo").isEmpty)
        XCTAssertTrue(SettingsCatalog.changed(in: settings).isEmpty)
        XCTAssertEqual(SettingsCatalog.search("Nextendo", supportsNextendo: true).map(\.id), ["nextendo", "nextendoClientID"])
        XCTAssertEqual(SettingsCatalog.changed(in: settings, supportsNextendo: true).map(\.id), ["nextendoClientID"])
    }
}
