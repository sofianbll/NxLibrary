import Foundation
import XCTest
@testable import NXLibraryCore

final class LocalProfileStoreTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    func testMigrationCreatesOneProfileWithExistingLookAndRetainsLastChoice() throws {
        try withDirectory { url in
            var settings = AppSettings()
            settings.colorThemeID = "arcane-flow"
            settings.wallpaperID = "Custom/One"
            settings.settingsWallpaperID = "Custom/Two"
            settings.spotlightOrder = ["card:activity"]
            let store = LocalProfileStore(directory: url, settings: settings, name: "Local")
            let first = try XCTUnwrap(store.active)
            XCTAssertEqual(first.look, .init(settings))
            XCTAssertEqual(store.originalID, first.id)
            XCTAssertFalse(store.remove(first.id))
            XCTAssertNil(first.appearsOnline)
            var other = LocalProfile(name: "  Jade ", avatar: 2, look: .init(AppSettings()))
            other.appearsOnline = false
            XCTAssertTrue(store.update(other))
            XCTAssertEqual(store.active?.id, first.id)
            let profileFile = url.appendingPathComponent("profiles.json")
            let existing = try Data(contentsOf: profileFile)
            XCTAssertTrue(store.choose(other.id))
            XCTAssertEqual(try Data(contentsOf: profileFile), existing)
            XCTAssertEqual(LocalProfileStore(directory: url, settings: .init(), name: "Other").active?.id, other.id)
            let game = UUID()
            XCTAssertTrue(store.toggleFavorite(game))
            let reopened = LocalProfileStore(directory: url, settings: .init(), name: "Do not reimport")
            XCTAssertEqual(reopened.active?.name, "Jade")
            XCTAssertEqual(reopened.active?.favorites, [game])
            XCTAssertEqual(reopened.active?.appearsOnline, false)
            XCTAssertTrue(reopened.remove(other.id))
            XCTAssertEqual(reopened.active, first)
        }
    }

    func testCorruptProfileFileIsNotReplaced() throws {
        try withDirectory { url in
            let file = url.appendingPathComponent("profiles.json")
            let original = Data("{not JSON".utf8)
            try original.write(to: file)
            let store = LocalProfileStore(directory: url, settings: .init(), name: "Local")
            XCTAssertTrue(store.failed)
            XCTAssertNil(store.active)
            XCTAssertFalse(store.update(LocalProfile(name: "Other", look: .init(.init()))))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testBackupIsCreatedOnceAndCanRestoreLegacyFiles() throws {
        try withDirectory { url in
            let settingsURL = url.appendingPathComponent("settings.json")
            let original = try JSONEncoder().encode(AppSettings())
            try original.write(to: settingsURL)
            let store = LocalProfileStore(directory: url, settings: .init(), name: "Original")
            XCTAssertNotNil(store.active)
            let backup = url.appendingPathComponent("profiles-migration-backup/settings.json")
            XCTAssertEqual(try Data(contentsOf: backup), original)
            let after = Data("new settings".utf8)
            try after.write(to: settingsURL)
            let again = LocalProfileStore(directory: url, settings: .init(), name: "Do not reimport")
            XCTAssertEqual(again.active, store.active)
            XCTAssertEqual(try Data(contentsOf: backup), original)
            try Data(contentsOf: backup).write(to: settingsURL, options: .atomic)
            XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        }
    }

    func testHistoryMigratesWithoutChangingLegacyAndKeepsLaunchOwner() throws {
        try withDirectory { url in
            let file = url.appendingPathComponent("play-sessions.json")
            let game = UUID(), second = UUID(), profile = UUID()
            var now = Date(timeIntervalSinceReferenceDate: 900)
            let old = PlaySessionStore(fileURL: file, now: { now })
            XCTAssertTrue(old.start(gameID: game, sourceID: "old"))
            now += 70
            old.end(gameID: game)
            let data = try Data(contentsOf: file)
            let store = PlaySessionStore(fileURL: file, now: { now })
            XCTAssertEqual(try Data(contentsOf: file), data)
            XCTAssertEqual(store.totalDuration(for: game), 70)
            store.expectStart(gameID: second)
            store.profileID = profile
            XCTAssertNil(store.lastPlayed(for: game))
            XCTAssertTrue(store.start(gameID: second, sourceID: "launch"))
            now += 40
            XCTAssertTrue(store.end(gameID: second).isEmpty)
            XCTAssertEqual(store.totalDuration(for: second), 0)
            XCTAssertTrue(store.start(gameID: game, sourceID: "scoped"))
            now += 20
            XCTAssertEqual(store.end(gameID: game).first?.profileID, profile)
            let reopened = PlaySessionStore(fileURL: file)
            XCTAssertEqual(reopened.totalDuration(for: second), 40)
            XCTAssertEqual(reopened.totalDuration(for: game), 70)
            reopened.profileID = profile
            XCTAssertEqual(reopened.totalDuration(for: game), 20)
        }
    }
}
