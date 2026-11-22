import XCTest
@testable import NXLibraryCore
@testable import ArcanePorting

final class LaunchServiceTests: XCTestCase {
    final class FakeLauncher: AppLaunching {
        var opened: URL?
        var environment: [String: String] = [:]
        var shouldSucceed = true
        func open(_ url: URL, environment: [String: String],
                  completion: @escaping (Bool, String?) -> Void) {
            opened = url
            self.environment = environment
            completion(shouldSucceed, shouldSucceed ? nil : "sample launch error")
        }
    }

    func testWritesEnvAndLaunches() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NXLaunch-\(UUID().uuidString)")
        let game = PortedGame(name: "G", url: URL(fileURLWithPath: "/tmp/G.app"),
                              platform: .macApp, sizeBytes: 1, modificationDate: Date(),
                              titleId: "0100000000010000")
        var settings = GameRuntimeConfig()
        settings.fpsTarget = 30
        settings.metalHUD = true
        let launcher = FakeLauncher()
        let service = LaunchService(launcher: launcher)
        try service.writeEnvironment(settings: settings, titleId: "0100000000010000", baseDirectory: dir)
        let env = try String(contentsOf: dir.appendingPathComponent("0100000000010000/env.txt"), encoding: .utf8)
        XCTAssertTrue(env.contains("DM_FPS_TARGET=30"))
        XCTAssertTrue(env.contains("DM_METAL_HUD=1"))
        var launched = false
        var launchError: String?
        service.launch(appURL: game.url, environment: ["DM_FPS_TARGET": "30"]) { success, error in
            launched = success
            launchError = error
        }
        XCTAssertTrue(launched)
        XCTAssertNil(launchError)
        XCTAssertEqual(launcher.opened, game.url)
        XCTAssertEqual(launcher.environment["DM_FPS_TARGET"], "30")
    }

    func testOverlayOnlySendsSupportedDataAndLeavesEnvFileAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NXOverlay-\(UUID())")
        let app = root.appendingPathComponent("Fixture.app")
        let host = HomeMenu.hostExecutable(in: app)
        try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        let service = LaunchService(launcher: launcher)
        let title = "0100000000000001"
        try service.writeEnvironment(settings: .init(), titleId: title, baseDirectory: root)
        let env = root.appendingPathComponent("\(title)/env.txt")
        let before = try Data(contentsOf: env)
        let cover = root.appendingPathComponent("Cover art.png")
        try Data().write(to: cover)
        let palette = SelenePalette.fallback
        XCTAssertEqual(GameOverlayLaunch(app: app).environment(palette: palette, playtime: 2599, cover: cover), [:])
        try Data("DM_OVERLAY_THEME_V10\0DM_OVERLAY_PLAYTIME_MIN\0".utf8).write(to: host)
        XCTAssertEqual(GameOverlayLaunch(app: app).environment(palette: palette, playtime: 2599, cover: cover),
                       ["DM_OVERLAY_PLAYTIME_MIN": "43"])
        try Data("DM_OVERLAY_THEME_V1\0DM_OVERLAY_PLAYTIME_MIN\0DM_OVERLAY_COVER\0".utf8).write(to: host)
        let overlay = GameOverlayLaunch(app: app)
        service.launch(appURL: app, environment: overlay.environment(palette: palette, playtime: 2599, cover: cover)) {
            ok, _ in XCTAssertTrue(ok)
        }
        XCTAssertEqual(launcher.environment["DM_OVERLAY_THEME_V1"],
                       "ink=#FFFFFFFF;surface=#14181FFF;scrim=#000000FF;focus=#FFFFFFFF;onFocus=#111111FF")
        XCTAssertEqual(launcher.environment["DM_OVERLAY_PLAYTIME_MIN"], "43")
        XCTAssertEqual(launcher.environment["DM_OVERLAY_COVER"], cover.path)
        XCTAssertEqual(try Data(contentsOf: env), before)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("DM_OVERLAY_"))
        XCTAssertEqual(overlay.environment(palette: palette, playtime: .infinity, cover: root).count, 1)
    }

    func testOverlayThemeRejectsUnreadableColors() {
        var palette = SelenePalette.fallback
        palette.ink = palette.glass
        XCTAssertNil(GameOverlayLaunch.theme(palette))
        palette = .fallback
        palette.onFocus = palette.focus
        XCTAssertNil(GameOverlayLaunch.theme(palette))
        palette = .fallback
        palette.focus = palette.glass
        palette.onFocus = palette.ink
        XCTAssertNil(GameOverlayLaunch.theme(palette))
    }

    func testLaunchFailureIsReported() throws {
        let launcher = FakeLauncher()
        launcher.shouldSucceed = false
        let service = LaunchService(launcher: launcher)
        var launched = true
        var launchError: String?
        service.launch(appURL: URL(fileURLWithPath: "/tmp/Missing.app")) { success, error in
            launched = success
            launchError = error
        }
        XCTAssertFalse(launched)
        XCTAssertEqual(launchError, "sample launch error")
    }

    func testUnreadableEnvironmentIsKeptInsteadOfReplacingUnknownOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NXLaunchUnreadable-\(UUID())")
        let title = "0100000000000001"
        let folder = root.appendingPathComponent(title)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = folder.appendingPathComponent("env.txt")
        let invalid = Data([0xff, 0xfe, 0xff])
        try invalid.write(to: env)
        let service = LaunchService(launcher: FakeLauncher())
        XCTAssertThrowsError(try service.writeEnvironment(settings: GameRuntimeConfig(), titleId: title, baseDirectory: root))
        XCTAssertEqual(try Data(contentsOf: env), invalid)
    }

    /// Arcane's Game options are the game's settings window: a game it starts skips the engine's own
    /// (dm/mac/launcher.c, DM_LAUNCHER=0), which would ask again and, on Quit, leave a process macOS never reports ended.
    func testLaunchSkipsTheEnginesSettingsWindow() {
        let launcher = FakeLauncher()
        LaunchService(launcher: launcher).launch(appURL: URL(fileURLWithPath: "/tmp/G.app"),
                                                 environment: ["DM_FPS_TARGET": "30", "DM_MODS_OFF": "Some mod"]
                                                    .merging(HomeMenu.environment(supported: true, launcherBundleID: "local.arcane")) { _, new in new }) { _, _ in }
        XCTAssertEqual(launcher.environment["DM_LAUNCHER"], "0")
        XCTAssertEqual(launcher.environment["DM_FPS_TARGET"], "30")
        XCTAssertEqual(launcher.environment["DM_MODS_OFF"], "Some mod")
        XCTAssertEqual(launcher.environment["DM_HOME_MENU_LAUNCHER"], "1")
        XCTAssertEqual(launcher.environment["DM_LAUNCHER_BUNDLE_ID"], "local.arcane")
    }

    func testEmptyCodeModsOverrideReachesTheEngineForReactivation() {
        let launcher = FakeLauncher()
        LaunchService(launcher: launcher).launch(appURL: URL(fileURLWithPath: "/tmp/G.app"),
                                                  environment: ["DM_MODS_OFF": ""]) { _, _ in }
        XCTAssertEqual(launcher.environment["DM_MODS_OFF"], "")
    }
}
