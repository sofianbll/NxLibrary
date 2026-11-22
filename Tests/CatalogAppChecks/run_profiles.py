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
    @MainActor static func main() throws {
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
            try save(bitmap(face), to: url)
        }
        let cachedPortraits = ProfileEditorView.loadAvatars(avatarGames, artwork: art)
        precondition(cachedPortraits.count == avatarGames.count)
        try checkGIF(in: data)
        func picker(selected: UUID?, removing: LocalProfile? = nil, overlay: Bool = false) -> some View {
            ProfilePickerView(profiles: profiles, initialSelection: selected, initialEdit: false, canClose: overlay, isOverlay: overlay,
                              games: [game], onChoose: { _ in }, onClose: {}, onActiveEdited: {},
                              selected: selected, removing: removing)
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
                                   accountOnly: true, accountOffline: presence == .offline, appearOnline: .constant(true),
                                   advanced: .constant(false), onActions: { _ in }, nextendo: nextendo)
            }, in: out, refs, "screenshots/activity.png")
        }
        let router = AppRouter()
        router.menuSelection.selected = .switchProfile
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
        let after = stage(SpotlightTopBar(filter: .all, sort: current))
        try render("07-top-bar", after, in: out, refs, "screenshots/home.png")
        try render("09-menu", ZStack {
            stage(SpotlightTopBar(filter: .all, sort: current), showsSort: false)
            MenuOverlayView(router: router, cloudLibrary: vm.cloudLibrary, activeProfile: alex,
                            hasBuildActivity: false, onSelect: { _ in }, onSelectPower: { _ in })
        }, in: out, refs, "screenshots/menu.png")
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
        L10n.setContext(.init(language: .english, region: "US"))
        try render("11-remove", picker(selected: sam.id, removing: sam), in: out, refs, "web/182-15.png")
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
        vm.applyCatalog(.init(games: [fixture] + avatarGames))
        vm.spotlight.selectedKey = SpotlightItem.game(game.id).key
        vm.profileOwnsInput = true
        try render("20-picker-over-spotlight", ZStack {
            SeleneBackdrop().still(true)
            SpotlightView(viewModel: vm, router: AppRouter(), settings: settings, playSessions: historyStore,
                          runningGames: RunningGameMonitor(), artwork: art, storeHost: ModStoreHost())
            picker(selected: profiles.active?.id, overlay: true)
        }, in: out, refs, "web/reddit-showcase-who-05s.png")
        vm.profileOwnsInput = false
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
                               accountOnly: true, appearOnline: .constant(true), advanced: .constant(false),
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

    @MainActor static func fakeAccount(_ directory: URL) -> NextendoSettings {
        let store = NextendoTokenStore(directory: directory)
        let oauth = NextendoOAuth(store: store) { request in
            precondition(request.url?.path == "/api/avatar")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return NextendoSettings(store: store, service: .init(oauth: oauth))
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

    @MainActor static func render<V: View>(_ name: String, _ view: V, in out: URL, _ refs: URL, _ reference: String,
                                          reduced: Bool = true) throws {
        let size = CGSize(width: 1440, height: 810)
        let image = try bitmap(view
            .environment(\.seleneCanvas, SeleneCanvas(size: size))
            .environment(\.seleneReduceMotion, reduced)
            .environment(\.seleneButtonNames, .xbox)
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
        replace(app / "Views/Theme/SeleneBackdrop.swift",
                r"tint: modsTint \? 1 : 0, moving: moving,\n",
                "tint: modsTint ? 1 : 0, moving: false, asImage: true,\n")
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
