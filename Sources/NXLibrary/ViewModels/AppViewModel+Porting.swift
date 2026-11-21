import AppKit
import NXLibraryCore
import ArcanePorting

/// What the home shows of the porting: the tile look, the pills and the time line.
extension AppViewModel {
    /// The game being ported now, if any.
    var portingGameID: UUID? { isBuilding ? currentBuildGameID : nil }

    func portingTileLook(_ game: PortedGame) -> PortingTileLook {
        if game.id != portingGameID, cloudLibrary.states[game.id]?.appIsCloudOnly == true { return .normal }
        return PortingTileLook.make(game: game, portingGameID: portingGameID, progress: portingProgress)
    }

    func portingPills(_ game: PortedGame) -> PortingPills {
        let pills = PortingPills.make(game: game, portingGameID: portingGameID)
        if pills == .unavailable(.sourcesMissing), canCheckCloudSources(for: game) { return .normal }
        return pills
    }

    /// "About 8 min left" under the Porting pill; nil before the shaders.
    var portingETAText: String? {
        guard isBuilding, let portingProgress else { return nil }
        return PortingETA.text(portingProgress, lastFinishingSeconds: porting.lastPortingFinishSeconds)
    }
}
