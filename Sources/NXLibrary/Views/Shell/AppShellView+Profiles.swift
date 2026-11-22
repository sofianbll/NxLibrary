import AppKit
import SwiftUI
import NXLibraryCore
import ArcanePorting

struct ProfileFlow {
    enum Page { case picker, editor, detail }
    var page: Page
    var selected: UUID?
    var atStartup = false
    var returnsToMenu = false
    var returnsToPortrait = false

    static func requestPicker() {
        NotificationCenter.default.post(name: .nxToggleProfilePicker, object: nil)
    }
}

extension EnvironmentValues {
    @Entry var profilePortrait: LocalProfile?
}

extension Notification.Name {
    static let nxProfileInput = Self("NXProfileInput")
    static let nxOpenLocalProfile = Self("NXOpenLocalProfile")
    static let nxToggleProfilePicker = Self("NXToggleProfilePicker")
}

extension AppShellView {
    var profileNextendo: NextendoSettings? {
        guard let active = profiles.active else { return nil }
        if active.id == profiles.originalID { return .shared }
        return additionalNextendo?.id == active.id ? additionalNextendo?.account : nil
    }

    @ViewBuilder var profilePresenceTask: some View {
        if let profile = profiles.active, let nextendo = profileNextendo {
            let clientID = settings.settings.nextendoClientID ?? NextendoLaunch.buildClientID
            let eligible = {
                profiles.active?.id == profile.id && profiles.active?.appearsOnline != false && !profiles.failed
                    && runningGames.runningGameIDs.isEmpty && !SteamPlayCoordinator.blocksIdlePresence(SteamPlayCoordinator.shared.states)
                    && viewModel.launchingGameId == nil && viewModel.launchOverlay == nil
                    && (settings.settings.nextendoClientID ?? NextendoLaunch.buildClientID) == clientID
            }
            NextendoPresenceTask(account: nextendo, clientID: !steamBlocksIdlePresence && eligible() ? clientID : nil,
                                 eligible: eligible)
                .id(profile.id)
        }
    }

    func updateProfileNextendo() {
        additionalNextendo = profiles.active.flatMap { profile in
            guard profile.id != profiles.originalID else { return nil }
            return (profile.id, NextendoSettings(store: NextendoLaunch.tokenStore(profileID: profile.id, originalID: profiles.originalID)))
        }
    }

    @ViewBuilder var profileLayer: some View {
        if let flow = profileFlow, let active = profiles.active {
            switch flow.page {
            case .picker, .editor:
                ProfilePickerView(profiles: profiles, initialSelection: flow.selected, initialEdit: flow.page == .editor,
                                  canClose: !flow.atStartup, isOverlay: !flow.atStartup, games: viewModel.libraryGames,
                                  avatarGames: viewModel.visibleCatalogGames, artwork: artwork,
                                  onChoose: chooseProfile, onClose: closeProfile,
                                  onActiveEdited: applyActiveProfile, onRemoved: { id in
                    if settings.settings.profileStartup == .profile(id) { settings.settings.profileStartup = .ask }
                })
            case .detail:
                if let nextendo = profileNextendo {
                    LocalProfilePage(profile: active, nextendo: nextendo, viewModel: viewModel,
                                     settings: settings, history: playSessions, onClose: closeProfile, onAppearOnline: { enabled in
                        guard var profile = profiles.active, profile.id == active.id else { return }
                        profile.appearsOnline = enabled ? nil : false
                        if !profiles.update(profile) {
                            viewModel.showSettingsNotice(title: L10n.text("Settings not saved"),
                                                         message: L10n.text("Your changes could not be saved. Try again."))
                        }
                    }) {
                        profileFlow?.page = .picker
                        profileFlow?.returnsToPortrait = true
                    }
                    .id(active.id)
                }
            }
        }
    }

    func openProfile(_ page: ProfileFlow.Page, fromMenu: Bool = false) {
        guard let active = profiles.active, profileFlow == nil, viewModel.launchOverlay == nil,
              !viewModel.showSetupCheck, !showsWelcome, !isCloseGameOpen else { return }
        viewModel.profileOwnsInput = true
        profileFlow = ProfileFlow(page: page, selected: active.id, returnsToMenu: fromMenu)
    }

    var launcherIsFrontmost: Bool {
        NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    func toggleProfilePicker() {
        guard launcherIsFrontmost, !nativeMenus.isTracking, !nativeDialogOwnsInput,
              !router.isScreenshotViewerOpen, !isCloseGameOpen else { return }
        if let profileFlow {
            if profileFlow.page == .picker, !profileFlow.atStartup { closeProfile() }
        } else {
            openProfile(.picker, fromMenu: router.isMenuPresented)
        }
    }

    func closeProfile() {
        if profileFlow?.returnsToPortrait == true {
            profileFlow?.page = .detail
            profileFlow?.returnsToPortrait = false
            return
        }
        profileFlow = nil
        viewModel.profileOwnsInput = false
    }

    func chooseProfile(_ id: UUID) {
        guard profiles.choose(id) else { return }
        applyActiveProfile()
        if profileFlow?.returnsToMenu == true { router.closeMenu() }
        profileFlow?.returnsToPortrait = false
        closeProfile()
    }

    func applyActiveProfile() {
        guard let profile = profiles.active else { return }
        let scopedID = profile.id == profiles.originalID ? nil : profile.id
        if playSessions.profileID != scopedID {
            playSessions.profileID = scopedID
            viewModel.refreshProfileFavorites()
        }
        if profile.look != .init(settings.settings) {
            profile.look.apply(to: &settings.settings)
        }
        ThemeStore.shared.apply(id: profile.look.theme)
    }

    func postProfileAction(_ action: GamepadAction) {
        NotificationCenter.default.post(name: .nxProfileInput, object: action)
    }

    func profileKey(_ event: NSEvent) -> NSEvent? {
        let key = event.charactersIgnoringModifiers?.lowercased()
        let typing = event.window?.firstResponder is NSText
        if typing && event.keyCode != 53 { return event }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
        let action: GamepadAction
        switch event.keyCode {
        case 123: action = .navigateLeft
        case 124: action = .navigateRight
        case 125: action = .navigateDown
        case 126: action = .navigateUp
        case 36, 49, 76: action = .confirm
        case 53: action = .cancel
        case 51: action = .secondaryAction
        case 12: action = .tabPrevious
        case 14: action = .tabNext
        case 48: action = event.modifierFlags.contains(.shift) ? .navigateLeft : .navigateRight
        default:
            switch key {
            case "x": action = .secondaryAction
            case "y": action = .contextAction
            case "+", "=": action = .menu
            default: return event
            }
        }
        if !event.isARepeat || [.navigateLeft, .navigateRight, .navigateUp, .navigateDown].contains(action) {
            postProfileAction(action)
        }
        return nil
    }
}

private struct NextendoPresenceTask: View {
    @ObservedObject var account: NextendoSettings
    let clientID: String?
    let eligible: () -> Bool

    private struct Key: Equatable {
        let clientID: String?
        let revision: UUID
    }

    var body: some View {
        Color.clear.accessibilityHidden(true).allowsHitTesting(false)
            .task(id: Key(clientID: account.isSigningOut ? nil : clientID, revision: account.presenceRevision)) {
                guard !Task.isCancelled else { return }
                account.clearPresence()
                if let clientID, !account.isSigningOut {
                    await account.publishPresence(clientID: clientID, eligible: eligible)
                }
            }
    }
}
