import AppKit
import Combine
import NXLibraryCore
import ArcanePorting

enum CloudLibraryAction: Equatable {
    case upload
    case free(CloudArtifactKind)
    case restore(CloudArtifactKind)
    case restoreBuildCache
}

struct CloudLibraryState {
    var local: [CloudArtifactKind: Bool] = [:]
    var remote: Set<CloudArtifactKind>?
    var action: CloudLibraryAction?
    var progress: Double?
    var message: String?
    var refreshing = false
}

final class CloudLibraryModel: ObservableObject {
    static let preference = "NXLibrary_CloudStorage"
    let archive: CloudGameArchive?
    @Published var states: [UUID: CloudLibraryState] = [:]
    var jobs: [UUID: Task<Void, Never>] = [:]
    var jobTokens: [UUID: UUID] = [:]
    var isWorking: Bool { !jobs.isEmpty }

    init() {
        let setting = AppData.preferences.string(forKey: Self.preference)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = setting.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        archive = parts.first.flatMap {
            guard !$0.isEmpty else { return nil }
            return CloudGameArchive(backend: RcloneStorageBackend(remote: String($0),
                                                                 root: parts.count == 2 ? String(parts[1]) : "Games"))
        }
    }

    @MainActor func update(_ id: UUID, _ change: (inout CloudLibraryState) -> Void) {
        var state = states[id] ?? CloudLibraryState()
        change(&state)
        states[id] = state
    }
}

extension AppViewModel {
    var hasCloudLibrary: Bool { cloudLibrary.archive != nil }

    func showsCloudLibrary(_ game: PortedGame) -> Bool {
        hasCloudLibrary && game.platform == .macApp && game.titleId.map(SaveLocation.validID) == true
    }

    @MainActor func canChangeCloudLibrary(_ game: PortedGame) -> Bool {
        guard let title = game.titleId else { return false }
        return !isBuilding && !isCheckingCloudBuild && !isCleaningStorage && !isUpdatingApp && !isScanningLibrary &&
            !appIcon.appIconsInFlight.contains(game.id) && game.pendingInstall == nil &&
            !saveGate.isBusy(titleID: title) && RunningGameMonitor.runningApplication(for: game) == nil
    }

    @MainActor func startCloudBuild(for game: PortedGame, archive: CloudGameArchive, extraArguments: [String],
                                    onStarted: (() -> Void)?, withoutCache: Bool) async {
        let target = libraryGames.first(where: { $0.id == game.id }) ?? game
        guard GameResourceState.sourcesAvailable(for: target) else {
            porting.presentBuildError(NXLibraryError.missingSources)
            return
        }
        guard let title = target.titleId, SaveLocation.validID(title) else {
            porting.presentBuildError(NXLibraryError.missingTitleId)
            return
        }
        do {
            let token = try await archive.beginBuild(titleID: title)
            let release = { await archive.endBuild(titleID: title, token: token) }
            do {
                let locations = withoutCache ? CloudArchiveGame(titleID: title, locations: [:]) : await cloudLocations(for: target)
                let check: (decision: CloudRebuildDecision, verifiedCache: URL?)
                do {
                    check = try await archive.checkRebuild(locations, sourcesAvailable: true, withoutCache: withoutCache)
                } catch {
                    await release()
                    showCloudBuildNotice(for: target, archive: archive, extraArguments: extraArguments,
                                         onStarted: onStarted, canDownload: false)
                    return
                }
                switch check.decision {
                case .missingSources:
                    throw NXLibraryError.missingSources
                case .downloadCache:
                    await release()
                    showCloudBuildNotice(for: target, archive: archive, extraArguments: extraArguments,
                                         onStarted: onStarted, canDownload: true)
                case .allowed:
                    guard let current = libraryGames.first(where: { $0.id == target.id }),
                          current.titleId == target.titleId, current.workspacePath == target.workspacePath,
                          current.buildCachePath == target.buildCachePath else { throw CloudArchiveError.busy }
                    try porting.beginBuild(for: target, extraArguments: extraArguments, verifiedCache: check.verifiedCache,
                                   withoutCache: withoutCache,
                                   releaseCloudBuild: release)
                    onStarted?()
                }
            } catch {
                await release()
                throw error
            }
        } catch {
            porting.presentBuildError(error)
        }
    }

