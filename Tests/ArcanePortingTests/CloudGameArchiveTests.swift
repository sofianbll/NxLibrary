import Darwin
import Foundation
import XCTest
@testable import NXLibraryCore
@testable import ArcanePorting

final class CloudGameArchiveTests: XCTestCase {
    private let title = "0100E65002BB8000"

    func testCloudOnlyRequiresAManifestAppAndKnownLocalAbsence() {
        XCTAssertEqual(CloudAppAvailability(remote: [.app], localApp: false), .cloudOnly)
        XCTAssertEqual(CloudAppAvailability(remote: [.app], localApp: true), .cloudCopy)
        XCTAssertEqual(CloudAppAvailability(remote: [.app], localApp: nil), .cloudCopy)
        XCTAssertEqual(CloudAppAvailability(remote: [.cache], localApp: false), .unknown)
        XCTAssertEqual(CloudAppAvailability(remote: nil, localApp: false), .unknown)
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
        XCTAssertTrue(phases.contains { $0.phase == .archiving && $0.kind == .app })
        XCTAssertTrue(phases.contains { $0.phase == .uploading && $0.kind == .app && $0.transfer?.bytesTransferred == 0 })
        XCTAssertTrue(phases.contains { $0.phase == .verifying && $0.kind == .cache })
        XCTAssertEqual(manifest.artifacts.map(\.kind), [.app, .cache])
        XCTAssertEqual(manifest.artifacts.first?.engineCommit, "72d43ff6")
        XCTAssertEqual(manifest.artifacts.first?.shaderChain, "1234567890ab")
        let latest = try await service.latest(titleID: title)
        XCTAssertEqual(latest, manifest)
        for artifact in manifest.artifacts {
            try await fixture.backend.verify(artifact.object(titleID: title))
        }

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
        let stamp = try fileStamp(fixture.cache.appendingPathComponent("run.key"))
        XCTAssertEqual(stamp.0, 1_700_000_000)
        XCTAssertEqual(stamp.1, 123_456_789)
        XCTAssertEqual(stamp.2, 0o640)
        XCTAssertEqual(try SaveFiles.attributes(fixture.cache.appendingPathComponent("run.key"))["org.arcane.test"], Data([42]))
    }

    func testCorruptRemoteObjectDoesNotRestoreOrPermitFree() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        let manifest = try await service.upload(f.game)
        let object = try XCTUnwrap(manifest.artifacts.first { $0.kind == .cache }).object(titleID: title)
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
                if progress.phase == .archiving, progress.kind == .cache {
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
    }

    func testChecksSpaceBeforeArchiveOrRestore() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = CloudGameArchive(backend: f.backend, capacity: { _ in 0 }, trash: { _ in })
        do {
            _ = try await service.upload(f.game)
            XCTFail("Must refuse staging without space")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .insufficientSpace) }
        let empty = try await service.latest(titleID: title)
        XCTAssertNil(empty)
        _ = try await f.service.upload(f.game)
        do {
            try await service.restore(.cache, for: f.game)
            XCTFail("Must refuse staging archive and extraction without space")
        } catch { XCTAssertEqual(error as? CloudArchiveError, .insufficientSpace) }
        XCTAssertEqual(try cacheContents(f.cache), "cache-data")
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
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(".arcane-cloud-") })
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
        XCTAssertEqual(try Data(contentsOf: save), Data([42]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.trash.path), [])
    }

    func testCacheWithObsoleteOrConvertedPackagesCannotBeUploaded() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for name in ["obsolete", "nsp"] {
            let folder = f.cache.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                _ = try await f.service.upload(f.game)
                XCTFail("An excluded \(name) folder must stay on disk")
            } catch { XCTAssertEqual(error as? CloudArchiveError, .excludedFiles) }
            try FileManager.default.removeItem(at: folder)
        }
        let remote = try await f.backend.list()
        XCTAssertEqual(remote, [])
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

    private func fixture() throws -> Fixture {
        guard let binary = RcloneStorageBackend.findExecutable() else { throw XCTSkip("rclone is not installed") }
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
                "CFBundlePackageType": "APPL", "DMTitleID": title, "DMCommit": "72d43ff6",
            ], format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/Fixture"))
            try Data([1, 2, 3]).write(to: app.appendingPathComponent("Contents/Resources/msl/b-1234567890ab.img"))
            try command("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            let cached = cache.appendingPathComponent("run.key")
            try Data("cache-data".utf8).write(to: cached)
            XCTAssertEqual(chmod(cached.path, 0o640), 0)
            var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
                         timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
            XCTAssertEqual(utimensat(AT_FDCWD, cached.path, &times, 0), 0)
            var value = UInt8(42)
            XCTAssertEqual(setxattr(cached.path, "org.arcane.test", &value, 1, 0, 0), 0)
            try fm.createSymbolicLink(atPath: cache.appendingPathComponent("nested/link").path, withDestinationPath: "../run.key")
            let config = root.appendingPathComponent("rclone.conf")
            try Data().write(to: config)
            let backend = RcloneStorageBackend(remote: ":local:", root: remote.path, executable: binary, config: config)
            let game = CloudArchiveGame(titleID: title, locations: [.app: app, .cache: cache])
            return Fixture(root: root, remote: remote, trash: trash, app: app, cache: cache, backend: backend, game: game)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
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
