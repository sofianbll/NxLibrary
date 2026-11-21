import AppKit
import Combine
import NXLibraryCore
import ArcanePorting

enum CloudLibraryAction: Equatable {
    case upload(CloudArtifactKind? = nil)
    case free(CloudArtifactKind)
    case restore(CloudArtifactKind)
    case restoreBuildCache

    func kind(during progress: CloudArchiveProgress?) -> CloudArtifactKind {
        switch self {
        case .upload(let kind): return kind ?? progress?.kind ?? (progress == nil ? .app : .cache)
        case .free(let kind), .restore(let kind): return kind
        case .restoreBuildCache: return .cache
        }
    }
}

struct CloudLibraryState {
    var copies: [CloudArtifactKind: CloudArtifactStatus] = [:]
    var action: CloudLibraryAction?
    var queued = false
    var progress: CloudArchiveProgress?
    var message: String?
    var issue: (kind: CloudArtifactKind, message: String, failed: Bool)?
    var refreshing = false
    var mustResendBoth = false

    var activeKind: CloudArtifactKind? { action?.kind(during: progress) }
    var appIsCloudOnly: Bool { copies[.app]?.state == .cloudOnly }
    func canUpload(_ kind: CloudArtifactKind) -> Bool {
        guard !mustResendBoth, let copy = copies[kind], copy.hasLocalCopy else { return false }
        switch copy.state {
        case .notInCloud, .newerOnThisMac, .unknown: return CloudArtifactStatus.canUploadAlone(kind, statuses: copies)
        case .cloudOnly, .synchronized: return false
        }
    }
    var needsCombinedUpload: Bool {
        CloudArtifactKind.allCases.allSatisfy {
            copies[$0]?.hasLocalCopy == true && (mustResendBoth || copies[$0]?.state == .notInCloud)
        }
    }
    var canUploadBoth: Bool {
        needsCombinedUpload || CloudArtifactKind.allCases.allSatisfy {
            copies[$0]?.state == .newerOnThisMac && canUpload($0)
        }
    }
}

struct CloudWorkScope: Equatable {
    let title: String
    let paths: Set<String>

    init(title: String, urls: [URL]) {
        self.title = title.uppercased()
        paths = Set(urls.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        })
    }

    init(_ game: PortedGame) {
        self.init(title: game.titleId ?? "", urls: [game.url] +
                  [game.buildCachePath, game.workspacePath].compactMap { $0.map { URL(fileURLWithPath: $0) } })
    }

    func overlaps(_ other: Self) -> Bool {
        (!title.isEmpty && title == other.title) || paths.contains { lhs in
            other.paths.contains { rhs in
                lhs == rhs || lhs == "/" || rhs == "/" || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
            }
        }
    }
}

final class CloudLibraryModel: ObservableObject {
    struct Request {
        let token = UUID()
        let id: UUID
        let action: CloudLibraryAction
        let scope: CloudWorkScope
    }

    @Published private(set) var preference: CloudLibraryPreference
    @Published private(set) var chosenExecutable: URL?
    @Published private(set) var archive: CloudGameArchive?
    @Published var isChangingConnection = false
    @Published var states: [UUID: CloudLibraryState] = [:]
    private var backend: RcloneStorageBackend?
    var reads: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    var queue: [Request] = []
    var active: (request: Request, task: Task<Void, Never>)?
    var isWorking: Bool { active != nil || !queue.isEmpty }

    func conflicts(with scope: CloudWorkScope) -> Bool {
        active?.request.scope.overlaps(scope) == true || queue.contains { $0.scope.overlaps(scope) }
    }

    init() {
        let defaults = AppData.preferences
        preference = CloudLibraryPreference(storage: defaults.string(forKey: CloudLibraryPreference.storageKey),
            enabled: defaults.object(forKey: CloudLibraryPreference.enabledKey) as? Bool)
        chosenExecutable = defaults.string(forKey: CloudLibraryPreference.executableKey).map { URL(fileURLWithPath: $0) }
        rebuildArchive()
    }

    @MainActor func configure(remote: String?, root: String, enabled: Bool) {
        let next = CloudLibraryPreference(storage: "\(remote ?? ""):\(root)", enabled: enabled)
        guard next != preference else { return }
        AppData.preferences.set(next.storage, forKey: CloudLibraryPreference.storageKey)
        AppData.preferences.set(next.enabled, forKey: CloudLibraryPreference.enabledKey)
        preference = next
        rebuildArchive()
    }

