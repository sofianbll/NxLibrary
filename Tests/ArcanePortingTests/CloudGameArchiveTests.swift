import Darwin
import Foundation
import XCTest
@testable import NXLibraryCore
@testable import ArcanePorting

final class CloudGameArchiveTests: XCTestCase {
    private let title = "0100E65002BB8000"

    func testFirstSendPublishesBrowsableAppFiles() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let manifest = try await f.service.upload(f.game)
        XCTAssertEqual(manifest.version, 2)
        let paths = try await f.backend.list().map(\.key.value)
        XCTAssertTrue(paths.contains { $0.hasPrefix("Fixture [\(title)]/app/")
            && $0.hasSuffix("/Fixture.app/Contents/Info.plist") })
        XCTAssertFalse(paths.contains { $0.hasSuffix(".aar") })
        let tree = try XCTUnwrap(manifest.artifacts.first?.files)
        let downloaded = f.root.appendingPathComponent("Browser.app")
        try FileManager.default.copyItem(at: f.remote.appendingPathComponent(tree.folder), to: downloaded)
        let importer = ImportService()
        let plan = try importer.prepareAdoption(from: downloaded, into: f.root, existing: [])
        let staged = try importer.stageAdoption(plan, replacing: true)
        defer { importer.cleanupAdoption(staged, published: false) }
        XCTAssertEqual(staged.app.titleId, title)
    }

    func testIncrementalSendTransfersOnlyChangedFile() async throws {
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.service.upload(f.game)
        let log = f.root.appendingPathComponent("transfers")
        try Data().write(to: log)
        try Data("cache-edit".utf8).write(to: f.cache.appendingPathComponent("run.key"))
        let second = try await f.service.upload(f.game)
        XCTAssertEqual(first.artifacts.first, second.artifacts.first)
        let files = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(files.filter { $0.hasPrefix("upload:") }.map { $0.split(separator: "/").last! }, ["run.key"])
        XCTAssertEqual(files.filter { $0.hasPrefix("server:") }.count, 2)
        try await XCTUnwrap(first.artifacts.last?.files).verify(on: f.backend)
    }

    func testMovingLibraryIncludesFilesReferencedByVersionTwo() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let published = try await f.service.upload(f.game)
        let destination = f.root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let executable = try XCTUnwrap(RcloneStorageBackend.findExecutable())
        let drive = CloudDriveFolders(remote: ":local:", executable: executable, localRoot: f.root,
                                      config: f.root.appendingPathComponent("rclone.conf"))
        let plan = try await drive.movePlan(from: f.remote.lastPathComponent)
        XCTAssertEqual(plan.games, 1)
        let conflicts = try await drive.move(plan, to: destination.lastPathComponent) { _, _ in }
        XCTAssertEqual(conflicts, [])
        let moved = f.backend.atRoot(destination.path)
        let latest = try await CloudGameArchive(backend: moved).latest(titleID: title)
        XCTAssertEqual(latest, published)
        for artifact in published.artifacts { try await XCTUnwrap(artifact.files).verify(on: moved) }
    }

    func testInterruptedCacheRestorationKeepsVerifiedFilesForBuildAndResume() async throws {
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let manifest = try await f.service.upload(f.game)
        try FileManager.default.removeItem(at: f.cache)
        let log = f.root.appendingPathComponent("transfers")
        try Data().write(to: log)
        try Data().write(to: f.root.appendingPathComponent("interrupt"))
        do {
            try await f.service.restore(.cache, for: f.game, onlyIfMissing: true)
            XCTFail("The fixture interrupts after the first regular file")
        } catch { XCTAssertEqual(error as? StorageBackendError, .processFailed(status: 7)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.cache.appendingPathComponent("nested/one").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.cache.appendingPathComponent("run.key").path))
        let build = try await f.service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(build.decision, .allowed)
        XCTAssertEqual(build.verifiedCache?.resolvingSymlinksInPath(), f.cache.resolvingSymlinksInPath())
        let copies = try await f.service.copyStatuses(f.game, manifest: .success(manifest))
        XCTAssertEqual(copies[.cache]?.state, .cloudOnly)
        try await f.service.restore(.cache, for: f.game, onlyIfMissing: true)
        let files = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(files.filter { $0.hasSuffix("/nested/one") }.count, 1)
        XCTAssertEqual(try cacheContents(f.cache), "cache-data")
    }

    @MainActor func testCatalogCheckVisitsValidGamesInOrderAndStopsWhenCancelled() async {
        let titles = [title, "invalid", "0100000000000001", "0100000000000002"]
        var events: [String] = []
        let check = Task {
            await CloudGameArchive.checkCatalogAvailability(titles, titleID: { $0 }) { title in
                events.append("start \(title)")
                await Task.yield()
                events.append("end \(title)")
                if title == titles[2] { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await check.value
        XCTAssertEqual(events, ["start \(title)", "end \(title)", "start \(titles[2])", "end \(titles[2])"])
    }

    @MainActor func testCatalogCheckPropagatesOfflineAndCanRetry() async throws {
        let ids = [title, "0100000000000001"]
        let unavailable = CloudGameArchive(backend: RcloneStorageBackend(remote: "fixture", root: "Games") { _, _, _ in
            .init(status: 1, stdout: "", stderr: "dial tcp: network is unreachable")
        })
        var attempts: [String] = []
        do {
            try await CloudGameArchive.checkCatalogAvailability(ids, titleID: { $0 }) { id in
                attempts.append(id)
                _ = try await unavailable.availability(.init(titleID: id, locations: [:]))
            }
            XCTFail("The check cannot complete successfully while offline")
        } catch { XCTAssertEqual(error as? CloudLibraryFailure, .offline) }
        XCTAssertEqual(attempts, [title])
        let reachable = CloudGameArchive(backend: RcloneStorageBackend(remote: "fixture", root: "Games") { _, args, _ in
            if args.contains("--dirs-only") { return .init(status: 0, stdout: "[]", stderr: "") }
            if args.contains("--stat") { return .init(status: 0, stdout: #"{"IsDir":true}"#, stderr: "") }
            return .init(status: 3, stdout: "", stderr: "directory not found")
        })
        attempts.removeAll()
        try await CloudGameArchive.checkCatalogAvailability(ids, titleID: { $0 }) { id in
            let result = try await reachable.availability(.init(titleID: id, locations: [:]))
            XCTAssertEqual(result[.app]?.state, .notInCloud)
            attempts.append(id)
        }
        XCTAssertEqual(attempts, ids)
    }

    func testCopyPreservesQuotaFailureFromSyntheticBackend() async throws {
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Data().write(to: f.root.appendingPathComponent("quota"))
        do {
            _ = try await f.service.upload(f.game)
            XCTFail("Synthetic copy should fail")
        } catch { XCTAssertEqual(error as? CloudLibraryFailure, .quotaFull) }
    }

    func testAvailabilityDoesNotReadArtifactContents() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = f.service
        let manifest = try await archive.upload(f.game)
        // The recursive inventory rejects a protected file. Presence doesn't inspect any children.
        try Data().write(to: f.cache.appendingPathComponent("prod.keys"))
        try FileManager.default.removeItem(at: f.app)
        let availability = try await archive.availability(f.game)
        XCTAssertEqual(availability[.app]?.state, .cloudOnly)
        XCTAssertEqual(availability[.cache]?.state, .unknown)
        XCTAssertEqual(availability[.cache]?.hasLocalCopy, true)
        XCTAssertEqual(availability[.cache]?.uploadedAt, manifest.createdAt)
    }

    func testCopyStatusUsesTheManifestInventoryAndDetectsSameSizeEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Synthetic.app")
        let cache = root.appendingPathComponent("\(title)_build")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let file = cache.appendingPathComponent("build")
        try Data("original".utf8).write(to: file)
        let inventory = try CloudArchiveInventory.scan(cache, kind: .cache)
        let artifact = CloudGameManifest.Artifact(kind: .cache, size: 40, sha256: "", md5: "",
            unpackedSize: inventory.bytes, entryCount: inventory.entries.count, inventorySHA256: inventory.sha256,
            engineCommit: nil, shaderChain: nil, options: [:])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = CloudGameManifest(version: 1, titleID: title, createdAt: date, artifacts: [artifact])
        let game = CloudArchiveGame(titleID: title, locations: [.app: app, .cache: cache])
        let backend = RcloneStorageBackend(remote: ":local:", root: "/unused")
        let cacheFile = root.appendingPathComponent("fingerprints.json")
        let fingerprints = CloudArchiveFingerprintCache(file: cacheFile)
        let service = CloudGameArchive(backend: backend, trash: { _ in }, fingerprints: fingerprints)

        let original = try await service.copyStatuses(game, manifest: .success(manifest))
        XCTAssertEqual(original[.app]?.state, .notInCloud)
        XCTAssertEqual(original[.cache]?.state, .synchronized)
        XCTAssertEqual(original[.cache]?.bytes, 8)
        XCTAssertEqual(original[.cache]?.uploadedAt, date)
        XCTAssertTrue(CloudArtifactStatus.needsUpload(original), "The app has no cloud copy")
        XCTAssertTrue(CloudArtifactStatus.needsUpload([.app: original[.cache]!, .cache: original[.cache]!]),
                      "Synchronized legacy archives can be migrated")

        let key = CloudArchiveInventory.fingerprintKey(cache.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(cache.lastPathComponent), kind: .cache)
        let onDisk = try Data(contentsOf: cacheFile)
        XCTAssertFalse(String(decoding: onDisk, as: UTF8.self).contains(root.lastPathComponent))
        let reopened = CloudArchiveFingerprintCache(file: cacheFile)
        let saved = await reopened.entries()[key]
        XCTAssertEqual(saved?.sha256, inventory.sha256)

        let old = try CloudArchiveInventory.node(at: file).st_mtimespec
        try Data("modified".utf8).write(to: file)
        var stamps = [old, old]
        XCTAssertEqual(utimensat(AT_FDCWD, file.path, &stamps, 0), 0)
        let restarted = CloudGameArchive(backend: backend, trash: { _ in }, fingerprints: reopened)
        let changed = try await restarted.copyStatuses(game, manifest: .success(manifest))
        XCTAssertEqual(changed[.cache]?.state, .newerOnThisMac)
        XCTAssertEqual(changed[.cache]?.bytes, 8)
        XCTAssertFalse(CloudArtifactStatus.canUploadAlone(.cache, statuses: changed))
        let updated = await reopened.entries()[key]
        XCTAssertNotEqual(updated?.signature, saved?.signature)
        XCTAssertNotEqual(updated?.sha256, saved?.sha256)

        try Data("invalid JSON".utf8).write(to: cacheFile, options: .atomic)
        let corrupt = await CloudArchiveFingerprintCache(file: cacheFile).entries()
        XCTAssertTrue(corrupt.isEmpty)

        try FileManager.default.removeItem(at: cache)
        let missing = try await service.copyStatuses(game, manifest: .success(manifest))
        XCTAssertEqual(missing[.cache]?.state, .cloudOnly)
        XCTAssertEqual(missing[.cache]?.bytes, 8)
        XCTAssertFalse(CloudArtifactStatus.needsUpload(missing))
        let unavailable = CloudArchiveGame(titleID: title, locations: [.app: app])
        let unknown = try await service.copyStatuses(unavailable, manifest: .success(manifest))
        XCTAssertEqual(unknown[.cache]?.state, .unknown)
        let unreadable = try await service.copyStatuses(game, manifest: .failure(CloudArchiveError.invalidManifest))
        XCTAssertEqual(unreadable[.app]?.state, .unknown)
        XCTAssertEqual(unreadable[.cache]?.state, .unknown)
        XCTAssertFalse(CloudArtifactStatus.needsUpload(unreadable))

        let noManifest = try await service.copyStatuses(game, manifest: .success(nil))
        XCTAssertEqual(noManifest[.app]?.state, .notInCloud)
        XCTAssertEqual(noManifest[.cache]?.state, .notInCloud)
        XCTAssertNil(noManifest[.app]?.uploadedAt)
        XCTAssertFalse(CloudArtifactStatus.needsUpload(noManifest))

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.copyStatuses(game, manifest: .success(manifest))
        }
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled comparison must not publish a result")
        } catch is CancellationError {}
    }

    func testFingerprintCacheEvictsOldestEntry() async {
        let cache = CloudArchiveFingerprintCache()
        let fingerprint = CloudArchiveFingerprintCache.Fingerprint(signature: "signature", sha256: "hash", withoutRootMtime: nil)
        await cache.save(["old": fingerprint])
        await cache.save(Dictionary(uniqueKeysWithValues: (1...500).map { (String($0), fingerprint) }))
        let entries = await cache.entries()
        XCTAssertEqual(entries.count, 500)
        XCTAssertNil(entries["old"])
    }

    func testAppOnlyFirstUploadRestoresAndRequiresAFullRebuild() async throws {
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let missingRoot = CloudGameArchive(backend: f.backend.atRoot(f.remote.appendingPathComponent("missing").path))
        do {
            _ = try await missingRoot.upload(f.game, kinds: [.app])
            XCTFail("An absent root must not look like a title that has never been uploaded")
        } catch { XCTAssertEqual(error as? CloudLibraryFailure, .folderMissing) }
        do {
            _ = try await service.upload(f.game, kinds: [.app])
            XCTFail("A first send must include the local cache when one exists")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .needsFullUpload) }
        try FileManager.default.removeItem(at: f.cache)
        let appOnly = CloudArchiveGame(titleID: title, locations: [.app: f.app])
        let before = try await service.copyStatuses(appOnly, manifest: .success(nil))
        XCTAssertTrue(CloudArtifactStatus.canUploadAlone(.app, statuses: before))
        XCTAssertFalse(CloudArtifactStatus.canUploadAlone(.cache, statuses: before))
        let unavailableCache = CloudArchiveGame(titleID: title, locations: [.app: f.app], cacheIsRegistered: true)
        let unavailable = try await service.copyStatuses(unavailableCache, manifest: .success(nil))
        XCTAssertFalse(CloudArtifactStatus.canUploadAlone(.app, statuses: unavailable))

        let uploaded = try await service.upload(appOnly, kinds: [.app])
        XCTAssertEqual(uploaded.artifacts.map(\.kind), [.app])
        let manifests = try await service.latestManifests()
        XCTAssertEqual(manifests, [uploaded])
        let check = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(check.decision, .fullRebuild)
        XCTAssertNil(check.verifiedCache)

        try FileManager.default.removeItem(at: f.app)
        _ = try await service.restore(.app, for: appOnly, onlyIfMissing: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.cache.path))
        let restored = try await service.copyStatuses(appOnly, manifest: .success(uploaded))
        XCTAssertEqual(restored[.app]?.state, .synchronized)
        try Data("new".utf8).write(to: f.app.appendingPathComponent("Contents/Resources/new"))
        try command("/usr/bin/codesign", ["--force", "--sign", "-", f.app.path])
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: false)
        try Data("cache".utf8).write(to: f.cache.appendingPathComponent("cache"))
        let diverged = try await service.copyStatuses(f.game, manifest: .success(uploaded))
        XCTAssertEqual(diverged[.app]?.state, .newerOnThisMac)
        XCTAssertTrue(CloudArtifactStatus.canUploadAlone(.app, statuses: diverged))
        XCTAssertFalse(CloudArtifactStatus.canUploadAlone(.cache, statuses: diverged))
        let update = try await service.upload(f.game, kinds: [.app])
        XCTAssertEqual(update.artifacts.map(\.kind), [.app])
        XCTAssertNotEqual(update.artifacts, uploaded.artifacts)
        let updatedCopies = try await service.copyStatuses(f.game, manifest: .success(update))
        XCTAssertTrue(CloudArtifactStatus.canUploadAlone(.cache, statuses: updatedCopies))
        let withCache = try await service.upload(f.game, kinds: [.cache])
        XCTAssertEqual(withCache.artifacts.map(\.kind), [.app, .cache])
        XCTAssertEqual(withCache.artifacts.first, update.artifacts.first)
        let verified = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(verified.decision, .allowed)
        XCTAssertEqual(verified.verifiedCache?.path, f.cache.resolvingSymlinksInPath().path)
    }

    func testPartialUploadPreservesRemoteAppWithoutReadingLocalApp() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let cacheOnly = CloudArchiveGame(titleID: title, locations: [.cache: f.cache])
        do {
            _ = try await service.upload(cacheOnly, kinds: [.cache])
            XCTFail("The first upload must include both artifacts")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .needsFullUpload) }

        let original = try await service.upload(f.game)
        try FileManager.default.removeItem(at: f.app)
        let cacheFile = f.cache.appendingPathComponent("run.key")
        try Data("updated cache".utf8).write(to: cacheFile)
        let statuses = try await service.copyStatuses(f.game, manifest: .success(original))
        XCTAssertEqual(statuses[.app]?.state, .cloudOnly)
        XCTAssertTrue(CloudArtifactStatus.canUploadAlone(.cache, statuses: statuses))
        XCTAssertFalse(CloudArtifactStatus.canUploadAlone(.app, statuses: statuses))
        let progress = ProgressRecorder()
        let updated = try await service.upload(cacheOnly, kinds: [.cache]) { progress.record($0) }
        XCTAssertFalse(progress.snapshot().contains { $0.kind == .app && $0.phase != .verifying })
        XCTAssertEqual(updated.artifacts.map(\.kind), [.app, .cache])
        XCTAssertEqual(updated.artifacts[0], original.artifacts[0])
        XCTAssertEqual(updated.gameName, original.gameName)
        XCTAssertEqual(updated.bundleName, original.bundleName)
        XCTAssertNotEqual(updated.artifacts[1], original.artifacts[1])
        let latest = try await service.latest(titleID: title)
        XCTAssertEqual(latest, updated)

        try await f.backend.delete(try XCTUnwrap(updated.artifacts[0].objects(titleID: title).first).key)
        let objects = try await f.backend.list().map(\.key.value).sorted()
        do {
            _ = try await service.upload(cacheOnly, kinds: [.cache])
            XCTFail("A missing retained object must prevent publication")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .needsFullUpload) }
        let after = try await f.backend.list().map(\.key.value).sorted()
        XCTAssertEqual(after, objects)
    }

    func testDiscoversAndRestoresAnArchivedAppWithoutSources() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let missingRoot = CloudGameArchive(backend: f.backend.atRoot(f.remote.appendingPathComponent("missing").path))
        do {
            _ = try await missingRoot.latestManifests()
            XCTFail("An unavailable root must not be reported as an empty library")
        } catch { XCTAssertEqual(error as? CloudLibraryFailure, .folderMissing) }
        let other = f.remote.appendingPathComponent("0100000000000001")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let empty = try await service.latestManifests()
        XCTAssertTrue(empty.isEmpty, "A title folder alone is not an archived game")

        let published = try await publishLegacy(f)
        XCTAssertEqual(published.gameName, "Fixture")
        XCTAssertEqual(published.bundleName, "Fixture.app")
        XCTAssertEqual(published.gameVersion, "1.2")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(published)) as? [String: Any])
        json.removeValue(forKey: "game_name")
        json.removeValue(forKey: "bundle_name")
        let oldFile = f.root.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: json).write(to: oldFile)
        let digest = try XCTUnwrap(CloudArchiveInventory.hashes(at: oldFile)["sha256"])
        let manifests = f.remote.appendingPathComponent("\(title)/manifests")
        try FileManager.default.moveItem(at: oldFile, to: manifests.appendingPathComponent("9999999999999999-\(digest).json"))
        let found = try await service.latestManifests()
        let legacy = try XCTUnwrap(found.first)
        XCTAssertEqual(found.map(\.titleID), [title])
        XCTAssertNil(legacy.gameName)
        XCTAssertNil(legacy.bundleName)
        XCTAssertEqual(legacy.gameVersion, "1.2")

        let apps = f.root.appendingPathComponent("Game apps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: false)
        let repository = CatalogRepository(store: CatalogStore(directory: f.root))
        let catalog = try repository.importCloudGames(found, in: apps)
        let game = try XCTUnwrap(catalog.nxnativeGames.first)
        XCTAssertEqual(game.name, title)
        XCTAssertEqual(game.url.deletingLastPathComponent().path, apps.path)
        XCTAssertEqual(game.status, .appMissing)
        XCTAssertFalse(game.isPlayableLocally)
        XCTAssertFalse(GameResourceState.sourcesAvailable(for: game))
        XCTAssertEqual(GameResourceState.unavailableReason(for: game), .sourcesMissing)
        XCTAssertNil(game.workspacePath)
        XCTAssertTrue(CatalogGamePresentation(game: catalog.games[0], sourceEnabled: catalog.source(.nxnative)?.isEnabled == true).isListedNormally)
        let chosen = f.root.appendingPathComponent("Different Game apps")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        let occupied = chosen.appendingPathComponent("\(title).app")
        try Data("Existing content".utf8).write(to: occupied)
        let destination = GameAppDestination.url(name: game.url.deletingPathExtension().lastPathComponent,
                                                 titleId: title, in: chosen, reusingExisting: false)
        XCTAssertEqual(destination.deletingLastPathComponent().path, chosen.path)
        XCTAssertNotEqual(destination.path, occupied.path)
        let target = CloudArchiveGame(titleID: title, locations: [.app: destination])
        let copies = try await service.copyStatuses(target, manifest: .success(legacy))
        XCTAssertEqual(copies[.app]?.state, .cloudOnly)
        try await service.restore(.app, for: target, onlyIfMissing: true)
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path])
        let restored = try repository.recordCloudAppRestore(id: game.id, at: destination)
        let playable = try XCTUnwrap(restored.nxnativeGames.first)
        XCTAssertEqual(playable.id, game.id)
        XCTAssertEqual(playable.status, .builtSourcesMissing)
        XCTAssertEqual(playable.versionString, "1.2")
        XCTAssertTrue(playable.isPlayableLocally)
        XCTAssertEqual(CatalogGamePresentation(game: restored.games[0], sourceEnabled: true).launchTarget,
                       .nxnative(appURL: destination))
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "Existing content")

        try Data().write(to: manifests.appendingPathComponent("zz-invalid.json"))
        do {
            _ = try await service.latestManifests()
            XCTFail("Unreadable manifests must not be reported as an empty library")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .invalidManifest) }
    }

    func testFirstFileUploadKeepsLegacyObjectsAndCanRetainLegacyCache() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let legacy = try await publishLegacy(f)
        let synchronized = try await f.service.copyStatuses(f.game, manifest: .success(legacy))
        XCTAssertEqual(synchronized[.app]?.state, .synchronized)
        XCTAssertTrue(CloudArtifactStatus.canUploadAlone(.app, statuses: synchronized))
        XCTAssertTrue(CloudArtifactStatus.canUploadAlone(.cache, statuses: synchronized))
        let modern = try await f.service.upload(f.game, kinds: [.app])
        XCTAssertEqual(modern.artifacts.last, legacy.artifacts.last)
        let mixed = try await f.service.copyStatuses(f.game, manifest: .success(modern))
        XCTAssertFalse(CloudArtifactStatus.canUploadAlone(.app, statuses: mixed))
        XCTAssertTrue(CloudArtifactStatus.canUploadAlone(.cache, statuses: mixed))
        let migrated = try await f.service.upload(f.game, kinds: [.cache])
        XCTAssertEqual(migrated.artifacts.first, modern.artifacts.first)
        XCTAssertTrue(migrated.artifacts.allSatisfy { $0.files != nil })
        for object in legacy.artifacts.flatMap({ $0.objects(titleID: title) }) {
            try await f.backend.verify(object)
        }
        try FileManager.default.removeItem(at: f.cache)
        try await f.service.restore(.cache, for: f.game, onlyIfMissing: true)
        let cached = f.cache.appendingPathComponent("run.key")
        let stamp = try fileStamp(cached)
        XCTAssertEqual(stamp.0, 1_700_000_000)
        XCTAssertEqual(stamp.1, 123_456_789)
        XCTAssertEqual(stamp.2, 0o640)
        XCTAssertEqual(try SaveFiles.attributes(cached)["org.arcane.test"], Data([42]))
    }

    func testRebuildDecisionRequiresSourcesAndVerifiedRemoteCacheUnlessExplicitlyOverridden() {
        func decision(_ sources: Bool = true, _ remote: Bool = true, _ verified: Bool = false,
                      _ override: Bool = false) -> CloudRebuildDecision {
            .decide(sourcesAvailable: sources, remoteCache: remote, localVerified: verified, withoutCache: override)
        }
        XCTAssertEqual(decision(), .downloadCache, "Remote-only or mismatching cache")
        XCTAssertEqual(decision(true, true, true), .allowed, "Verified local cache")
        XCTAssertEqual(decision(true, false), .allowed, "No remote manifest")
        XCTAssertEqual(decision(false), .missingSources)
        XCTAssertEqual(decision(true, true, false, true), .allowed)
        XCTAssertEqual(decision(false, true, false, true), .missingSources, "Override does not waive sources")
    }

    func testBuildLeaseExcludesCloudMutationsForTheSameTitle() async throws {
        let service = CloudGameArchive(backend: RcloneStorageBackend(remote: ":local:", root: "/unused"))
        let game = CloudArchiveGame(titleID: title, locations: [:])
        let token = try await service.beginBuild(titleID: title.lowercased())
        await service.endBuild(titleID: title, token: UUID())
        let otherTitle = "0100000000000000"
        let other = try await service.beginBuild(titleID: otherTitle)
        await service.endBuild(titleID: otherTitle, token: other)
        let operations: [() async throws -> Void] = [
            { _ = try await service.upload(game) },
            { try await service.free(.cache, for: game, confirmed: true) },
            { try await service.restore(.cache, for: game) }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("Cloud mutation took an active build's lease") }
            catch { XCTAssertEqual(error as? CloudArchiveError, .busy) }
        }
        await service.endBuild(titleID: title, token: token)
        do { try await service.restore(.cache, for: game); XCTFail("Fixture has no destination") }
        catch { XCTAssertEqual(error as? CloudArchiveError, .localMissing) }
        let next = try await service.beginBuild(titleID: title)
        await service.endBuild(titleID: title, token: next)
    }

    func testSignedAppAndCacheRoundTripThroughLocalRclone() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service
        let before = try await service.checkRebuild(fixture.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(before.decision, .allowed)
        let updates = ProgressRecorder()
        let manifest = try await service.upload(fixture.game, progress: { updates.record($0) })
        let phases = updates.snapshot()
        XCTAssertTrue(phases.contains { $0.phase == .preparing && $0.kind == .app })
        XCTAssertTrue(phases.contains { $0.phase == .uploading && $0.kind == .app && $0.transfer?.bytesTransferred == 0 })
        XCTAssertTrue(phases.contains { $0.phase == .verifying && $0.kind == .cache })
        XCTAssertEqual(manifest.artifacts.map(\.kind), [.app, .cache])
        XCTAssertEqual(manifest.artifacts.first?.engineCommit, "72d43ff6")
        XCTAssertEqual(manifest.artifacts.first?.shaderChain, "1234567890ab")
        let latest = try await service.latest(titleID: title)
        XCTAssertEqual(latest, manifest)
        let copies = try await service.copyStatuses(fixture.game, manifest: .success(latest))
        XCTAssertEqual(copies[.app]?.state, .synchronized)
        XCTAssertEqual(copies[.cache]?.state, .synchronized)
        XCTAssertFalse(CloudArtifactStatus.needsUpload(copies))
        for artifact in manifest.artifacts { try await XCTUnwrap(artifact.files).verify(on: fixture.backend) }

        do {
            try await service.free(.app, for: fixture.game, confirmed: false)
            XCTFail("Free requires explicit confirmation")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .confirmationRequired) }

        for kind in CloudArtifactKind.allCases {
            try await service.free(kind, for: fixture.game, confirmed: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.game.locations[kind]!.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent(kind.rawValue).path))
            if kind == .cache {
                let missing = try await service.checkRebuild(fixture.game, sourcesAvailable: true, withoutCache: false)
                XCTAssertEqual(missing.decision, .downloadCache)
            }
            _ = try await service.restore(kind, for: fixture.game, progress: { updates.record($0) })
            XCTAssertTrue(updates.snapshot().contains { $0.phase == .downloading && $0.kind == kind && $0.transfer != nil })
            XCTAssertTrue(updates.snapshot().contains { $0.phase == .restoring && $0.kind == kind })
        }
        let restored = try await service.checkRebuild(fixture.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(restored.decision, .allowed)
        XCTAssertEqual(restored.verifiedCache?.resolvingSymlinksInPath(), fixture.cache.resolvingSymlinksInPath())
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", fixture.app.path])
        XCTAssertEqual(try String(contentsOf: fixture.cache.appendingPathComponent("run.key"), encoding: .utf8), "cache-data")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.cache.appendingPathComponent("nested/link").path), "../run.key")
        let executable = try fileStamp(fixture.app.appendingPathComponent("Contents/MacOS/Fixture"))
        XCTAssertNotEqual(executable.2 & 0o100, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.app.appendingPathComponent("Contents/Resources/empty")), Data())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.app.appendingPathComponent("Contents/Resources/link").path), "empty")
    }

    func testCorruptRemoteObjectDoesNotRestoreOrPermitFree() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let manifest = try await service.upload(f.game)
        let object = try XCTUnwrap(manifest.artifacts.first { $0.kind == .cache }?.objects(titleID: title)
            .first { $0.key.value.hasSuffix("/run.key") })
        let file = f.remote.appendingPathComponent(object.key.value)
        var data = try Data(contentsOf: file)
        data[data.startIndex] ^= 1
        try data.write(to: file)
        do {
            try await service.free(.cache, for: f.game, confirmed: true)
            XCTFail("A corrupt remote copy cannot authorize Trash")
        } catch { XCTAssertEqual(error as? StorageBackendError, .hashMismatch) }
        do {
            try await service.restore(.cache, for: f.game)
            XCTFail("A corrupt download cannot be installed")
        } catch { XCTAssertEqual(error as? StorageBackendError, .hashMismatch) }
        XCTAssertEqual(try cacheContents(f.cache), "cache-data")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.trash.path), [])
    }

    func testUploadRefusesAnAppThatChangesAfterItsSnapshotAndNamesTheEntry() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let path = "Contents/_CodeSignature/CodeResources"
        let file = f.app.appendingPathComponent(path)
        let changed = Data(repeating: 42, count: try Data(contentsOf: file).count + 1)
        let service = f.service
        do {
            _ = try await service.upload(f.game) { progress in
                // The app was already scanned when the cache scan starts.
                if progress.phase == .preparing, progress.kind == .cache {
                    do { try changed.write(to: file) }
                    catch { XCTFail("Could not mutate the fixture: \(error)") }
                }
            }
            XCTFail("A changed app must not be published")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(path), error.localizedDescription)
            let mismatch = error as? CloudArchiveError
            XCTAssertEqual(mismatch, .uploadMismatch(.app, path: path, reason: .size))
            XCTAssertEqual(mismatch?.diagnosticDetail, "Cloud upload: app \"Contents/_CodeSignature/CodeResources\" — size")
        }
        let remote = try await f.backend.list()
        XCTAssertEqual(remote, [])
        try assertNoStagedArchive(f)
    }

    func testResendDoesNotReplaceManifestWhenCachePermissionsChange() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let before = try await service.upload(f.game)
        let file = f.cache.appendingPathComponent("run.key")
        do {
            _ = try await service.upload(f.game) { progress in
                if progress.phase == .verifying, progress.kind == .app {
                    XCTAssertEqual(chmod(file.path, 0o600), 0)
                }
            }
            XCTFail("A changed cache must not be published")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("run.key"), error.localizedDescription)
            let mismatch = error as? CloudArchiveError
            XCTAssertEqual(mismatch, .uploadMismatch(.cache, path: "run.key", reason: .permissions))
        }
        let latest = try await service.latest(titleID: title)
        XCTAssertEqual(latest, before)
        try assertNoStagedArchive(f)
    }

    func testSameSizeMutationBeforeCacheTransferDoesNotPublishManifest() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try addLargeCacheFile(to: f)
        let file = f.cache.appendingPathComponent("run.key")
        let mutated = ProgressRecorder()
        do {
            _ = try await f.service.upload(f.game) { progress in
                guard progress.phase == .uploading, progress.kind == .cache,
                      mutated.snapshot().isEmpty else { return }
                mutated.record(progress)
                do { try Data("cache-edit".utf8).write(to: file) }
                catch { XCTFail("Could not mutate the fixture: \(error)") }
            }
            XCTFail("A same-size edit during an upload must not be published")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .localChanged) }
        XCTAssertFalse(mutated.snapshot().isEmpty)
        let objects = try await f.backend.list()
        XCTAssertFalse(objects.contains { $0.key.value.hasSuffix(".json") })
        try assertNoStagedArchive(f)
    }

    func testInterruptedSendRetainsReceivedFilesAndResumes() async throws {
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Data().write(to: f.root.appendingPathComponent("interrupt"))
        do {
            _ = try await f.service.upload(f.game)
            XCTFail("An interrupted upload must not publish")
        } catch { XCTAssertEqual(error as? StorageBackendError, .processFailed(status: 7)) }
        let objects = try await f.backend.list()
        let partial = try XCTUnwrap(objects.first)
        XCTAssertEqual(objects.count, 1)
        let file = f.remote.appendingPathComponent(partial.key.value)
        let inode = try CloudArchiveInventory.node(at: file).st_ino
        let resumed = try await f.service.upload(f.game)
        XCTAssertEqual(resumed.version, 2)
        XCTAssertEqual(try CloudArchiveInventory.node(at: file).st_ino, inode)
        let received = try String(contentsOf: f.root.appendingPathComponent("transfers"), encoding: .utf8)
        XCTAssertEqual(received.components(separatedBy: "\n").filter { $0 == "upload:\(partial.key.value)" }.count, 1)
        let lease = try await f.service.beginBuild(titleID: title)
        await f.service.endBuild(titleID: title, token: lease)
    }

    func testExistingVersionIsReusedWithoutReplacingIt() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.service.upload(f.game)
        let url = f.remote.appendingPathComponent(try XCTUnwrap(first.artifacts[0].objects(titleID: title).first).key.value)
        let inode = try CloudArchiveInventory.node(at: url).st_ino
        let again = try await f.service.upload(f.game, kinds: [.app])
        XCTAssertEqual(again.artifacts, first.artifacts)
        XCTAssertEqual(try CloudArchiveInventory.node(at: url).st_ino, inode)
        try assertNoStagedArchive(f)
    }

    func testUploadDoesNotStageAnArchiveAndRestoreStillChecksSpace() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = CloudGameArchive(backend: f.backend, capacity: { _ in 0 }, trash: { _ in })
        _ = try await service.upload(f.game) { progress in
            guard progress.phase == .uploading || progress.phase == .verifying else { return }
            let local = try? FileManager.default.contentsOfDirectory(atPath: f.root.path)
            XCTAssertFalse(local?.contains { $0.hasPrefix(".arcane-cloud-") } ?? true)
            let fm = FileManager.default
            let stages = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
            for stage in stages where stage.lastPathComponent.hasPrefix(".arcane-cloud-") {
                XCTAssertFalse(fm.fileExists(atPath: stage.appendingPathComponent("item.aar").path))
            }
        }
        do {
            try await service.restore(.cache, for: f.game)
            XCTFail("Must refuse staging archive and extraction without space")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .insufficientSpace) }
        XCTAssertEqual(try cacheContents(f.cache), "cache-data")
    }

    private func addLargeCacheFile(to fixture: Fixture) throws {
        var bytes = Data(count: 12 << 20)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: fixture.cache.appendingPathComponent("large.bin"))
    }

    private func publishLegacy(_ f: Fixture) async throws -> CloudGameManifest {
        var artifacts: [CloudGameManifest.Artifact] = []
        for kind in CloudArtifactKind.allCases {
            let source = try XCTUnwrap(f.game.locations[kind])
            let archive = f.root.appendingPathComponent(kind.rawValue + ".aar")
            try command("/usr/bin/aa", ["archive", "-d", source.path, "-o", archive.path,
                "-a", "lzfse", "-t", "2", "-x", "-include-field", "siz"] + CloudArchiveInventory.archiveExclusions(kind))
            let snapshot = try CloudArchiveInventory.scan(source, kind: kind)
            let hashes = try CloudArchiveInventory.hashes(at: archive)
            let artifact = CloudGameManifest.Artifact(kind: kind, size: try CloudArchiveInventory.node(at: archive).st_size,
                sha256: hashes["sha256"]!, md5: hashes["md5"]!, unpackedSize: snapshot.bytes,
                entryCount: snapshot.entries.count, inventorySHA256: snapshot.sha256, engineCommit: nil,
                shaderChain: nil, options: ["CFBundleShortVersionString": "1.2"])
            try await f.backend.put(archive, as: XCTUnwrap(artifact.legacyObject(titleID: title)), progress: nil)
            artifacts.append(artifact)
        }
        let manifest = CloudGameManifest(version: 1, titleID: title, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                          artifacts: artifacts, gameName: "Fixture", bundleName: "Fixture.app")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = f.root.appendingPathComponent("old-manifest")
        let data = try encoder.encode(manifest)
        try data.write(to: file)
        let hashes = try CloudArchiveInventory.hashes(at: file)
        let key = StorageObjectKey("\(title)/manifests/0001700000000000-\(hashes["sha256"]!).json")
        try await f.backend.put(file, as: .init(key: key, size: Int64(data.count), hashes: hashes), progress: nil)
        return manifest
    }

    private func assertNoStagedArchive(_ fixture: Fixture) throws {
        let directory = fixture.remote.appendingPathComponent(".arcane-upload")
        if FileManager.default.fileExists(atPath: directory.path) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testRebuildLatencyProbe() async throws {
        guard ProcessInfo.processInfo.environment["ARCANE_REBUILD_PROBE"] == "1" else { return }
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let manifest = try await service.upload(f.game)
        let file = f.cache.appendingPathComponent("large.bin")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 16_000_000_000)
        try handle.close()
        let start = manifest.createdAt.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(30)], ofItemAtPath: file.path)
        for _ in 0..<3 {
            let clock = ContinuousClock()
            let t = clock.now
            let check = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false,
                                                       lastSuccessfulBuild: start...start.addingTimeInterval(60))
            print("rebuild fixture: \(t.duration(to: clock.now))")
            XCTAssertEqual(check.decision, .allowed)
        }
    }

    func testRebuildKeepsNewerLocalCache() async throws {
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let fingerprints = CloudArchiveFingerprintCache()
        let service = CloudGameArchive(backend: f.backend, trash: { _ in }, fingerprints: fingerprints)
        let manifest = try await service.upload(f.game)
        let file = f.cache.appendingPathComponent("run.key")
        try Data("different local cache".utf8).write(to: file)
        let start = manifest.createdAt.addingTimeInterval(60)
        let end = start.addingTimeInterval(60)
        let build = start...end
        try FileManager.default.setAttributes([.modificationDate: manifest.createdAt.addingTimeInterval(-60)], ofItemAtPath: file.path)
        let older = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false, lastSuccessfulBuild: build)
        XCTAssertEqual(older.decision, .downloadCache)
        XCTAssertNil(older.verifiedCache)
        XCTAssertTrue(older.hasUsableLocalCache)
        let explicit = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false, preferLocalCache: true)
        XCTAssertEqual(explicit.decision, .allowed)
        XCTAssertEqual(explicit.verifiedCache, f.cache)

        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(30)], ofItemAtPath: file.path)
        let before = await fingerprints.entries().mapValues(\.signature)
        let newer = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false, lastSuccessfulBuild: build)
        let after = await fingerprints.entries().mapValues(\.signature)
        XCTAssertEqual(newer.decision, .allowed)
        XCTAssertEqual(newer.verifiedCache, f.cache)
        XCTAssertEqual(before, after, "A recent cache does not need a new content fingerprint")

        try Data().write(to: f.cache.appendingPathComponent("prod.keys"))
        let excluded = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false,
                                                      lastSuccessfulBuild: build, preferLocalCache: true)
        XCTAssertEqual(excluded.decision, .downloadCache)
        XCTAssertFalse(excluded.hasUsableLocalCache)

        try FileManager.default.removeItem(at: f.cache)
        let missing = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false, lastSuccessfulBuild: build)
        XCTAssertEqual(missing.decision, .downloadCache)
        XCTAssertFalse(missing.hasUsableLocalCache)
    }

    func testRebuildReusesOnlyCurrentFingerprints() async throws {
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let fingerprints = CloudArchiveFingerprintCache()
        let service = CloudGameArchive(backend: f.backend, trash: { _ in }, fingerprints: fingerprints)
        let manifest = try await service.upload(f.game)
        let key = CloudArchiveInventory.fingerprintKey(f.cache, kind: .cache, portable: true)
        let signature = try CloudArchiveInventory.signature(f.cache, kind: .cache)
        let artifact = try XCTUnwrap(manifest.artifacts.first { $0.kind == .cache })
        // A cached mismatch goes straight to the choice, without reopening any file.
        await fingerprints.save([key: .init(signature: signature.sha256, sha256: "different", withoutRootMtime: nil)])
        let mismatch = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(mismatch.decision, .downloadCache)
        XCTAssertTrue(mismatch.hasUsableLocalCache)
        await fingerprints.save([key: .init(signature: signature.sha256, sha256: artifact.inventorySHA256, withoutRootMtime: nil)])
        let match = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(match.verifiedCache, f.cache)

        let file = f.cache.appendingPathComponent("run.key")
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try Data("different!".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        let changed = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(changed.decision, .downloadCache)
        XCTAssertNil(changed.verifiedCache)
        XCTAssertTrue(changed.hasUsableLocalCache)
    }

    func testCancelledRebuildCheckDoesNotOfferAnUnverifiedCache() async throws {
        let f = try fixture(useSyntheticBackend: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let check = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false)
        }
        do {
            _ = try await check.value
            XCTFail("Cancellation must not produce a rebuild decision")
        } catch is CancellationError {}
    }

    func testInterruptedRestoreLeavesOriginalAndSuccessfulSwapKeepsPreviousCopy() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        _ = try await service.upload(f.game)
        try Data("current-v2".utf8).write(to: f.cache.appendingPathComponent("run.key"))
        let changed = try await service.checkRebuild(f.game, sourcesAvailable: true, withoutCache: false)
        XCTAssertEqual(changed.decision, .downloadCache)
        let interrupted = Task {
            try await service.restore(.cache, for: f.game, beforeMutation: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do {
            _ = try await interrupted.value
            XCTFail("The last cancellation check precedes publication")
        } catch is CancellationError {}
        XCTAssertEqual(try cacheContents(f.cache), "current-v2")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains {
            $0.hasPrefix(".arcane-cloud-") && !$0.hasPrefix(".arcane-cloud-files-")
        })
        let previous = try await service.restore(.cache, for: f.game)
        XCTAssertEqual(try cacheContents(f.cache), "cache-data")
        XCTAssertEqual(try cacheContents(XCTUnwrap(previous)), "current-v2")
    }

    func testNeverTrashesDifferentLocalContentOrOmittedCacheData() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let manifest = try await service.upload(f.game)
        try Data("not-backed".utf8).write(to: f.cache.appendingPathComponent("run.key"))
        do {
            try await service.free(.cache, for: f.game, confirmed: true)
            XCTFail("The verified remote copy is not the current cache")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .localChanged) }
        let saves = f.cache.appendingPathComponent("run/save")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        let save = saves.appendingPathComponent("local")
        try Data([42]).write(to: save)
        let before = try await f.backend.list()
        do {
            _ = try await service.upload(f.game)
            XCTFail("An archive with excluded data cannot be offered for later eviction")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .excludedFiles) }
        let after = try await f.backend.list()
        XCTAssertEqual(before.sorted { $0.key.value < $1.key.value }, after.sorted { $0.key.value < $1.key.value })
        let current = try await service.latest(titleID: title)
        XCTAssertEqual(current, manifest)
        do {
            try await service.free(.cache, for: f.game, confirmed: true)
            XCTFail("No eviction if the cache has excluded files")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .excludedFiles) }
        do {
            try await service.restore(.cache, for: f.game)
            XCTFail("No replacement if the cache has excluded files")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .excludedFiles) }
        XCTAssertEqual(try Data(contentsOf: save), Data([42]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.trash.path), [])
    }

    func testCacheSkipsRootObsoleteAndNSPInUploadFreeAndRestore() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        for name in ["obsolete", "NSP", "nested/obsolete"] {
            let folder = f.cache.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data([42]).write(to: folder.appendingPathComponent(".keep"))
        }
        let manifest = try await service.upload(f.game)
        // Removing/recreating an ignored directory changes the root mtime, but not the archive's contents.
        let nsp = f.cache.appendingPathComponent("NSP")
        try FileManager.default.removeItem(at: nsp)
        try FileManager.default.createDirectory(at: nsp, withIntermediateDirectories: false)
        try Data([1, 2]).write(to: nsp.appendingPathComponent(".keep"))
        let synced = try await service.copyStatuses(f.game, manifest: .success(manifest))
        XCTAssertEqual(synced[.cache]?.state, .synchronized)
        XCTAssertEqual(synced[.cache]?.bytes, 15)
        XCTAssertEqual(synced[.cache]?.skippedRoots, [.init(path: "NSP", bytes: 2), .init(path: "obsolete", bytes: 1)])

        let failedTrash = CloudGameArchive(backend: f.backend, trash: { _ in throw CocoaError(.fileWriteUnknown) })
        do {
            try await failedTrash.free(.cache, for: f.game, confirmed: true)
            XCTFail("A failed Trash move must be reported")
        } catch { XCTAssertEqual(error as? CocoaError, CocoaError(.fileWriteUnknown)) }
        XCTAssertEqual(try cacheContents(f.cache), "cache-data")

        try await service.free(.cache, for: f.game, confirmed: true)
        for folder in [f.cache, f.trash.appendingPathComponent("cache")] {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            XCTAssertEqual(names, folder == f.cache ? ["NSP", "obsolete"] : ["nested", "run.key"])
        }
        let freed = try await service.copyStatuses(f.game, manifest: .success(manifest))
        XCTAssertEqual(freed[.cache]?.state, .cloudOnly)
        XCTAssertFalse(freed[.cache]?.hasLocalCopy ?? true)
        try await service.restore(.cache, for: f.game, onlyIfMissing: true)
        XCTAssertEqual(try cacheContents(f.cache), "cache-data")
        XCTAssertEqual(try Data(contentsOf: nsp.appendingPathComponent(".keep")), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: f.cache.appendingPathComponent("obsolete/.keep")), Data([42]))
        XCTAssertEqual(try Data(contentsOf: f.cache.appendingPathComponent("nested/obsolete/.keep")), Data([42]))
        let restored = try await service.copyStatuses(f.game, manifest: .success(manifest))
        XCTAssertEqual(restored[.cache]?.state, .synchronized)
    }

    func testExternalSymlinksStopPublication() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createSymbolicLink(atPath: f.cache.appendingPathComponent("escape").path,
                                                   withDestinationPath: "../remote")
        do {
            _ = try await f.service.upload(f.game)
            XCTFail("An external link cannot be archived")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .unsafePath) }
        let latest = try await f.service.latest(titleID: title)
        XCTAssertNil(latest)
    }

    private struct Fixture {
        let root: URL
        let remote: URL
        let trash: URL
        let app: URL
        let cache: URL
        let backend: RcloneStorageBackend
        let game: CloudArchiveGame

        var service: CloudGameArchive {
            CloudGameArchive(backend: backend, trash: { item in
                let name = item.pathExtension == "app" ? "app" : "cache"
                try FileManager.default.moveItem(at: item, to: self.trash.appendingPathComponent(name))
            })
        }
    }

    private func fixture(useSyntheticBackend: Bool = false) throws -> Fixture {
        let binary = useSyntheticBackend ? nil : RcloneStorageBackend.findExecutable()
        if binary == nil && !useSyntheticBackend { throw XCTSkip("rclone is not installed") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ArcaneCloudTests-\(UUID().uuidString)", isDirectory: true)
        do {
            let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
            let cache = root.appendingPathComponent("\(title)_build", isDirectory: true)
            let remote = root.appendingPathComponent("remote", isDirectory: true)
            let trash = root.appendingPathComponent("trash", isDirectory: true)
            for directory in [app.appendingPathComponent("Contents/MacOS"), app.appendingPathComponent("Contents/Resources/msl"),
                              cache.appendingPathComponent("nested"), remote, trash] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let info = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "org.arcane.tests.fake", "CFBundleExecutable": "Fixture",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2",
                "DMTitleID": title, "DMCommit": "72d43ff6",
            ], format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/Fixture"))
            try Data([1, 2, 3]).write(to: app.appendingPathComponent("Contents/Resources/msl/b-1234567890ab.img"))
            try Data().write(to: app.appendingPathComponent("Contents/Resources/empty"))
            try fm.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/link").path, withDestinationPath: "empty")
            try command("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            let cached = cache.appendingPathComponent("run.key")
            try Data("cache-data".utf8).write(to: cached)
            try Data([1, 2, 3, 4]).write(to: cache.appendingPathComponent("nested/one"))
            XCTAssertEqual(chmod(cached.path, 0o640), 0)
            var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
                         timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
            XCTAssertEqual(utimensat(AT_FDCWD, cached.path, &times, 0), 0)
            var value = UInt8(42)
            XCTAssertEqual(setxattr(cached.path, "org.arcane.test", &value, 1, 0, 0), 0)
            try fm.createSymbolicLink(atPath: cache.appendingPathComponent("nested/link").path, withDestinationPath: "../run.key")
            let config = root.appendingPathComponent("rclone.conf")
            try Data().write(to: config)
            let executable = try binary ?? syntheticBackend(in: root)
            let backend = RcloneStorageBackend(remote: ":local:", root: remote.path, executable: executable, config: config)
            let game = CloudArchiveGame(titleID: title, locations: [.app: app, .cache: cache])
            return Fixture(root: root, remote: remote, trash: trash, app: app, cache: cache, backend: backend, game: game)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    /// A CLI fixture for the real streaming and archive protocol; it never opens a network connection.
    private func syntheticBackend(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("fake-rclone")
        try """
        #!/usr/bin/python3
        import hashlib, json, os, shutil, sys
        from pathlib import Path
        cmd, *args = sys.argv[1:]
        if cmd == "rcd":
            sys.exit(1)
        root = Path(__file__).resolve().parent
        def path(arg):
            result = Path(arg.removeprefix(":local:").removeprefix(":local,links=true:")).resolve()
            assert result.is_relative_to(root) or (
                not arg.startswith(":local:") and any(p.startswith((".arcane-cloud-", ".arcane-download-")) for p in result.parts))
            return result
        def item(p):
            data = p.read_bytes() if p.is_file() else b""
            return dict(Path=p.name, Name=p.name, Size=len(data), IsDir=p.is_dir(),
                        Hashes={"md5": hashlib.md5(data).hexdigest(), "sha256": hashlib.sha256(data).hexdigest()})
        if cmd == "lsjson":
            p = path(args[0])
            if "--stat" in args:
                print(json.dumps(item(p) if p.exists() and ("--files-only" not in args or p.is_file()) else None))
            elif p.is_dir():
                if "--recursive" in args:
                    print(json.dumps([dict(item(c), Path=str(c.relative_to(p))) for c in p.rglob("*")
                        if not c.is_relative_to(p / ".arcane-upload") and ("--files-only" not in args or c.is_file())]))
                else:
                    print(json.dumps([item(c) for c in p.iterdir() if c.is_dir() == ("--dirs-only" in args)]))
            else:
                sys.exit(3)
        elif cmd == "copy":
            if (root / "quota").exists():
                print("googleapi: Error 403: storageQuotaExceeded", file=sys.stderr)
                sys.exit(1)
            src, dest = map(path, args[:2])
            listed = Path(args[args.index("--files-from-raw") + 1]).read_text().splitlines()
            previous = path(args[args.index("--copy-dest") + 1]) if "--copy-dest" in args else None
            sending = args[0].startswith(":local,links=true:")
            for name in sorted(listed, key=lambda name: name.endswith(".rclonelink")):
                if sending and name.endswith(".rclonelink"):
                    data = os.readlink(src / name.removesuffix(".rclonelink")).encode()
                else:
                    data = (src / name).read_bytes()
                target = dest / name
                if target.exists():
                    assert target.read_bytes() == data
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                reused = previous and (previous / name).is_file() and (previous / name).read_bytes() == data
                target.write_bytes(data)
                event = "server:" if reused else "upload:" if sending else "download:"
                key = target if sending else src / name
                with (root / "transfers").open("a") as log:
                    log.write(event + str(key.relative_to(root / "remote")) + "\\n")
                if (root / "interrupt").exists():
                    (root / "interrupt").unlink()
                    sys.exit(7)
        elif cmd in ("rcat", "copyto", "moveto"):
            dest = path(args[0 if cmd == "rcat" else 1])
            dest.parent.mkdir(parents=True, exist_ok=True)
            if cmd == "rcat":
                with dest.open("xb") as out:
                    shutil.copyfileobj(sys.stdin.buffer, out)
            elif cmd == "copyto":
                shutil.copyfile(path(args[0]), dest)
            else:
                os.rename(path(args[0]), dest)
        elif cmd == "deletefile":
            path(args[0]).unlink(missing_ok=True)
        else:
            raise ValueError(cmd)
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }

    private func command(_ executable: String, _ args: [String]) throws {
        let result = try SystemCommandRunner().run(URL(fileURLWithPath: executable), args, environment: nil, currentDirectory: nil)
        guard result.status == 0 else {
            XCTFail("\(executable): \(result.stderr)")
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func cacheContents(_ cache: URL) throws -> String {
        try String(contentsOf: cache.appendingPathComponent("run.key"), encoding: .utf8)
    }

    private func fileStamp(_ file: URL) throws -> (Int, Int, mode_t) {
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        return (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, info.st_mode & 0o777)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CloudArchiveProgress] = []
    func record(_ value: CloudArchiveProgress) { lock.withLock { values.append(value) } }
    func snapshot() -> [CloudArchiveProgress] { lock.withLock { values } }
}
