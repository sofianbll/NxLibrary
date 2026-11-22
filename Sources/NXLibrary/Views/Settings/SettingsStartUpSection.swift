import SwiftUI
import NXLibraryCore

struct SettingsStartUpSection: View {
    @ObservedObject var settings: AppSettingsStore
    let onActions: ([SettingsRowAction]) -> Void
    let onChooseLanguage: () -> Void
    let onChooseRegion: () -> Void
    @Environment(\.seleneCanvas) private var canvas

    private var startOnTitle: String {
        switch settings.settings.startOn {
        case .spotlight: return "Spotlight"
        case .collection: return "Collection"
        case .last: return L10n.text("Where I left")
        }
    }

    var body: some View {
        VStack(spacing: canvas.u(8)) {
            SettingsSubheading(L10n.text("Language & region"))
            SeleneButtonRow("App language",
                            subtitle: "Menus, genres and available game descriptions. The games’ own language stays separate.",
                            buttonTitle: settings.settings.appLanguage.nativeName, action: onChooseLanguage)
            SeleneButtonRow("Regional formats", id: "Region",
                            subtitle: "Dates, numbers and sizes only. Game descriptions follow the app language.",
                            buttonTitle: settings.settings.appRegion.flatMap {
                                L10n.context.formatLocale.localizedString(forRegionCode: $0)
                            } ?? L10n.text("Automatic (Mac)"), action: onChooseRegion)

            SeleneCycleRow("Start on",
                           subtitle: "The screen Arcane opens on.",
                           value: startOnTitle) { step in
                settings.settings.startOn = settings.settings.startOn.stepped(step)
            }

            SeleneToggleRow("Restore last selected game",
                            subtitle: "Reopen the game that was selected when you quit.",
                            isOn: $settings.settings.restoreLastGame)

            SeleneToggleRow("Start in fullscreen",
                            subtitle: "Applies at the next launch.",
                            isOn: $settings.settings.startInFullscreen)

            SeleneToggleRow("Check for app updates",
                            subtitle: "Look for a newer Arcane release at launch, at most once a day.",
                            isOn: $settings.settings.checkAppUpdatesAtLaunch)

            SeleneToggleRow("Entrance animation",
                            subtitle: "The library's tiles fly in with the boot sound when the app opens.",
                            isOn: $settings.settings.introAnimation)
        }
        .onAppear(perform: publishActions)
        .onChange(of: settings.settings.appLanguage) { publishActions() }
        .onChange(of: settings.settings.appRegion) { publishActions() }
    }

    private func publishActions() {
        onActions([
            .init(id: "appLanguage", title: "App language", activate: onChooseLanguage),
            .init(id: "appRegion", title: L10n.text("Regional formats"), rowID: "Region", activate: onChooseRegion),
            .value("startOn", "Start on") { step in
                settings.settings.startOn = settings.settings.startOn.stepped(step)
            },
            .init(id: "restore", title: "Restore last selected game") {
                settings.settings.restoreLastGame.toggle()
            },
            .init(id: "startupFullscreen", title: "Start in fullscreen") {
                settings.settings.startInFullscreen.toggle()
            },
            .init(id: "appUpdates", title: "Check for app updates") {
                settings.settings.checkAppUpdatesAtLaunch.toggle()
            },
            .init(id: "intro", title: "Entrance animation") {
                settings.settings.introAnimation.toggle()
            }
        ])
    }
}

struct SettingsProfilesSection: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var profiles: LocalProfileStore
    let onActions: ([SettingsRowAction]) -> Void
    @Environment(\.nxAppLocale) private var localization

    private var value: String {
        switch settings.settings.profileStartup.available(in: profiles.profiles) {
        case .ask: return L10n.text("Who's playing?", context: localization)
        case .last: return L10n.text("Last profile", context: localization)
        case .profile(let id): return profiles.profiles.first { $0.id == id }?.name ?? ""
        }
    }

    var body: some View {
        SeleneCycleRow("At startup", subtitle: "Choose who plays when Arcane opens.", value: value,
                       verbatimValue: true, cycle: cycle)
            .onAppear { onActions([.value("showProfilePicker", "At startup", cycle: cycle)]) }
    }

    func cycle(_ step: Int) {
        let choices: [ProfileStartup] = [.ask, .last] + profiles.profiles.map { .profile($0.id) }
        let current = settings.settings.profileStartup.available(in: profiles.profiles)
        settings.settings.profileStartup = choices.stepped(from: current, step) ?? .ask
    }
}