    @MainActor private func showCloudBuildNotice(for game: PortedGame, archive: CloudGameArchive,
                                                  extraArguments: [String], onStarted: (() -> Void)?, canDownload: Bool) {
        let title = L10n.text("Rebuild")
        let confirmOverride: () -> Void = { [weak self] in
            self?.showSettingsNotice(title: title,
                message: L10n.text("Rebuild from the original game files without using the existing cache? This can take much longer."),
                actionTitle: "Rebuild without cache", cancelTitle: "Cancel") { [weak self] in
                    self?.porting.requestCloudBuild(for: game, archive: archive, extraArguments: extraArguments,
                                            onStarted: onStarted, withoutCache: true)
                }
        }
        if canDownload {
            showSettingsNotice(title: title,
                message: L10n.text("The build cache in the cloud has no verified local copy. Download it before rebuilding. Any existing cache is kept as a backup."),
                actionTitle: "Download cache", cancelTitle: "Cancel") { [weak self] in
                    guard let self else { return }
                    self.performCloudLibrary(.restoreBuildCache, for: game)
                    if self.cloudLibrary.jobs[game.id] != nil {
                        self.cloudLibraryGameID = game.id
                    } else {
                        self.showSettingsNotice(title: title, message: self.cloudMessage(for: CloudArchiveError.busy))
                    }
                }
            settingsNotice?.alternative = ("Rebuild without cache", confirmOverride)
        } else {
            showSettingsNotice(title: title,
                message: L10n.text("Arcane could not check the cloud manifest. Check rclone and try again."),
                actionTitle: "Rebuild without cache", cancelTitle: "Cancel", retry: confirmOverride)
        }
    }

    @MainActor func refreshCloudLibrary(_ game: PortedGame) async {
        guard let archive = cloudLibrary.archive, let game = libraryGames.first(where: { $0.id == game.id }),
              cloudLibrary.states[game.id]?.refreshing != true, cloudLibrary.jobs[game.id] == nil else { return }
        let id = game.id
        cloudLibrary.update(id) { $0.refreshing = true; $0.remote = nil; $0.message = nil }
        defer { cloudLibrary.update(id) { $0.refreshing = false } }
        let target = await cloudLocations(for: game)
        let local = await archive.localStatus(target)
        cloudLibrary.update(id) { $0.local = local }
        do {
            let manifest = try await archive.latest(titleID: target.titleID)
            try Task.checkCancellation()
            cloudLibrary.update(id) { $0.remote = Set(manifest?.artifacts.map(\.kind) ?? []) }
        } catch is CancellationError {
            // Closing the panel cancels this read, but not a user-started transfer.
        } catch {
            cloudLibrary.update(id) { $0.message = cloudMessage(for: error) }
        }
    }

    @MainActor func confirmCloudFree(_ kind: CloudArtifactKind, for game: PortedGame) {
        showSettingsNotice(title: L10n.text("Free up space"),
            message: L10n.text(kind == .app
                ? "After verification, Arcane moves this app to the Trash. Download it again to play. Saves stay on this Mac."
                : "After verification, Arcane moves this build cache to the Trash. Game files and saves stay on this Mac."),
            actionTitle: "Free up space", cancelTitle: "Cancel") { [weak self] in
                self?.performCloudLibrary(.free(kind), for: game)
            }
    }

