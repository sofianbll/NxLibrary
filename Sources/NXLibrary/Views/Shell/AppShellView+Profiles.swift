import AppKit
import SwiftUI
import NXLibraryCore

struct ProfileFlow {
    enum Page { case picker, editor, detail }
    var page: Page
    var selected: UUID?
    var atStartup = false
    var returnsToMenu = false
    var returnsToPortrait = false
}

extension EnvironmentValues {
    @Entry var profilePortrait: LocalProfile?
}

extension Notification.Name {
    static let nxProfileInput = Self("NXProfileInput")
    static let nxOpenLocalProfile = Self("NXOpenLocalProfile")
}

extension AppShellView {
    @ViewBuilder var profileLayer: some View {
        if let flow = profileFlow, let active = profiles.active {
            switch flow.page {
            case .picker, .editor:
                ProfilePickerView(profiles: profiles, initialSelection: flow.selected, initialEdit: flow.page == .editor,
                                  canClose: !flow.atStartup, games: viewModel.libraryGames,
                                  avatarGames: viewModel.visibleCatalogGames, artwork: artwork,
                                  onChoose: chooseProfile, onClose: closeProfile,
                                  onActiveEdited: applyActiveProfile)
            case .detail:
                LocalProfilePage(profile: active, originalID: profiles.originalID, viewModel: viewModel,
                                 settings: settings, history: playSessions, onClose: closeProfile) {
                    profileFlow?.page = .picker
                    profileFlow?.returnsToPortrait = true
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

    func closeProfile() {
        if profileFlow?.returnsToPortrait == true {
            profileFlow?.page = .detail
            profileFlow?.returnsToPortrait = false
            return
        }
        let returnToMenu = profileFlow?.returnsToMenu == true
        profileFlow = nil
        viewModel.profileOwnsInput = false
        if !returnToMenu {
            router.closeMenu()
        }
    }

    func chooseProfile(_ id: UUID) {
        guard profiles.choose(id) else { return }
        applyActiveProfile()
        profileFlow?.returnsToMenu = false
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