    @MainActor func chooseExecutable(_ executable: URL?) {
        guard chosenExecutable != executable else { return }
        AppData.preferences.set(executable?.path, forKey: CloudLibraryPreference.executableKey)
        chosenExecutable = executable
        rebuildArchive()
    }

    private func rebuildArchive() {
        stopRemoteControl()
        reads.values.forEach { $0.task.cancel() }
        reads.removeAll()
        states = [:]
        backend = preference.enabled ? preference.remote.map {
            RcloneStorageBackend(remote: $0, root: preference.root, executable: chosenExecutable)
        } : nil
        archive = backend.map { CloudGameArchive(backend: $0) }
    }

    func stopRemoteControl() { backend?.stopRemoteControl() }

    @MainActor func update(_ id: UUID, _ change: (inout CloudLibraryState) -> Void) {
        var state = states[id] ?? CloudLibraryState()
        change(&state)
        states[id] = state
    }
}

extension AppViewModel {
    var hasCloudLibrary: Bool { cloudLibrary.archive != nil }

    func showsCloudLibrary(_ game: PortedGame) -> Bool {
        game.platform == .macApp
    }

    @MainActor func openCloudLibrary(for game: PortedGame) {
        if cloudLibrary.archive == nil { router?.openSettings(.cloudLibrary) }
        else { cloudLibraryGameID = game.id }
    }

    /// Read only the settled selection, not every tile or every game passed during a scroll.
    @MainActor func prefetchCloudLibrary(_ game: PortedGame?) async {
        guard let game, cloudLibrary.archive != nil, showsCloudLibrary(game), cloudLibraryGameID == nil else { return }
        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        if cloudLibraryGameID == nil, cloudLibrary.reads[game.id] == nil { await refreshCloudLibrary(game) }
    }

    var canConfigureCloudLibrary: Bool {
        !isBuilding && !isCheckingCloudBuild && !isUpdatingApp && !cloudLibrary.isWorking && !cloudLibrary.isChangingConnection
    }