    @MainActor func performCloudLibrary(_ action: CloudLibraryAction, for selected: PortedGame) {
        guard let archive = cloudLibrary.archive,
              let game = libraryGames.first(where: { $0.id == selected.id }),
              game.url == selected.url, game.buildCachePath == selected.buildCachePath,
              game.workspacePath == selected.workspacePath,
              cloudLibrary.jobs[game.id] == nil, cloudLibrary.states[game.id]?.refreshing != true,
              canChangeCloudLibrary(game), let release = acquireSaveInstallLease(for: game) else {
            cloudLibrary.update(selected.id) { $0.message = cloudMessage(for: CloudArchiveError.busy) }
            return
        }
        let id = game.id
        let token = UUID()
        cloudLibrary.jobTokens[id] = token
        cloudLibrary.update(id) { $0.action = action; $0.progress = nil; $0.message = nil }
        cloudLibrary.jobs[id] = Task { [weak self] in
            guard let self else { release(); return }
            defer {
                self.cloudLibrary.jobs[id] = nil
                self.cloudLibrary.jobTokens[id] = nil
                release()
                self.cloudLibrary.update(id) { $0.action = nil; $0.progress = nil }
                self.appIcon.syncPendingAppIcons()
                self.resumeLibraryScanAfterCloud()
            }
            let target = await self.cloudLocations(for: game)
            let progress: CloudGameArchive.Progress = { [weak self] value in
                Task { @MainActor in
                    guard let self, self.cloudLibrary.jobTokens[id] == token else { return }
                    self.cloudLibrary.update(id) { $0.progress = value }
                }
            }
            // Also catch a direct Finder launch, which does not take Arcane's lease.
            let gameClosed: @Sendable () throws -> Void = {
                if RunningGameMonitor.runningApplication(for: game) != nil { throw CloudArchiveError.busy }
            }
            do {
                switch action {
                case .upload:
                    let manifest = try await archive.upload(target, progress: progress)
                    self.cloudLibrary.update(id) { $0.remote = Set(manifest.artifacts.map(\.kind)) }
                case .free(let kind):
                    try await archive.free(kind, for: target, confirmed: true, beforeMutation: gameClosed)
                    if kind == .app {
                        self.applyCatalog(try self.catalogRepository.updateNXNative(id: id) { $0.status = .appMissing })
                    }
                case .restore, .restoreBuildCache:
                    let kind: CloudArtifactKind
                    if case .restore(let selectedKind) = action { kind = selectedKind } else { kind = .cache }
                    if action == .restoreBuildCache, let cache = target.locations[.cache] {
                        let parent = cache.deletingLastPathComponent()
                        let root = BuildScratch.choose(core: AppData.supportRoot,
                            appFolder: self.gameAppsFolder).workspaces
                        if parent.standardizedFileURL.path == root.appendingPathComponent(target.titleID).standardizedFileURL.path,
                           !FileManager.default.fileExists(atPath: parent.path) {
                            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                        }
                    }
                    try await archive.restore(kind, for: target, onlyIfMissing: action != .restoreBuildCache,
                                              progress: progress, beforeMutation: gameClosed)
                    if kind == .app, let url = target.locations[.app] {
                        GameIconProvider.forget(game)
                        self.applyCatalog(try self.catalogRepository.updateNXNative(id: id) { item in
                            item.url = url
                            item.status = GameResourceState.sourcesAvailable(for: item) ? .built : .builtSourcesMissing
                            item.versionString = BuildOutputInstaller.version(of: url)
                            item.bundleId = Bundle(url: url)?.bundleIdentifier
                            item.modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                        })
                    }
                }
            } catch is CancellationError {
                self.cloudLibrary.update(id) { $0.message = L10n.text("Transfer cancelled.") }
            } catch {
                self.cloudLibrary.update(id) {
                    $0.message = self.cloudMessage(for: error)
                    if error is StorageBackendError || error as? CloudArchiveError == .invalidManifest { $0.remote = nil }
                }
            }
            let current = await archive.localStatus(target)
            self.cloudLibrary.update(id) { $0.local = current }
        }
    }

    @MainActor func cancelCloudLibrary(_ game: PortedGame) {
        cloudLibrary.jobs[game.id]?.cancel()
    }

    @MainActor private func cloudLocations(for game: PortedGame) async -> CloudArchiveGame {
        let games = libraryGames
        return await Task.detached(priority: .utility) {
            var locations: [CloudArtifactKind: URL] = [:]
            func path(_ url: URL) -> String {
                url.resolvingSymlinksInPath().standardizedFileURL.path
                    .precomposedStringWithCanonicalMapping.lowercased()
            }
            func overlaps(_ lhs: String, _ rhs: String) -> Bool {
                lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
            }
            let appPath = path(game.url)
            let sources = games.flatMap(\.sources).map { path($0.url) }
            let otherApps = games.filter { $0.id != game.id && $0.url.pathExtension.lowercased() == "app" }
            if game.url.pathExtension.lowercased() == "app",
               !sources.contains(where: { overlaps(appPath, $0) }),
               !otherApps.contains(where: { overlaps(appPath, path($0.url)) }),
               !games.compactMap(\.workspacePath).contains(where: {
                   let workspace = path(URL(fileURLWithPath: $0))
                   return workspace == appPath || workspace.hasPrefix(appPath + "/")
               }) {
                locations[.app] = game.url
            }
            if let cache = try? StorageManager().cacheURL(for: game, protecting: games) {
                let cachePath = path(cache)
                if !sources.contains(where: { overlaps(cachePath, $0) }),
                   !games.filter({ $0.id != game.id }).compactMap(\.buildCachePath)
                    .contains(where: { overlaps(cachePath, path(URL(fileURLWithPath: $0))) }) {
                    locations[.cache] = cache
                }
            }
            return CloudArchiveGame(titleID: game.titleId ?? "", locations: locations,
                                    engineCommit: game.lastBuild?.exitCode == 0 ? game.lastBuild?.engineCommit : nil)
        }.value
    }

    private func cloudMessage(for error: Error) -> String {
        if let error = error as? CloudArchiveError { return error.localizedDescription }
        if error as? StorageBackendError == .hashMismatch {
            return L10n.text("The cloud copy could not be verified.")
        }
        return L10n.text("Cloud storage is unavailable. Check rclone and try again.")
    }
}
