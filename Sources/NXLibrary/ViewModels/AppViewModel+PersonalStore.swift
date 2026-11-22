import ArcanePorting
import Foundation
import NXLibraryCore

extension AppViewModel {
    func personalStoreAppOffer(_ game: PortedGame, own: CloudGameManifest?,
                               reference: CloudGameManifest?) -> PersonalStore.Offer? {
        let shared = reference.map { referenceWins($0, over: own, kind: .app) } ?? false
        let manifest = shared ? reference : own
        let update = game.isPlayableLocally
        // Only the existing reference replacement path can safely update an installed app.
        guard !update || (shared && PersonalStore.isNewer(manifest?.gameVersion, than: game.versionString))
        else { return nil }
        return .app(manifest, reference: shared, update: update)
    }

    @MainActor func personalStoreState(_ game: PortedGame, localROM: Bool) -> PersonalStore.State {
        let id = game.titleId?.uppercased() ?? ""
        let facts = cloudLibrary.states[game.id]
        let offer = personalStoreAppOffer(game, own: cloudLibrary.personalManifests[id],
                                         reference: cloudLibrary.referenceManifests[id])
        let app: PersonalStore.Action? = game.isPlayableLocally
            ? (offer == nil ? .play : .update)
            : (offer != nil || facts?.availability[.app]?.state == .cloudOnly || facts?.appIsCloudOnly == true
               ? .downloadApp : nil)
        let remoteROM = facts?.sources?.state == .cloudOnly || facts?.sourceAvailability?.state == .cloudOnly ||
            facts?.referenceSourceBytes != nil || cloudLibrary.referenceManifests[id]?.sourceSelection != nil
        return .init(app: app, rom: localROM ? .prepare : remoteROM ? .downloadROM : nil)
    }

    /// Reads a fresh offer and shows the disk budget before anything joins the FIFO.
    @MainActor func planPersonalStoreTransfer(_ intent: PersonalStore.Action, game: PortedGame) async throws
        -> (offer: PersonalStore.Offer, bytes: Int64, destination: URL, free: Int64?, storage: String?) {
        guard let archive = cloudLibrary.archive, let title = game.titleId,
              libraryGames.contains(game) else { throw CloudArchiveError.noRemoteCopy }
        let action: CloudLibraryAction = intent == .downloadROM ? .downloadSources : .restore(.app)
        let storage = cloudLibrary.storageScope(for: action)
        let own = try await archive.latest(titleID: title)
        let reference = try await referenceManifest(titleID: title)
        let offer: PersonalStore.Offer
        let destination: URL
        var changedBytes: Int64?
        if action == .downloadSources {
            let files = CloudSourceFiles(game)
            if let reference, let selection = reference.sourceSelection, let sources = cloudLibrary.referenceSourceArchive,
               let shared = try await referenceSourceStatus(for: game, reference: reference, own: own),
               let parent = shared.urls.first?.deletingLastPathComponent() {
                destination = parent
                offer = try await sources.downloadOffer(folderName: selection.folderName, files: shared.urls, reference: true,
                    replacingBefore: selection.publishedAt ?? reference.createdAt, replacing: Set(files?.files ?? []))
            } else {
                guard let sources = cloudLibrary.sourceArchive, let files,
                      let parent = files.files.first?.deletingLastPathComponent() else { throw CloudArchiveError.noRemoteCopy }
                destination = parent
                offer = try await sources.downloadOffer(folderName: files.folderName, files: files.files, reference: false)
            }
        } else {
            guard let app = personalStoreAppOffer(game, own: own, reference: reference),
                  game.isPlayableLocally == (intent == .update) else { throw CloudArchiveError.noRemoteCopy }
            offer = app
            let bundle = cloudImportDestination(for: game, action: action) ?? game.url
            guard bundle.pathExtension.lowercased() == "app" else { throw CloudArchiveError.unsafePath }
            destination = bundle.deletingLastPathComponent()
            if intent == .update, let reference, let referenceArchive = cloudLibrary.referenceArchive {
                let target = await cloudLocations(for: game)
                let statuses = try await referenceArchive.copyStatuses(target, manifest: .success(reference))
                let personal = try await archive.copyStatuses(target, manifest: .success(own))
                guard let copy = try await referenceArchive.referenceCopy(.app, for: target,
                    manifest: reference, status: statuses[.app], matchesOlderCopy: personal[.app]?.state == .synchronized),
                      copy.updatesLocal else { throw CloudArchiveError.localChanged }
                changedBytes = copy.downloadBytes
            }
        }
        try Task.checkCancellation()
        let free = await Task.detached(priority: .utility) { ModInstaller.availableCapacity(destination) }.value
        guard cloudLibrary.archive === archive, cloudLibrary.storageScope(for: action) == storage,
              libraryGames.contains(game) else { throw CloudArchiveError.localChanged }
        return (offer, changedBytes ?? offer.budget.bytes, destination, free, storage)
    }
}