    @MainActor func canChangeCloudLibrary(_ game: PortedGame) -> Bool {
        guard let title = game.titleId else { return false }
        return porting.cloudBuildScope?.overlaps(CloudWorkScope(game)) != true &&
            !isCleaningStorage && !isUpdatingApp && !isScanningLibrary &&
            !cloudLibrary.isChangingConnection &&
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
                    if self.cloudLibrary.states[game.id]?.action == .restoreBuildCache {
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
              let titleID = game.titleId, SaveLocation.validID(titleID),
              !Task.isCancelled, cloudLibrary.states[game.id]?.action == nil else { return }
        let id = game.id, token = UUID()
        cloudLibrary.reads[id]?.task.cancel()
        cloudLibrary.update(id) { $0.refreshing = true; $0.message = nil }
        let read = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.cloudLibrary.reads[id]?.token == token {
                    self.cloudLibrary.reads[id] = nil
                    self.cloudLibrary.update(id) { $0.refreshing = false }
                }
            }
            async let target = self.cloudLocations(for: game)
            let lookup: Result<CloudGameManifest?, Error>
            do { lookup = .success(try await archive.latest(titleID: titleID)) }
            catch { lookup = .failure(error) }
            guard let copies = try? await archive.copyStatuses(target, manifest: lookup), !Task.isCancelled,
                  self.cloudLibrary.reads[id]?.token == token, self.cloudLibrary.archive === archive,
                  let current = self.libraryGames.first(where: { $0.id == id }),
                  current.titleId == titleID, current.url == game.url,
                  current.buildCachePath == game.buildCachePath, current.workspacePath == game.workspacePath,
                  current.modificationDate == game.modificationDate else { return }
            self.cloudLibrary.update(id) {
                $0.copies = copies
                if case .failure(let error) = lookup { $0.message = self.cloudMessage(for: error) }
            }
        }
        cloudLibrary.reads[id] = (token, read)
        await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
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
        guard cloudLibrary.archive != nil,
              let game = libraryGames.first(where: { $0.id == selected.id }),
              CloudWorkScope(game) == CloudWorkScope(selected),
              game.titleId.map(SaveLocation.validID) == true,
              cloudLibrary.states[game.id]?.action == nil, cloudLibrary.states[game.id]?.refreshing != true,
              canChangeCloudLibrary(game) else {
            cloudLibrary.update(selected.id) {
                $0.issue = (action.kind(during: nil), cloudMessage(for: CloudArchiveError.busy), true)
            }
            return
        }
        if case .upload(let kind) = action {
            let state = cloudLibrary.states[game.id] ?? CloudLibraryState()
            guard kind.map(state.canUpload) ?? state.canUploadBoth else { return }
        }
        objectWillChange.send()
        cloudLibrary.queue.append(.init(id: game.id, action: action, scope: CloudWorkScope(game)))
        cloudLibrary.update(game.id) {
            $0.action = action; $0.queued = true; $0.progress = nil; $0.message = nil; $0.issue = nil
        }
        startNextCloudOperation()
    }

    @MainActor private func startNextCloudOperation() {
        guard cloudLibrary.active == nil else { return }
        while !cloudLibrary.queue.isEmpty {
            let request = cloudLibrary.queue.removeFirst()
            let id = request.id, action = request.action
            assert(cloudLibrary.states[id]?.action == action && cloudLibrary.states[id]?.queued == true)
            guard let archive = cloudLibrary.archive,
                  let game = libraryGames.first(where: { $0.id == id }),
                  CloudWorkScope(game) == request.scope, canChangeCloudLibrary(game),
                  let release = acquireSaveInstallLease(for: game) else {
                cloudLibrary.update(id) {
                    $0.action = nil; $0.queued = false
                    $0.issue = (action.kind(during: nil), cloudMessage(for: CloudArchiveError.busy), true)
                }
                continue
            }
            cloudLibrary.update(id) { $0.queued = false }
            cloudLibrary.active = (request, runCloudOperation(request, archive: archive, game: game, release: release))
            return
        }
        resumeLibraryScanAfterCloud()
    }

    @MainActor private func runCloudOperation(_ request: CloudLibraryModel.Request, archive: CloudGameArchive,
                                             game: PortedGame, release: @escaping () -> Void) -> Task<Void, Never> {
        let id = request.id, action = request.action
        return Task { [weak self] in
            guard let self else { release(); return }
            defer {
                assert(self.cloudLibrary.active?.request.token == request.token)
                self.objectWillChange.send()
                self.cloudLibrary.active = nil
                release()
                self.cloudLibrary.update(id) { $0.action = nil; $0.progress = nil; $0.copies = [:] }
                self.startNextCloudOperation()
                self.appIcon.syncPendingAppIcons()
                Task { await self.refreshCloudLibrary(game) }
            }
            let target = await self.cloudLocations(for: game)
            let (updates, continuation) = AsyncStream.makeStream(of: CloudArchiveProgress.self, bufferingPolicy: .bufferingNewest(1))
            let listener = Task { @MainActor in
                for await value in updates {
                    guard self.cloudLibrary.active?.request.token == request.token else { break }
                    self.cloudLibrary.update(id) { $0.progress = value }
                }
            }
            defer { continuation.finish(); listener.cancel() }
            let progress: CloudGameArchive.Progress = { continuation.yield($0) }
            // Also catch a direct Finder launch, which does not take Arcane's lease.
            let gameClosed: @Sendable () throws -> Void = {
                if RunningGameMonitor.runningApplication(for: game) != nil { throw CloudArchiveError.busy }
            }
            do {
                try Task.checkCancellation()
                switch action {
                case .upload(let kind):
                    _ = try await archive.upload(target, kinds: Set(kind.map { [$0] } ?? CloudArtifactKind.allCases),
                                                 progress: progress)
                    self.cloudLibrary.update(id) { $0.mustResendBoth = false }
                case .free(let kind):
                    self.cloudLibrary.update(id) { $0.progress = .init(.verifying, kind: kind) }
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
                continuation.finish()
                await listener.value
                self.cloudLibrary.update(id) { $0.issue = (action.kind(during: $0.progress), L10n.text("Transfer cancelled."), false) }
            } catch {
                continuation.finish()
                await listener.value
                if let detail = (error as? CloudArchiveError)?.diagnosticDetail {
                    self.logs.append(LogEntry(level: .error, message: detail))
                }
                self.cloudLibrary.update(id) {
                    if (error as? CloudArchiveError) == .needsFullUpload { $0.mustResendBoth = true }
                    $0.issue = (action.kind(during: $0.progress), self.cloudMessage(for: error), true)
                }
            }
        }
    }

    @MainActor func cancelCloudLibrary(_ game: PortedGame) {
        guard let action = cloudLibrary.states[game.id]?.action else { return }
        if let index = cloudLibrary.queue.firstIndex(where: { $0.id == game.id && $0.action == action }) {
            objectWillChange.send()
            cloudLibrary.queue.remove(at: index)
            cloudLibrary.update(game.id) { $0.action = nil; $0.queued = false }
            appIcon.syncPendingAppIcons()
        } else if let active = cloudLibrary.active, active.request.id == game.id, active.request.action == action {
            active.task.cancel()
        }
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
