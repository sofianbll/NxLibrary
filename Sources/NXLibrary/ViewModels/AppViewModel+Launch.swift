import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NXLibraryCore
import ArcanePorting

/// Launching a Switch game: the launch screen, its checks and watching the launch.
extension AppViewModel {
    func launchGame(_ game: PortedGame, acceptsLocalFallback: Bool = false) {
        // One launch at a time: the launch screen covers the library, and input reaching it changes nothing.
        guard launchingGameId == nil, launchOverlay == nil else { return }
        // A running game is brought forward, never started a second time.
        if let running = RunningGameMonitor.runningApplication(for: game) {
            if let runningGameMonitor { Task { @MainActor in runningGameMonitor.resume(game) } }
            else { RunningGameMonitor.activate(running) }
            return
        }
        guard savesPermitPlay(game) else { return }
        // Installing a waiting build can itself start an icon update: check after installation too.
        let game = installingPendingBuild(of: game)
        // The app is being signed again with a new icon: starting it now could read a half-written bundle.
        guard !appIcon.appIconsInFlight.contains(game.id) else {
            appIcon.waitForAppIconBeforeLaunching(game)
            return
        }
        if !FileManager.default.fileExists(atPath: game.url.path),
           game.isPlayableLocally || game.status == .appMissing {
            let reason = GameUnavailableReason.appMissing
            lastError = reason.title + ". " + reason.detail
            alertMessage = lastError
            updateStoredStatus(.appMissing, for: game)
            SoundEffectService.shared.play(.error)
            return
        }
        guard game.isPlayableLocally else {
            let reason = GameResourceState.unavailableReason(for: game)
            let message = reason.map { $0.title + ". " + $0.detail }
                ?? L10n.text("This game is not built yet. Build it first.")
            lastError = message
            alertMessage = message
            SoundEffectService.shared.play(.error)
            logs.append(LogEntry(level: .error, message: message))
            return
        }
        guard FileManager.default.fileExists(atPath: game.url.path) else {
            let reason = GameUnavailableReason.appMissing
            lastError = reason.title + ". " + reason.detail
            alertMessage = lastError
            updateStoredStatus(.appMissing, for: game)
            SoundEffectService.shared.play(.error)
            logs.append(LogEntry(level: .error, message: lastError!))
            return
        }
        guard let titleId = game.titleId, !titleId.isEmpty else {
            lastError = NXLibraryError.missingTitleId.localizedDescription
            alertMessage = lastError
            SoundEffectService.shared.play(.error)
            logs.append(LogEntry(level: .error, message: lastError!))
            return
        }

        let gameSettings = runtimeSettings.gameSettings(for: game)
        let appSettings = settingsStore?.settings ?? AppSettings()
        let multiplayer = gameSettings?.multiplayerLaunch(settings: appSettings, adapters: .current())
        if multiplayer?.warning != nil && !acceptsLocalFallback {
            showMultiplayerVPNFallback { [weak self] in
                self?.launchGame(game, acceptsLocalFallback: true)
            }
            return
        }
        guard let saveLaunchToken = saveGate.begin(titleID: titleId) else {
            alertMessage = SaveFailure.busy.localizedDescription
            return
        }
        launchingGameId = game.id
        let setting = gameSettings.flatMap { NextendoLaunch.networkSetting(in: $0.settings) }
        let multiplayerEnvironment = multiplayer?.environment ?? [:]
        let mode = multiplayerEnvironment[NextendoLaunch.networkKey] ?? gameSettings?.effectiveLaunchValue(NextendoLaunch.networkKey)
        if NextendoLaunch.requiresSignIn(setting: setting, mode: mode) {
            let clientID = settingsStore?.settings.nextendoClientID ?? NextendoLaunch.buildClientID
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    // Validate access under the engine's lock, including credentials written by other frontends.
                    let store = NextendoTokenStore()
                    let environment = try await NextendoLaunch.environment(setting: setting, mode: mode, clientID: clientID) { client in
                        try await NextendoOAuth(store: store).accountName(clientID: client) != nil
                    }
                    self.startGame(game, titleId: titleId, token: saveLaunchToken, gameSettings: gameSettings,
                                   environment: multiplayerEnvironment.merging(environment) { _, online in online })
                } catch {
                    self.saveGate.end(titleID: titleId, token: saveLaunchToken)
                    self.launchingGameId = nil
                    let problem = error as? NextendoError ?? .service
                    let hint = problem.localizedDescription
                    SoundEffectService.shared.play(.error)
                    if [.clientID, .signedOut, .expired, .authorization].contains(problem) {
                        self.showSettingsNotice(title: "Nextendo", message: hint, actionTitle: "Play together") { [weak self] in
                            guard let self else { return }
                            self.gameForSettingsSheet = nil
                            self.router?.openSettings(.multiplayer)
                        }
                    } else {
                        self.showSettingsNotice(title: "Nextendo", message: hint)
                    }
                }
            }
            return
        }
        startGame(game, titleId: titleId, token: saveLaunchToken, gameSettings: gameSettings, environment: multiplayerEnvironment)
    }

    func showMultiplayerVPNFallback(_ proceed: @escaping () -> Void) {
        showSettingsNotice(title: "VPN unavailable",
                           message: L10n.text("This game can start on your local network instead. Players on the VPN will not be reachable."),
                           actionTitle: "Play on the local network", cancelTitle: "Cancel", primaryFirst: true, retry: proceed)
    }

    private func startGame(_ game: PortedGame, titleId: String, token saveLaunchToken: UUID,
                           gameSettings: NXNativeGameSettings?, environment: [String: String] = [:]) {
        launchOverlay = LaunchOverlayState(game: .nxnative(game))
        SoundEffectService.shared.play(.launch)

        // A saved-choices build reads the game's own store; only an older build takes env.txt and the environment.
        let config = GameRuntimeConfig.load(for: game)
        do {
            if let gameSettings {
                try gameSettings.migrate()
            } else {
                try launchService.writeEnvironment(settings: config, titleId: titleId)
            }
        } catch {
            saveGate.end(titleID: titleId, token: saveLaunchToken)
            launchingGameId = nil
            launchOverlay = nil
            lastError = error.localizedDescription
            alertMessage = lastError
            SoundEffectService.shared.play(.error)
            logs.append(LogEntry(level: .error,
                                 message: L10n.format("Could not write the runtime environment: %@", [String(describing: error.localizedDescription)])))
            return
        }

        if let choice = settingsStore?.settings.cloudSaves, let domain = game.effectiveBundleId {
            do {
                try cloudSavesPreferences.applyBeforeLaunch(choice, domain: domain)
            } catch {
                logs.append(LogEntry(level: .warning, message: L10n.format("Cloud saves: %@", [String(describing: error.localizedDescription)])))
                showSettingsNotice(title: L10n.text("Cloud unavailable"),
                                   message: L10n.text("Cloud sync could not be updated for this launch. Check Games → Cloud saves."))
            }
        }

        // Play can come straight from the row. Reconcile removed mod folders before the game reads its overlay.
        let store = modStore(for: game)
        if let store { _ = performModChange { try store.sync() } }

        Task { @MainActor in
            let appURL = game.url
            let supported = await InstalledEngineCapabilities.shared.supportsHomeMenu(in: appURL, engineFolder: setup.nxnativePath)
            let homeMenu = HomeMenu.environment(supported: supported, launcherBundleID: Bundle.main.bundleIdentifier)
            let online = environment[NextendoLaunch.clientIDKey] != nil
            let codeMods = await Task.detached(priority: .userInitiated) {
                store?.codeModsLaunchEnvironment(app: appURL, build: game.lastBuild, online: online) ?? [:]
            }.value
            let overrides = (gameSettings == nil ? config.toEnvironmentDict() : environment)
                .merging(homeMenu) { _, launcher in launcher }
                .merging(codeMods) { _, mods in mods }
            openGame(game, titleId: titleId, token: saveLaunchToken, environment: overrides)
        }
    }

    private func openGame(_ game: PortedGame, titleId: String, token saveLaunchToken: UUID,
                          environment: [String: String]) {
        launchService.launch(appURL: game.url, environment: environment) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.saveGate.end(titleID: titleId, token: saveLaunchToken)
                if success {
                    self.lastError = nil
                    self.playSessionStore?.start(for: game)
                    self.logs.append(LogEntry(level: .success, message: L10n.format("Launched game: %@", [String(describing: game.name)])))
                    self.watchLaunch(of: game)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if self.launchingGameId == game.id { self.launchingGameId = nil }
                    }
                } else {
                    let message = error ?? NXLibraryError.launchFailed(game.name).localizedDescription
                    self.launchingGameId = nil
                    self.launchOverlay = nil
                    self.lastError = message
                    self.alertMessage = message
                    SoundEffectService.shared.play(.error)
                    self.logs.append(LogEntry(level: .error, message: message))
                }
            }
        }
    }

    /// Marks the launch screen ready once the game shows a window, or after the probe times out.
    private func watchLaunch(of game: PortedGame) {
        launchProbeTask?.cancel()
        guard let bundleID = game.effectiveBundleId else {
            launchOverlay?.isReady = true
            return
        }
        launchProbeTask = Task { [weak self] in
            let visible = await LaunchReadinessProbe().waitUntilVisible(bundleID: bundleID)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.launchOverlay?.game.id == game.id else { return }
                if visible {
                    SoundEffectService.shared.play(.gameReady)
                } else {
                    self.logs.append(LogEntry(level: .warning,
                                              message: L10n.format("%@ showed no window within 60 s; launch screen closed.", [String(describing: game.name)])))
                }
                self.launchOverlay?.isReady = true
            }
        }
    }

    /// Called by the launch screen after its fade out.
    func dismissLaunchOverlay() {
        launchProbeTask?.cancel()
        launchProbeTask = nil
        launchOverlay = nil
    }
}
