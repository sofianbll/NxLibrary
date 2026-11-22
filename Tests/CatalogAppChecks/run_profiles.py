#!/usr/bin/env python3
"""Render the real profile and sort views without windows, live data or sign-in."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]

HOST = r'''
import AppKit
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import NXLibraryCore
import ArcanePorting

@main struct ProfileScreenProbe {
    @MainActor static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let font = URL(fileURLWithPath: CommandLine.arguments[2])
        let refs = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        precondition(CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil))
        let data = AppData.supportRoot
        let settings = AppSettingsStore(fileURL: data.appendingPathComponent("settings.json"))
        settings.settings.nextendoClientID = "fixture-client"
        let profiles = LocalProfileStore(directory: data, settings: settings.settings, name: "Alex")
        let alex = profiles.active!
        let sam = LocalProfile(name: "Sam", avatar: 3, look: alex.look)
        let vm = AppViewModel(settingsStore: settings, catalog: .init(), repository: .init(store: .init(directory: data)))
        vm.localProfiles = profiles
        let game = PortedGame(name: "Lunar Observatory", url: data.appendingPathComponent("Fixture.app"),
                              platform: .macApp, sizeBytes: 0, modificationDate: .now, titleId: "0100000000001000")
        let slate = LocalProfile(name: "", look: alex.look)
        let avatarGames = (0..<7).map { index -> CatalogGame in
            var item = game
            item.id = UUID()
            item.name = "Observatory \(index + 1)"
            item.titleId = String(format: "010%013X", index + 1)
            return .init(nxnative: item)
        }
        let art = ArtworkStore(cacheDirectory: data.appendingPathComponent("avatar-fixtures"))
        for (index, game) in avatarGames.enumerated() {
            let url = art.cacheDirectory.appendingPathComponent(game.personalizationKey).appendingPathComponent("hero.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let hue = Double(index) / Double(avatarGames.count)
            let face = ZStack {
                LinearGradient(colors: [.init(hue: hue, saturation: 0.7, brightness: 0.8), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: ["person.crop.circle.fill", "theatermasks.fill", "sparkles", "moon.fill",
                                   "hare.fill", "bird.fill", "mountain.2.fill"][index])
                    .font(.system(size: 118)).foregroundStyle(.white.opacity(0.84))
            }.frame(width: 460, height: 300)
            let picture = try bitmap(face)
            try save(picture, to: url)
            // The tiles' own art cache: the row paints these illustrations (its async look-up never runs here).
            TileArtMemo.store(NSImage(cgImage: picture, size: .init(width: 460, height: 300)),
                              for: "nxnative|\(game.id)" as NSString)
        }
        TileArtMemo.store(TileArtMemo.shared.object(forKey: "nxnative|\(avatarGames[0].id)" as NSString)!,
                          for: "nxnative|\(game.id)" as NSString)
        let cachedPortraits = ProfileEditorView.loadAvatars(avatarGames, artwork: art)
        precondition(cachedPortraits.count == avatarGames.count)
        precondition(ProfilePortrait.symbols.count == LocalProfile.avatarCount)
        try checkGIF(in: data)
        func picker(selected: UUID?, removing: LocalProfile? = nil, editing: LocalProfile? = nil, overlay: Bool = false) -> some View {
            ProfilePickerView(profiles: profiles, initialSelection: selected, initialEdit: false, canClose: overlay, isOverlay: overlay,
                              games: [game], avatarGames: avatarGames, artwork: art, onChoose: { _ in }, onClose: {}, onActiveEdited: {},
                              onGuest: { _ in },
                              selected: selected, draft: editing, removing: removing)
        }
        try render("01-who", picker(selected: alex.id), in: out, refs, "web/reddit-showcase-who-05s.png", reduced: false)
        try render("02-add-focus", picker(selected: nil), in: out, refs, "web/182-10.png", reduced: false)
        for (step, ref) in [(ProfileEditorView.Step.name, "web/182-11.png"), (.avatar, "web/182-12.png"),
                            (.theme, "web/archive-theme-step.png"), (.background, "web/archive-background-step.png")] {
            try render("0\(step.rawValue + 3)-wizard-\(step)", ZStack {
                SeleneBackdrop().still(true)
                ProfileEditorView(profile: slate, games: [game], isNew: true, onCancel: {}, onSave: { _ in true }, step: step)
            }, in: out, refs, ref)
        }
        let french = AppLocale(language: .french, region: "FR")
        L10n.setContext(french)
        try render("04-wizard-avatar", ZStack {
            SeleneBackdrop().still(true)
            ProfileEditorView(profile: slate, games: [game], isNew: true, onCancel: {}, onSave: { _ in true },
                              step: .avatar, cachedPortraits: cachedPortraits)
        }.environment(\.nxAppLocale, french), in: out, refs, "web/182-12.png", reduced: false)
        L10n.setContext(.init(language: .english, region: "US"))
        let current = LibrarySort.recent
        let history = [ProfileRecentGame(id: game.id, name: game.name,
                       last: Date(timeIntervalSince1970: 1_791_014_400), duration: 9450)]
        for (name, presence) in [("connected", ProfilePresence.connected), ("offline", .offline), ("no-account", .notLinked),
                                 ("loading", .loading), ("unknown", .unknown), ("error", .failed), ("expired", .expired)] {
            let nextendo = fakeAccount(data.appendingPathComponent("fixture-account"))
            nextendo.setScreenFixture(presence)
            try render("08-profile-\(name)", ProfilePageLayout(profile: alex, presence: presence, games: history, onClose: {}) {
                SettingsAPISection(viewModel: vm, settings: settings, showsMultiplayer: true, supportsNextendo: true,
                                   accountOnly: true, accountOffline: presence == .offline,
                                   advanced: .constant(false), onActions: { _ in }, nextendo: nextendo)
            }, in: out, refs, "screenshots/activity.png")
        }
        let localHistory = PlaySessionStore(fileURL: data.appendingPathComponent("profile-page-history.json"))
        vm.localProfiles = nil
        precondition(vm.profileNextendo == nil)
        try render("08-profile-without-nextendo-real", LocalProfilePage(profile: alex, nextendo: nil, viewModel: vm,
                   settings: settings, history: localHistory, onClose: {}, onUpdate: { _ in true }, onSwitch: {}),
                   in: out, refs, "none")
        vm.localProfiles = profiles
        let linked = fakeAccount(data.appendingPathComponent("profile-page-account"))
        linked.setScreenFixture(.connected)
        try render("08-profile-linked-real", LocalProfilePage(profile: alex, nextendo: linked, viewModel: vm,
                   settings: settings, history: localHistory, onClose: {}, onUpdate: { _ in true }, onSwitch: {}),
                   in: out, refs, "none")
        let switchToSam = ProfileFlow.Change(target: sam, startsGuest: false, step: .confirm)
        precondition(switchToSam.requiresConfirmation(current: alex.id, running: true, endsGuest: false))
        precondition(!switchToSam.canCommit(current: alex.id, running: true))
        precondition(switchToSam.canCommit(current: alex.id, running: false))
        precondition(!switchToSam.requiresConfirmation(current: sam.id, running: true, endsGuest: false))
        precondition(switchToSam.requiresConfirmation(current: alex.id, running: false, endsGuest: true))
        for (name, starting, ending, running) in [("switch", false, false, true), ("guest-start", true, false, false),
                                                 ("guest-end", false, true, false)] {
            try render("32-\(name)", ZStack {
                picker(selected: alex.id).seleneOverlayOwnership(false)
                SeleneOverlay(style: .profileRemoval) {
                    ProfileSwitchDialog(startsGuest: starting, endsGuest: ending, hasGame: running, hasSteam: false,
                                        waiting: false, onCancel: {}, onConfirm: {})
                }
            }, in: out, refs, "none")
        }
        try render("33-profile-lock", ZStack {
            picker(selected: alex.id).seleneOverlayOwnership(false)
            SeleneOverlay(style: .profileRemoval) {
                ProfilePINDialog(title: "Unlock profile", onCancel: {}, onPIN: { _ in nil })
            }
        }, in: out, refs, "none")
        func stage<Bar: View>(_ top: Bar, showsSort: Bool = true, player: LocalProfile? = nil) -> some View {
            ZStack(alignment: .top) {
                SeleneBackdrop().still(true)
                top
                VStack {
                    Spacer()
                    CollectionCoverRow(games: player == nil ? [.init(nxnative: game)] : Array(avatarGames.prefix(4)),
                        selectedID: player == nil ? game.id : avatarGames[1].id,
                        artwork: ArtworkStore(), boxArt: vm.boxArt, boxArtIndexVersion: 0,
                        officialName: { _ in nil }, needsMetadata: { _ in }, cloud: vm.cloudLibrary,
                        showsCloudBadges: true, onSelect: { _ in }, onActivate: { _ in })
                    Spacer()
                }
                if showsSort {
                    SeleneHintsBar(left: HintItem.homeGlobals(other: "Spotlight", onOther: {}, onMenu: {}, onSearch: {}, onProfiles: {}),
                                   right: [LibrarySortMenu.hint(current, action: {})])
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .environment(\.profilePortrait, showsSort ? player ?? alex : nil)
            .environment(\.onlinePlayersByTitle, [game.titleId!.lowercased(): 12])
        }
        let online = fakeAccount(data.appendingPathComponent("fixture-online"))
        online.setPresenceFixture()
        let after = stage(SpotlightTopBar(filter: .all, sort: current, nextendo: online))
        try render("07-top-bar", after, in: out, refs, "screenshots/library.png")
        try checkTopBar(in: out, profile: alex, accent: Color(hex: SelenePaletteCatalog.resolve(alex.look.theme, in: ThemeStore.shared.palettes).glyph))
        func menu(_ name: String, _ prepare: (AppRouter) -> Void, lang: AppLocale? = nil, names: ButtonNameStyle = .xbox) throws {
            let router = AppRouter()
            router.isMenuPresented = true
            prepare(router)
            if let lang { L10n.setContext(lang) }
            try render(name, ZStack {
                stage(SpotlightTopBar(filter: .all, sort: current, nextendo: online), showsSort: false)
                MenuOverlayView(router: router, cloudLibrary: vm.cloudLibrary, activeProfile: alex,
                                hasBuildActivity: true, onSelect: { _ in }, onSelectPower: { _ in })
            }.environment(\.nxAppLocale, lang ?? .init(language: .english, region: "US")),
                       in: out, refs, "screenshots/menu.png", names: names)
            L10n.setContext(.init(language: .english, region: "US"))
        }
        let fr = AppLocale(language: .french, region: "FR")
        try menu("09-menu", { $0.menuSelection.selected = .profile })
        try menu("09-menu-profile-card", { $0.menuSelection.selected = .profile; $0.openEntryMenu(); $0.moveEntryMenu(by: 1) })
        try menu("09-menu-library-card", { $0.menuSelection.selected = .library; $0.openEntryMenu() })
        try menu("09-menu-activity", { $0.menuSelection.selected = .activityCenter })
        try menu("09-menu-settings", { $0.menuSelection.selected = .settings })
        try menu("09-menu-power", { $0.menuSelection.selected = .power; $0.openPowerMenu() })
        try menu("09-menu-profile-card-fr", { $0.menuSelection.selected = .profile; $0.openEntryMenu() }, lang: fr)
        try menu("09-menu-library-card-fr", { $0.menuSelection.selected = .library; $0.openEntryMenu(); $0.moveEntryMenu(by: 2) }, lang: fr)
        try checkMenuCards()
        // Each submenu over a real Details page: the page blurs under the heavier veil, the focus walks down the pills.
        let german = AppLocale(language: .german, region: "DE")
        let submenus: [(String, (AppRouter) -> Void)] = [
            ("profile", { $0.menuSelection.selected = .profile; $0.openEntryMenu() }),
            ("library", { $0.menuSelection.selected = .library; $0.openEntryMenu() }),
            ("power", { $0.menuSelection.selected = .power; $0.openPowerMenu() })]
        func details(blur: CGFloat) -> some View {
            ZStack {
                SeleneBackdrop().still(true).blur(radius: blur)
                GameDetailView(viewModel: vm, setup: vm.setup, store: vm.store, router: AppRouter(), settings: settings,
                               playSessions: PlaySessionStore(), runningGames: RunningGameMonitor(), artwork: art, game: game)
                    .blur(radius: blur)
            }
        }
        L10n.setContext(fr)
        try render("10-details-page", details(blur: 0).environment(\.nxAppLocale, fr), in: out, refs, "none")
        for (locale, tag) in [(fr, "fr"), (german, "de")] {
            for (submenu, open) in submenus {
                for downs in 1...2 {
                    let router = AppRouter()
                    router.isMenuPresented = true
                    open(router)
                    for _ in 0..<downs { router.menuStep(.down) }
                    L10n.setContext(locale)
                    try render("10-details-\(submenu)-\(tag)-\(downs + 1)", ZStack {
                        details(blur: AppShellView.profileOverlayBlur)
                        MenuOverlayView(router: router, cloudLibrary: vm.cloudLibrary, activeProfile: alex,
                                        hasBuildActivity: false, onSelect: { _ in }, onSelectPower: { _ in })
                    }.environment(\.nxAppLocale, locale), in: out, refs, "none")
                }
            }
        }
        L10n.setContext(.init(language: .english, region: "US"))
        // The same screens under each family's button names: Switch, PS5 and the keyboard (Automatic, no pad).
        for (suffix, names) in [("switch", ButtonNameStyle.nintendo), ("ps5", .playstation), ("keyboard", .automatic)] {
            try render("07-top-bar-\(suffix)", after, in: out, refs, "none", names: names)
            try menu("09-menu-\(suffix)", { $0.menuSelection.selected = .profile }, names: names)
        }
        try render("10-online-tile", after, in: out, refs, "screenshots/library.png")
        precondition(profiles.update(sam))
        L10n.setContext(french)
        let profileSection = SettingsProfilesSection(settings: settings, profiles: profiles, onActions: { _ in })
        for choice: ProfileStartup in [.last, .profile(alex.id), .profile(sam.id), .ask] {
            profileSection.cycle(1)
            precondition(settings.settings.profileStartup == choice)
        }
        profileSection.cycle(-1)
        precondition(settings.settings.profileStartup == .profile(sam.id))
        try render("19-profiles-at-startup", ZStack {
            SeleneBackdrop().still(true)
            SettingsView(initialSection: .profiles, viewModel: vm, settings: settings, router: AppRouter(), artwork: art)
        }.environment(\.nxAppLocale, french), in: out, refs, "screenshots/game-options.png")
        settings.settings.profileStartup = .ask
        for (name, section) in [("21-settings-console", SettingsSection.console), ("22-settings-setup", .engine)] {
            try render(name, ZStack {
                SeleneBackdrop().still(true)
                SettingsView(initialSection: section, viewModel: vm, settings: settings, router: AppRouter(), artwork: art)
            }.environment(\.nxAppLocale, french), in: out, refs, "screenshots/game-options.png")
        }
        L10n.setContext(.init(language: .english, region: "US"))
        try render("11-original-protected", picker(selected: alex.id), in: out, refs, "none")
        try render("11-remove", picker(selected: sam.id, removing: sam), in: out, refs, "web/182-15.png")
        // Y on a profile: the wizard replaces the selector, with one bar of hints; closing it brings the selector back.
        try render("21-picker-y-wizard", picker(selected: sam.id, editing: sam, overlay: true), in: out, refs,
                   "web/182-12.png")
        try render("22-picker-back", picker(selected: sam.id, overlay: true), in: out, refs, "web/reddit-showcase-who-05s.png")
        try render("16-switch-profile", picker(selected: sam.id), in: out, refs, "web/reddit-showcase-who-05s.png", reduced: false)
        try render("17-second-profile-collection", stage(SpotlightTopBar(filter: .recentlyPlayed, sort: current), player: sam),
                   in: out, refs, "screenshots/library.png")
        let historyStore = PlaySessionStore(fileURL: data.appendingPathComponent("fixture-history.json"))
        let firstGame = UUID(), secondGame = UUID()
        precondition(historyStore.start(gameID: firstGame, sourceID: "fixture"))
        precondition(profiles.choose(sam.id))
        historyStore.profileID = sam.id
        precondition(historyStore.lastPlayed(for: firstGame) == nil)
        precondition(historyStore.start(gameID: secondGame, sourceID: "fixture"))
        let native = CatalogGame(nxnative: game)
        var originalGame = native
        originalGame.setFavorite(true)
        vm.homeSeen = true
        var fixture = originalGame
        fixture.setFavorite(false)
        // Without an enabled source the library lists nothing: the screen would show an empty collection.
        vm.applyCatalog(.init(sources: [.init(integration: .nxnative, isEnabled: true)], games: [fixture] + avatarGames))
        vm.spotlight.selectedKey = SpotlightItem.game(game.id).key
        vm.profileOwnsInput = true
        try render("20-picker-over-spotlight", ZStack {
            // The shell blurs the screen under an overlaid picker by `profileOverlayBlur`.
            SeleneBackdrop().still(true).blur(radius: AppShellView.profileOverlayBlur)
            SpotlightView(viewModel: vm, router: AppRouter(), settings: settings, playSessions: historyStore,
                          runningGames: RunningGameMonitor(), artwork: art, storeHost: ModStoreHost())
                .blur(radius: AppShellView.profileOverlayBlur)
            picker(selected: profiles.active?.id, overlay: true)
        }, in: out, refs, "web/reddit-showcase-who-05s.png")
        vm.profileOwnsInput = false
        vm.librarySelection.query.filter = .notPlayed
        try render("23-spotlight-not-played", ZStack {
            SeleneBackdrop().still(true)
            SpotlightView(viewModel: vm, router: AppRouter(), settings: settings, playSessions: historyStore,
                          runningGames: RunningGameMonitor(), artwork: art, storeHost: ModStoreHost())
        }.environment(\.profilePortrait, profiles.active), in: out, refs, "screenshots/library.png")
        try save(bitmap(HStack(spacing: 12) {
            panel(NSImage(contentsOf: out.appendingPathComponent("09-menu-library-card-fr.png"))!, "Bibliothèque")
            panel(NSImage(contentsOf: out.appendingPathComponent("23-spotlight-not-played.png"))!, "Spotlight")
        }), to: out.appendingPathComponent("bibliotheque-spotlight.png"))
        try render("24-collection", ZStack {
            SeleneBackdrop().still(true)
            CollectionView(viewModel: vm, router: AppRouter(), settings: settings, playSessions: historyStore,
                           artwork: art)
        }, in: out, refs, "none")
        try render("25-search", ZStack {
            stage(SpotlightTopBar(filter: .all, sort: current), showsSort: false)
            FindGameView(router: AppRouter(), viewModel: vm, playSessions: historyStore, artwork: art)
        }, in: out, refs, "screenshots/find.png")
        try render("26-game-options", ZStack {
            details(blur: 10)
            GameOptionsView(viewModel: vm, game: game, origin: .details,
                            onClose: {}, onShowBuild: {}, onMove: {})
        }, in: out, refs, "screenshots/game-options.png")
        let pack = LocalAchievementPack.linksAwakening!
        var progress = LocalAchievementProgress()
        _ = progress.record([.seashells: 12, .heartPieces: 4], in: pack, at: Date(timeIntervalSince1970: 1_790_000_000))
        let achievements = pack.summary(progress, language: .french)
        var zelda = game
        zelda.name = "Link’s Awakening"
        zelda.url = data.appendingPathComponent("AchievementFixture.app")
        zelda.titleId = pack.titleID
        zelda.versionString = pack.gameVersion
        let achievementModel = AchievementsScreenModel(ids: achievements.rows(.all).map(\.id))
        func achievementScreen() -> some View {
            AchievementsScreen(model: achievementModel, game: .init(nxnative: zelda), summary: achievements,
                               art: nil, onFilter: { _ in }, onShiftFilter: { _ in }, onCycleOrder: {},
                               onFocus: { _ in }, onOpen: {}, onCloseDetail: {}, onClose: {})
        }
        L10n.setContext(fr)
        try render("27-local-achievements", achievementScreen(), in: out, refs, "none")
        _ = achievementModel.handle(.confirm, summary: achievements)
        try render("28-local-achievement-detail", achievementScreen(), in: out, refs, "none")
        try render("29-local-achievement-toast", ZStack(alignment: .topTrailing) {
            SeleneBackdrop().still(true)
            AchievementUnlockToast(names: achievements.rows(.unlocked).map(\.name)).padding(24)
        }, in: out, refs, "none")
        try render("29-local-achievement-card", ZStack {
            SeleneBackdrop().still(true)
            DetailsAchievementsCard(summary: achievements, appID: 0, focused: false, onOpen: {})
        }, in: out, refs, "none")
        let plist = zelda.url.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["DMTitleID": pack.titleID], format: .xml, options: 0)
            .write(to: plist)
        let scopedSave = try vm.profileSaveLocation(for: zelda, profileID: sam.id)
        let guest = LocalProfile(name: "Guest", look: alex.look)
        precondition(profiles.beginGuest(guest) && vm.profileNextendo == nil)
        let guestSave = try vm.defaultSaveLocation(for: zelda)
        let legacySave = try vm.legacySaveLocation(for: zelda)
        let guestEnvironment = try guestSave.profileLaunchEnvironment(shared: legacySave)
        precondition(guestSave != scopedSave && guestSave != legacySave && guestEnvironment["DM_SAVE_SYNC"] == "0")
        precondition(guestEnvironment["DM_SAVE"]?.contains(guest.id.uuidString) == true)
        precondition(profiles.choose(sam.id))
        let anotherGuest = LocalProfile(name: "Guest", look: alex.look)
        precondition(profiles.beginGuest(anotherGuest))
        let anotherSave = try vm.defaultSaveLocation(for: zelda)
        precondition(anotherSave != guestSave)
        precondition(profiles.choose(sam.id))
        let selectedSave = try vm.saveContext(for: zelda, launchProfileID: sam.id).location
        precondition(scopedSave == selectedSave)
        try render("30-profile-saves", ZStack {
            SeleneBackdrop().still(true)
            SavesPanel(viewModel: vm, game: zelda, onClose: {})
        }, in: out, refs, "none")
        try render("31-profile-saves-copy", ZStack {
            SeleneBackdrop().still(true)
            SavesPanel(viewModel: vm, game: zelda, onClose: {}, copyingFrom: [alex])
        }, in: out, refs, "none")
        precondition(profiles.choose(alex.id))
        let capturedSave = try vm.saveContext(for: zelda, launchProfileID: sam.id).location
        precondition(capturedSave == scopedSave, "Changing profiles must not reroute the launched game's achievements")
        precondition(profiles.choose(sam.id))
        try await checkQueuedBackup(vm, profiles: profiles, game: zelda, owner: sam)
        L10n.setContext(.init(language: .english, region: "US"))
        vm.librarySelection.query.filter = .all
        vm.applyCatalog(.init(games: [originalGame]))
        precondition(vm.catalogGames.first?.isFavorite == false)
        let revision = vm.catalogSnapshot.revision
        precondition(profiles.choose(alex.id))
        vm.refreshProfileFavorites()
        precondition(vm.catalogSnapshot.revision == revision && vm.catalogGames.first?.isFavorite == true)
        let accountDir = NextendoLaunch.tokenStore(profileID: sam.id, originalID: alex.id, root: data).directory
        precondition(accountDir != NextendoLaunch.tokenStore(profileID: alex.id, originalID: alex.id, root: data).directory)
        let samAccount = fakeAccount(accountDir)
        samAccount.setScreenFixture(.connected, second: true)
        L10n.setContext(french)
        try render("18-second-profile-nextendo", ProfilePageLayout(profile: sam, presence: .connected,
            games: [.init(id: secondGame, name: game.name, last: .now, duration: 123)], onClose: {}, onSwitch: {}) {
            SettingsAPISection(viewModel: vm, settings: settings, showsMultiplayer: true, supportsNextendo: true,
                               accountOnly: true, advanced: .constant(false),
                               onActions: { _ in }, nextendo: samAccount)
        }.environment(\.nxAppLocale, french), in: out, refs, "screenshots/activity.png")
        L10n.setContext(.init(language: .english, region: "US"))
        try render("12-sort-before", stage(BeforeSortTopBar(), showsSort: false), in: out, refs, "screenshots/library.png")
        try render("13-sort-after", after, in: out, refs, "screenshots/library.png")
        var focus: LibrarySort? = current
        LibrarySortMenu.handle(.navigateDown, focused: &focus) { _ in preconditionFailure() }
        precondition(focus == .name)
        try render("14-sort-menu", after.overlay {
            LibrarySortMenu(current: current, focused: focus!, choose: { _ in }, close: {})
        }, in: out, refs, "screenshots/library.png")
        var chosen: LibrarySort?
        LibrarySortMenu.handle(.confirm, focused: &focus) { chosen = $0 }
        precondition(focus == nil && chosen == .name)
        let beforeImage = out.appendingPathComponent("12-sort-before.png")
        let afterImage = out.appendingPathComponent("13-sort-after.png")
        try save(bitmap(HStack(spacing: 12) {
            panel(NSImage(contentsOf: beforeImage)!, "Arcane · avant")
            panel(NSImage(contentsOf: afterImage)!, "Arcane · après")
        }), to: out.appendingPathComponent("15-sort-avant-apres.png"))
    }

    @MainActor static func checkQueuedBackup(_ vm: AppViewModel, profiles: LocalProfileStore,
                                             game: PortedGame, owner: LocalProfile) async throws {
        var game = game
        game.bundleId = "example.arcane.backup-fixture"
        let other = LocalProfile(name: "Backup fixture", look: owner.look)
        precondition(profiles.update(other))
        let titleID = game.titleId!
        let store = SaveSnapshotStore(root: vm.saveBackupRoot)
        for (profile, marker) in [(owner, "MARKER-A"), (other, "MARKER-B")] {
            let location = try vm.profileSaveLocation(for: game, profileID: profile.id)
            let slot = location.directory(.account)
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: slot.appendingPathComponent("progress"))
        }
        let panel = SavePanelModel(viewModel: vm, game: game)
        let resume = DispatchSemaphore(value: 0)
        vm.saveQueue.async { resume.wait() }
        panel.backUp()
        precondition(profiles.choose(other.id))
        let otherStore = SaveSnapshotStore(root: vm.saveBackupRoot)
        resume.signal()

        let deadline = ContinuousClock.now + .seconds(5)
        while panel.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!panel.busy && panel.issue == nil, "The queued backup must complete")
        let snapshots = try store.list(titleID: titleID)
        precondition(snapshots.count == 1, "A's backup folder must contain exactly one snapshot")
        let directory = try store.directory(snapshotID: snapshots[0].id, titleID: titleID)
        let saved = try String(contentsOf: directory.appendingPathComponent("save/progress"), encoding: .utf8)
        precondition(saved == "MARKER-A", "A's queued backup must not publish B's save")
        let otherSnapshots = try otherStore.list(titleID: titleID)
        precondition(otherSnapshots.isEmpty, "A's queued backup must not publish into B's backups")
        precondition(profiles.choose(owner.id))
    }

    @MainActor static func fakeAccount(_ directory: URL) -> NextendoSettings {
        let store = NextendoTokenStore(directory: directory)
        let oauth = NextendoOAuth(store: store) { request in
            precondition(request.url?.path == "/api/avatar")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return NextendoSettings(store: store, service: .init(oauth: oauth))
    }

    /// The profile's portrait sits on the right beside the clock: its accent ring is in the right third of the
    /// bar and nowhere in the left third (no portrait, no filter chip).
    @MainActor static func checkTopBar(in out: URL, profile: LocalProfile, accent: Color) throws {
        let size = CGSize(width: 1440, height: 810)
        let bar = SpotlightTopBar(filter: .notPlayed, sort: .recent)
            .environment(\.profilePortrait, profile)
            .environment(\.seleneCanvas, SeleneCanvas(size: size))
            .environment(\.seleneReduceMotion, true)
            .frame(width: size.width, height: 110 * size.height / 1080 , alignment: .top)
            .background(Color.black)
        let image = try bitmap(bar)
        let rep = NSBitmapImageRep(cgImage: image)
        let ring = NSColor(accent).usingColorSpace(.deviceRGB)!
        var columns: [Int] = []
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(c.redComponent - ring.redComponent) < 0.08, abs(c.greenComponent - ring.greenComponent) < 0.08,
                   abs(c.blueComponent - ring.blueComponent) < 0.08 { columns.append(x); break }
            }
        }
        precondition(!columns.isEmpty, "the profile ring is not drawn")
        precondition(columns.allSatisfy { $0 > rep.pixelsWide * 2 / 3 }, "the profile ring is not on the right: \(columns.min()!)")
        // Nothing but black in the left third: no portrait and no filter chip under it.
        for x in 0..<rep.pixelsWide / 4 {
            for y in 0..<rep.pixelsHigh {
                let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                precondition(c.redComponent + c.greenComponent + c.blueComponent < 0.05, "something is drawn at the top left")
            }
        }
        try save(image, to: out.appendingPathComponent("07-top-bar-position.png"))
    }

    /// Every pill of an open card is as wide as the widest, in every language, with the same left edge. Measured on the
    /// pixels of the real card over black, with no pill focused (no glow, no scale).
    @MainActor static func checkMenuCards() throws {
        defer { L10n.setContext(.init(language: .english, region: "US")) }
        func lines(_ titles: [(String, MaterialIcon)], width: CGFloat) -> [MenuCard.Line] {
            titles.map { .init(id: $0.0, title: $0.0, icon: $0.1, width: width, focused: false, focus: {}, choose: {}) }
        }
        for language in AppLanguage.allCases where language != .automatic {
            let locale = AppLocale(language: language, region: "FR")
            L10n.setContext(locale)
            let cards = [MenuAction.profile, .library].map { lines($0.entries.map { ($0.title, $0.icon) }, width: 320) }
                + [lines(PowerAction.allCases.map { ($0.title, $0.icon) }, width: 240)]
            for card in cards {
                let size = CGSize(width: 1440, height: 810)
                let rep = NSBitmapImageRep(cgImage: try bitmap(MenuCard(lines: card).padding(40)
                    .environment(\.nxAppLocale, locale)
                    .environment(\.seleneCanvas, SeleneCanvas(size: size))
                    .environment(\.seleneReduceMotion, true)
                    .background(Color.black)))
                var bands: [(left: Int, right: Int)] = []
                var current: (left: Int, right: Int)?
                for y in 0..<rep.pixelsHigh {
                    var span: (Int, Int)?
                    for x in 0..<rep.pixelsWide {
                        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        if c.redComponent + c.greenComponent + c.blueComponent > 0.06 { span = (span?.0 ?? x, x) }
                    }
                    if let span {
                        current = (min(current?.left ?? span.0, span.0), max(current?.right ?? span.1, span.1))
                    } else if let finished = current {
                        bands.append(finished)
                        current = nil
                    }
                }
                if let current { bands.append(current) }
                let titles = card.map(\.title)
                precondition(bands.count == card.count, "\(language.rawValue): \(bands.count) pills drawn for \(titles)")
                let widths = bands.map { $0.right - $0.left + 1 }
                precondition(widths.max()! - widths.min()! <= 1, "\(language.rawValue): pill widths differ \(widths) for \(titles)")
                precondition(bands.map(\.left).max()! - bands.map(\.left).min()! <= 1, "\(language.rawValue): pills are not aligned")
            }
        }
    }

    @MainActor static func checkGIF(in root: URL) throws {
        let url = root.appendingPathComponent("fixture.gif")
        let out = root.appendingPathComponent("cropped.gif")
        let encoder = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        for color in [Color.red, .blue] {
            CGImageDestinationAddImage(encoder, try bitmap(color.frame(width: 100, height: 60)),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(encoder))
        let crop = ProfileAvatar.Crop(x: 1, y: 0, zoom: 2)
        precondition(crop.rectangle(width: 100, height: 60) == CGRect(x: 70, y: 0, width: 30, height: 30))
        let result = ProfileAvatar.render(url, crop: crop)!
        precondition(ProfileAvatar.isGIF(result))
        try result.write(to: out)
        let source = ProfileAvatar.source(out)!
        precondition(CGImageSourceGetCount(source) == 2)
        precondition(ProfileAvatar.thumbnail(source)?.width == 30)
        let values = CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any]
        let timing = values?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        precondition(timing?[kCGImagePropertyGIFDelayTime] as? Double == 0.2)
    }

    struct BeforeSortTopBar: View {
        @FocusState private var focused: Bool
        var body: some View {
            LegacySpotlightTopBar(filter: .all, sort: .recent, sortFocus: $focused, onCycleSort: {})
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    static let screenSize = CGSize(width: 1440, height: 810)

    @MainActor static func render<V: View>(_ name: String, _ view: V, in out: URL, _ refs: URL, _ reference: String,
                                          reduced: Bool = true, names: ButtonNameStyle = .xbox) throws {
        let size = screenSize
        let image = try bitmap(view
            .environment(\.seleneCanvas, SeleneCanvas(size: size))
            .environment(\.seleneReduceMotion, reduced)
            .environment(\.seleneButtonNames, names)
            .frame(width: size.width, height: size.height))
        try save(image, to: out.appendingPathComponent(name + ".png"))
        guard let ref = NSImage(contentsOf: refs.appendingPathComponent(reference)) else { return }
        let comparison = HStack(spacing: 12) {
            panel(NSImage(cgImage: image, size: size), "Arcane")
            if name == "20-picker-over-spotlight",
               let original = NSImage(contentsOf: out.appendingPathComponent("01-who.png")) {
                panel(original, "Arcane · 01-who")
            }
            if name == "04-wizard-avatar", reference == "web/182-12.png" {
                // The crop's adjacent portrait centres are 157px apart for Selene's 118-unit cells.
                panel(ref, "Selene · \(reference) · same scale", cropScale: 800 / 1920 * 118 / 157)
            } else {
                panel(ref, "Selene · \(reference)")
            }
        }
        try save(bitmap(comparison), to: out.appendingPathComponent(name + "-comparison.png"))
    }

    static func panel(_ image: NSImage, _ label: String, cropScale: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 16, weight: .semibold))
            if let cropScale, let pixels = image.representations.first {
                Image(nsImage: image).resizable()
                    .frame(width: CGFloat(pixels.pixelsWide) * cropScale, height: CGFloat(pixels.pixelsHigh) * cropScale)
                    .padding(.top, 38)
                    .frame(width: 800, height: 450, alignment: .top)
            } else {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 800, height: 450)
            }
        }
        .padding(10).foregroundStyle(.white).background(.black)
    }

    @MainActor static func bitmap<V: View>(_ view: V) throws -> CGImage {
        guard let image = ImageRenderer(content: view).cgImage else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    static func save(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
'''


def replace(file, old, new):
    original = file.read_text()
    text, count = re.subn(old, new if callable(new) else lambda _: new, original, count=1, flags=re.S)
    assert count == 1, (file, old)
    file.write_text(text)


def main():
    work = ROOT / "work"
    work.mkdir(exist_ok=True)
    out = (Path(sys.argv[1]) if len(sys.argv) > 1 else work / "screens-profiles").resolve()
    refs = (Path(sys.argv[2]) if len(sys.argv) > 2 else out / "no-reference").resolve()
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="profile-screens-", dir=work) as temp:
        package = Path(temp)
        shutil.copytree(ROOT / "Sources", package / "Sources")
        shutil.copyfile(ROOT / "Package.swift", package / "Package.swift")
        replace(package / "Package.swift", r'\.executable\(name: "NXLibrary",', '.executable(name: "ProfileScreenProbe",')
        for target in ("NXLibraryCoreTests", "ArcanePortingTests"):
            stub = package / "Tests" / target
            stub.mkdir(parents=True)
            (stub / "Empty.swift").touch()
        app = package / "Sources/NXLibrary"
        replace(app / "NXLibraryApp.swift", r"@main\nstruct", "struct")
        replace(app / "ViewModels/AppViewModel.swift", r"SteamGridDBKey\(\)\.load\(\) != nil", "false")
        replace(app / "ViewModels/AppViewModel.swift", r"        applyCatalog\(catalog\).*?\n    }\n\n    // MARK: - Dynamic",
                "    }\n\n    // MARK: - Dynamic")
        replace(package / "Sources/NXLibraryCore/App/AppDataProfile.swift",
                r'public static let profile = [^\n]*',
                f'public static let profile = AppDataProfile(home: URL(fileURLWithPath: "{temp}"), isDevelopment: true)')
        replace(package / "Sources/NXLibraryCore/App/AppDataProfile.swift",
                r'public static var preferences: UserDefaults \{ \.standard \}',
                f'public static let preferences = UserDefaults(suiteName: "local.arcane.{package.name}")!')
        replace(app / "Views/Shell/MenuOverlayView.swift", r"var presented = false", "var presented = true")
        replace(app / "Views/Theme/ThemeStore.swift", r"static let shared = ThemeStore\(\)",
                f'static let shared = ThemeStore(palettesURL: URL(fileURLWithPath: "{ROOT}/Resources/Selene/palettes.json"))')
        replace(app / "Views/Search/FindGameView.swift",
                r'TextField\(L10n.text\("Find a game"\), text: \$query\).*?\.onSubmit \{ pick\(results.first\) \}',
                'Text(query.isEmpty ? L10n.text("Find a game") : query).seleneFont(19)'
                '.foregroundColor(SeleneTheme.ink).frame(maxWidth: .infinity, alignment: .leading)')
        replace(app / "Views/Search/FindGameView.swift", r'var query = ""', 'var query = "Observatory"')
        options = app / "Views/GameOptions/GameOptionsView+Rows.swift"
        replace(options, r'            ScrollViewReader \{ proxy in\n                ScrollView \{\n', '')
        replace(options, r'                }\n                \.scrollIndicators\(\.hidden\).*?\n            }\n            \.id\(level\)\n', '')
        replace(options, r'let entries = p\.entries\(level: level, origin: origin\)', r'let entries = p.entries(level: level, origin: origin).prefix(8)')
        saves = app / "Views/GameOptions/SavesPanel.swift"
        replace(saves, r"onClose: @escaping \(\) -> Void\) \{",
                "onClose: @escaping () -> Void, copyingFrom: [LocalProfile] = []) {\n"
                "        _copyFrom = State(initialValue: copyingFrom)")
        # The two snapshots share a game fixture; neither needs the live save lease or key monitor.
        replace(saves, r"\n        \.onAppear \{ model.refresh\(\); installKeyMonitor\(\) \}", "")
        replace(saves, r"ProgressView\(\)\.controlSize\(\.small\)\.tint\(SeleneTheme.ink60\)", "Color.clear")
        replace(saves,
                r"        ScrollViewReader \{ proxy in\n            ScrollView \{(.*?)\n            }\.scrollIndicators\(\.hidden\).*?\n        }\n    }\n    private var statusLine",
                lambda m: "        Group {" + m[1] + "\n        }\n    }\n    private var statusLine")
        replace(app / "Views/Theme/SeleneBackdrop.swift",
                r"tint: modsTint \? 1 : 0, moving: moving,\n",
                "tint: modsTint ? 1 : 0, moving: false, asImage: true,\n")
        # ImageRenderer paints any AppKit-backed view as a full-screen yellow "no entry" placeholder: the game-art
        # layer is one. Arcane itself shows the Selene backdrop there when a game has no art.
        replace(app / "Views/Spotlight/SeleneArtBackground.swift",
                r"            SeleneArtLayer\(image: art,[^\n]*\n",
                "            if let art { Image(nsImage: art).resizable().scaledToFill() }\n")
        replace(app / "Views/Theme/MoonlightRenderer.swift", r"                if let image \{\n                    Image\(decorative:",
                "                if let image = engine.snapshot(width: max(w, 1), height: max(h, 1), colors: colors) {\n                    Image(decorative:")
        # ImageRenderer does not rasterize AppKit scroll views or fields. Render their real SwiftUI contents.
        # Real Settings views, with only the AppKit-backed scroll containers flattened.
        replace(app / "Views/Settings/SettingsView.swift",
                r"        ScrollViewReader \{ proxy in\n            ScrollView \{(.*?)\n            }\n            \.scrollIndicators\(\.hidden\).*?\n        }\n    }\n\n    private var reduceMotion",
                lambda m: "        Group {" + m[1] + "\n        }\n    }\n\n    private var reduceMotion")
        replace(app / "Views/Settings/SettingsSidebar.swift", r"            ScrollViewReader \{ proxy in\n.*?\n            }",
                "            GeometryReader { _ in groups }.clipped()")
        replace(app / "Views/Shell/ProfilePickerView.swift",
                r"                ScrollViewReader .*?\n                        (HStack\(spacing: canvas.u\(56\)\).*?)\n                    }\n                    \.scrollIndicators.*?\n                }\n                if profiles.failed",
                lambda m: "                " + m[1] + "\n                if profiles.failed")
        # The wizard opens on the avatar step, with the game portraits the real flow loads in a task.
        replace(app / "Views/Shell/ProfilePickerView.swift", r"onSave: save\)",
                "onSave: save, step: .avatar, cachedPortraits: ProfileEditorView.loadAvatars(avatarGames, artwork: artwork!))")
        editor = app / "Views/Shell/ProfileEditorView.swift"
        replace(editor, r'TextField\(L10n.text\("Name"\), text: \$profile.name\)\n                \.textFieldStyle\(\.plain\)',
                'Text(verbatim: profile.name)')
        replace(editor, r'\n                \.focused\(\$nameFocused\)\n                \.onSubmit\(advance\)', '')
        replace(editor, r'            ScrollViewReader \{ scroll in\n                ScrollView \{(.*?)\n                }\n                \.scrollIndicators\(\.hidden\)(.*?)\n                \.onChange\(of: index\).*?\n            }',
                lambda m: f"            Group {{{m[1]}\n            }}{m[2]}")
        page = app / "Views/Shell/LocalProfilePage.swift"
        replace(page, r'            ScrollViewReader \{ proxy in\n                ScrollView \{', '            Group {\n                Group {')
        replace(page, r'                \.onChange\(of: row\) \{ _, value in\n.*?\n                }', '')
        replace(page, r"\.padding\(\.bottom, canvas.u\(134\)\)", ".padding(.bottom, canvas.u(70))")
        api = app / "Views/Settings/SettingsAPISection.swift"
        replace(api, r"            if supportsNextendo \{ nextendo.check\(clientID: clientID\) \}", "")
        replace(api, r"@State private var friendsExpanded = false",
                "@State private var friendsExpanded = true")
        replace(api, r'            TextField\(text\("Friend code"\).*?\n                \.onSubmit\(sendFriendCode\)',
                '            Text(verbatim: "SW-0000-0000-0000")')
        with (package / "Sources/ArcanePorting/Launch/NextendoAccountService.swift").open("a") as swift:
            swift.write(r'''
extension NextendoAccountSnapshot {
    package static func screenFixture(second: Bool) -> Self {
        .init(name: second ? "Solar Pilot" : "Lunar Pilot", username: second ? "fixture2" : "fixture", countryCode: nil, friendCode: nil, avatar: nil,
              avatarPID: nil, friends: [
                  .init(id: 1, name: "Sol", favorite: false, presence: .online, game: nil, gameID: nil),
                  .init(id: 2, name: "Nova", favorite: false, presence: .playing, game: "Pokémon Legends: Z-A", gameID: nil)
              ],
              requests: [], sent: [], recentPlayers: [], failure: nil)
    }
}
''')
        with (app / "ViewModels/NextendoSettings.swift").open("a") as swift:
            swift.write(r'''
extension NextendoSettings {
    func setPresenceFixture() { presenceShared = true }
    func setScreenFixture(_ presence: ProfilePresence, second: Bool = false) {
        switch presence {
        case .connected:
            status = .signedIn; account = .screenFixture(second: second); accountName = account?.name
            friendsUpdatedAt = .now.addingTimeInterval(-30)
        case .offline: status = .unavailable
        case .loading: isBusy = true
        case .expired: status = .expired
        case .failed: status = .unavailable; failure = .service
        default: break
        }
    }
}
''')
        before = subprocess.run(
            ["git", "show", "adad00f:Sources/NXLibrary/Views/Spotlight/SpotlightTopBar.swift"],
            cwd=ROOT, text=True, capture_output=True)
        host = HOST
        if before.returncode == 0:
            (app / "LegacySpotlightTopBar.swift").write_text(
                before.stdout.replace("struct SpotlightTopBar:", "struct LegacySpotlightTopBar:"))
        else:
            # A shallow checkout still verifies current screens; only the historical panel needs this commit.
            host = re.sub(r'        try render\("12-sort-before"[^\n]+\n', "", host)
            host = re.sub(r'        let beforeImage = .*?(?=\n    })', "", host, flags=re.S)
            host = re.sub(r'    struct BeforeSortTopBar: View \{.*?\n    }\n', "", host, flags=re.S)
        (app / "ProfileScreenProbe.swift").write_text(host)
        subprocess.run(["swift", "run", "--package-path", str(package), "ProfileScreenProbe", str(out),
                        str(ROOT / "Resources/Selene/Fonts/MaterialIcons-Regular.ttf"), str(refs)],
                       check=True, env=dict(os.environ, HOME=temp))


if __name__ == "__main__":
    main()
