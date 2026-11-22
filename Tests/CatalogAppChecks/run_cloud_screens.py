#!/usr/bin/env python3
"""Render cloud and multiplayer views offscreen with synthetic states; never start the launcher."""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

HOST = r'''
import AppKit
import CoreText
import SwiftUI
import NXLibraryCore
import ArcanePorting

@main struct CloudScreenProbe {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let font = URL(fileURLWithPath: CommandLine.arguments[2])
        precondition(CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil))
        NSApplication.shared.applicationIconImage = NSImage(contentsOfFile: CommandLine.arguments[3])
        let data = AppData.supportRoot
        let settings = AppSettingsStore(fileURL: data.appendingPathComponent("settings.json"))
        let vm = AppViewModel(settingsStore: settings, catalog: .init(), repository: .init(store: .init(directory: data)))
        let model = vm.cloudLibrary
        let game = PortedGame(name: "Lunar Observatory", url: data.appendingPathComponent("Fixture.app"),
                              platform: .macApp, sizeBytes: 0, modificationDate: .now, titleId: "0100000000001000")
        model.update(game.id) {
            $0.copies = [.app: .screenFixture(.cloudOnly), .cache: .screenFixture(.synchronized)]
        }
        // CONNECTION_FIXTURE
        try render("panel", output, CloudLibraryPanel(viewModel: vm, model: model, game: game))
        for (name, locale) in [("rebuild", AppLocale(language: .french, region: "FR")),
                               ("rebuild-de", AppLocale(language: .german, region: "DE"))] {
            L10n.setContext(locale)
            vm.screenRebuildNotice()
            let notice = vm.settingsNotice!
            precondition(notice.choices == ["Download the cloud cache", "Rebuild with this Mac’s cache", "Rebuild without cache", "Cancel"])
            precondition(vm.settingsNoticeFocus == 0 && notice.cancelIndex == 3)
            try renderNotice(name, output, notice, width: 1440)
        }
        L10n.setContext(.init(language: .english, region: "US"))
        vm.settingsNotice = nil
        try render("settings", output, SettingsCloudLibrarySection(
            viewModel: vm, model: model, settings: settings, advanced: .constant(false),
            onEdit: {}, onEditSources: {}, onActions: { _ in })
            .padding(24).frame(width: 1040))
        let assistant = CloudSetupAssistant(viewModel: vm, model: model /* ENTRY */) {}
        // ASSISTANT_CHECK
        try render("assistant", output, assistant)
        precondition(CloudLibraryTileBadge.artworkOpacity(model.states[game.id]) == 0.55)
        try render("tile", output,
            CollectionCoverRow(games: [.init(nxnative: game)], selectedID: game.id,
                artwork: ArtworkStore(), boxArt: vm.boxArt, boxArtIndexVersion: 0,
                officialName: { _ in nil }, needsMetadata: { _ in }, cloud: model,
                showsCloudBadges: true, onSelect: { _ in }, onActivate: { _ in }),
            size: .init(width: 400, height: 440))
        let queuedRequest = CloudLibraryModel.Request(id: game.id, name: game.name, action: .restore(.app),
            storage: model.preference.storage, scope: .init(title: game.titleId!, urls: []),
            importDestination: nil, sourceFiles: nil, onSuccess: nil)
        let addGame = AddGameView(viewModel: vm, router: AppRouter())
        func adoptionRow() -> AddGameRow { addGame.rows(for: 1).first { $0.id == "adoptApp" }! }
        precondition(adoptionRow().enabled)
        vm.isBuilding = true
        precondition(!adoptionRow().enabled && adoptionRow().about == L10n.text("Available after the active build finishes or is cancelled."))
        vm.isBuilding = false
        let activity = ActivityCenterView(viewModel: vm, porting: vm.porting, cloudLibrary: model, focus: .init(),
            onFocus: { _ in }, onOpen: { _ in }, onCancel: { _ in }, onClose: {})
        precondition(ActivityCenterView.rows(vm).isEmpty)
        try render("activity-empty", output, activity)
        model.queue = [queuedRequest]
        precondition(!adoptionRow().enabled && adoptionRow().about == L10n.text("Available after the cloud transfers."))
        model.update(game.id) { $0.action = queuedRequest.action; $0.queued = true }
        try render("panel-queued", output, CloudLibraryPanel(viewModel: vm, model: model, game: game))
        let activeGame = PortedGame(name: "Solar Observatory", url: data.appendingPathComponent("Active.app"),
                                  platform: .macApp, sizeBytes: 0, modificationDate: .now, titleId: "0100000000002000")
        let request = CloudLibraryModel.Request(id: activeGame.id, name: activeGame.name, action: .restore(.app),
            storage: model.preference.storage, scope: .init(title: activeGame.titleId!, urls: []),
            importDestination: nil, sourceFiles: nil, onSuccess: nil)
        model.active = (request, Task {})
        model.update(activeGame.id) {
            $0.action = request.action
            $0.progress = .init(.downloading, kind: .app, transfer: .init(bytesTransferred: 42_000_000, totalBytes: 100_000_000))
        }
        try render("activity", output, activity)
        try render("tile-progress", output,
            CollectionCoverRow(games: [.init(nxnative: activeGame)], selectedID: activeGame.id,
                artwork: ArtworkStore(), boxArt: vm.boxArt, boxArtIndexVersion: 0,
                officialName: { _ in nil }, needsMetadata: { _ in }, cloud: model,
                showsCloudBadges: true, onSelect: { _ in }, onActivate: { _ in }),
            size: .init(width: 400, height: 440))
        // DOWNLOAD_FILL_CHECK
        // TYPED_PATH_CHECK
        // MULTIPLAYER_CHECK
    }

    @MainActor static func renderNotice(_ name: String, _ output: URL, _ notice: SettingsNotice, width: CGFloat) throws {
        try render(name, output, SeleneChoiceDialog(title: notice.title, message: notice.message,
            choices: notice.choices, focus: .constant(notice.initialFocus), /* NOTICE_LAYOUT */
            details: notice.choiceDetails, onChoose: { _ in }).environment(\.nxAppLocale, L10n.context),
            size: .init(width: width, height: 620))
    }

    @MainActor static func render<V: View>(_ name: String, _ output: URL, _ view: V,
                                          size: CGSize = .init(width: 1280, height: 1000)) throws {
        let canvas = SeleneCanvas(size: .init(width: 1920, height: 1080))
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .background(Color(red: 0.09, green: 0.13, blue: 0.20))
            .environment(\.colorScheme, .dark)
            .environment(\.seleneCanvas, canvas)
            .environment(\.seleneReduceMotion, true))
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
}
'''

DOWNLOAD_FILL = r'''
        let fr = AppLocale(language: .french, region: "FR")
        model.active = nil
        model.queue = []
        func checkDownloadFill(_ expected: Double?) {
            let state = model.states[game.id]!
            precondition(CloudLibraryProgressView.downloadFill(state, item: .app) == expected)
            precondition(CloudLibraryProgressView.downloadFill(state, item: .cache) == nil)
        }
        model.update(game.id) { $0.action = nil; $0.queued = false; $0.progress = nil }
        checkDownloadFill(nil)
        try render("panel-download-idle", output,
            CloudLibraryPanel(viewModel: vm, model: model, game: game).environment(\.nxAppLocale, fr))
        for percent in [0, 40, 100, nil] as [Int?] {
            model.update(game.id) {
                $0.action = .restore(.app)
                $0.progress = .init(.downloading, kind: .app,
                    transfer: percent.map { .init(bytesTransferred: Int64($0) * 1_000_000, totalBytes: 100_000_000) })
            }
            checkDownloadFill(percent.map { Double($0) / 100 })
            let suffix = percent.map(String.init) ?? "unknown"
            if percent == 40 {
                let progress = model.states[game.id]?.progress
                let english = AppLocale(language: .english, region: "US")
                precondition(CloudLibraryProgressView.bytesSummary(progress, context: english) == "40 MB of 100 MB")
                precondition(CloudLibraryProgressView.downloadSummary(progress, context: english) ==
                             "Downloading app · 40 MB of 100 MB")
            }
            try render("panel-download-\(suffix)", output,
                CloudLibraryPanel(viewModel: vm, model: model, game: game).environment(\.nxAppLocale, fr))
            try render("spotlight-download-\(suffix)", output,
                SpotlightGameInfoView(game: game, logo: nil,
                    presentation: .init(game: game, metadata: nil, totalPlaytime: 0, lastPlayed: nil),
                    isRunning: false, focusedPill: 0, onPill: { _ in }, onHoverPill: { _ in },
                    cloud: model, showsCloudPill: true, downloadsApp: true, downloadEnabled: true)
                    .environment(\.nxAppLocale, fr),
                size: .init(width: 1120, height: 460))
            try render("details-download-\(suffix)", output,
                DetailsTopBlock(game: game, logo: nil,
                    presentation: .init(game: game, metadata: nil, totalPlaytime: 0, lastPlayed: nil),
                    isRunning: false, focusedPill: 0, primaryEnabled: true, expanded: .constant(false),
                    onPrimary: {}, onSecondary: {}, onFavorite: {}, onHoverPill: { _ in }, pillSet: .normal,
                    cloud: model, showsCloudPill: true, downloadEnabled: true)
                    .environment(\.nxAppLocale, fr),
                size: .init(width: 1120, height: 460))
        }
        model.update(game.id) { $0.progress = .init(.verifying, kind: .app, downloadComplete: true) }
        checkDownloadFill(1)
        precondition(CloudLibraryProgressView.fraction(model.states[game.id]?.progress) == nil)
        model.update(game.id) { $0.queued = true }
        checkDownloadFill(nil)
'''

MULTIPLAYER = r'''
        let frLocale = AppLocale(language: .french, region: "FR")
        L10n.setContext(frLocale)
        let dm = game.url.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.arcane.screen-multiplayer", "DMSettings": []]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: game.url.appendingPathComponent("Contents/Info.plist"))
        try Data("""
            {"schema":1,"game":"0100000000001000","settings":[
             {"env":"DM_NETWORK","kind":"choice","section":"Game","label":"Network","default":"offline",
              "options":[["offline","Offline"],["ldn","Local communication"],["lan","LAN mode"],["auto","Automatic"],["nextendo","Online (Nextendo)"]]},
             {"env":"DM_NET_VPN","kind":"toggle","section":"Game","label":"Play over a VPN","default":"0","on":"1","off":"0"}]}
            """.utf8).write(to: dm.appendingPathComponent("launcher.json"))
        // MULTIPLAYER_STATES
'''

MULTIPLAYER_STATES = r'''
        settings.settings.multiplayerVPN = .zeroTier
        settings.settings.multiplayerDefault = .local
        func settingsPage() -> some View {
            SettingsView(initialSection: .multiplayer, viewModel: vm, settings: settings,
                         router: AppRouter(), artwork: ArtworkStore())
                .environment(\.nxAppLocale, frLocale)
        }
        ScreenVPN.connected = true
        try render("multiplayer-settings", output, settingsPage(), size: .init(width: 1920, height: 1080))
        ScreenVPN.connected = false
        try render("multiplayer-vpn-disconnected", output, settingsPage(), size: .init(width: 1920, height: 1080))
        for (name, locale) in [("multiplayer-vpn-warning", frLocale),
                               ("multiplayer-vpn-warning-de", AppLocale(language: .german, region: "DE"))] {
            L10n.setContext(locale)
            vm.showMultiplayerVPNFallback {}
            let warning = vm.settingsNotice!
            precondition(warning.choices == ["Play on the local network", "Cancel"])
            precondition(vm.settingsNoticeFocus == 0 && warning.cancelIndex == 1)
            try renderNotice(name, output, warning, width: 1100)
        }
        L10n.setContext(frLocale)
        func gameOptions() -> some View {
            var installed = game
            installed.status = .built
            return GameOptionsView(viewModel: vm, game: installed, origin: .details, onClose: {}, onShowBuild: {}, onMove: {})
                .environment(\.nxAppLocale, frLocale)
        }
        ScreenVPN.connected = true
        try render("multiplayer-game-options", output, gameOptions(),
                   size: .init(width: 1920, height: 1080))
        settings.settings.multiplayerDefault = .online
        ScreenVPN.mods = true
        try render("multiplayer-online-mods", output, gameOptions(),
                   size: .init(width: 1920, height: 1080))
'''

MULTIPLAYER_BEFORE = r'''
        let page = SettingsView(initialSection: .apiServices, viewModel: vm, settings: settings,
                                router: AppRouter(), artwork: ArtworkStore())
        ScreenVPN.connected = true
        try render("multiplayer-settings", output, page.environment(\.nxAppLocale, frLocale),
                   size: .init(width: 1920, height: 1080))
        ScreenVPN.connected = false
        try render("multiplayer-vpn-disconnected", output, page.environment(\.nxAppLocale, frLocale),
                   size: .init(width: 1920, height: 1080))
        try render("multiplayer-game-options", output,
                   MoreSettingsPanel(viewModel: vm, game: game, onClose: {}).environment(\.nxAppLocale, frLocale),
                   size: .init(width: 1920, height: 1080))
        let snapshot = vm.runtimeSettings.settingsSnapshot(for: game)!
        try render("multiplayer-online-mods", output,
                   ModsPanel(viewModel: vm, game: game,
                             settings: .init(settings: snapshot.settings, values: ["DM_NETWORK": "nextendo"], fixed: []),
                             onRebuild: {}, onClose: {}).environment(\.nxAppLocale, frLocale),
                   size: .init(width: 1920, height: 1080))
'''

def multiplayer_fixture(app, host, before):
    settings_view = app / "Views/Settings/SettingsView.swift"
    change(settings_view, r'        ScrollViewReader \{ proxy in\n            ScrollView \{\n', '')
    change(settings_view, r'            }\n            \.scrollIndicators\(\.hidden\).*?(?=\n    }\n\n    private var reduceMotion)', '')
    change(settings_view, r'    private var supportsNextendo: Bool \{ [^\n]* \}', '    private var supportsNextendo: Bool { true }')
    change(settings_view, r'        \.background\(SeleneBackdrop\(\)\.environment[^\n]*\n', '')
    sidebar = app / "Views/Settings/SettingsSidebar.swift"
    change(sidebar, r'            ScrollViewReader \{ proxy in.*?(?=\n        }\n    })', '            groups')
    change(sidebar, r'ForEach\(SettingsSidebarGroup.all\)', 'ForEach(Array(SettingsSidebarGroup.all.prefix(2)))')
    nextendo = app / "ViewModels/NextendoSettings.swift"
    change(nextendo, r'    func check\(clientID: String\?\) \{.*?(?=\n    func updateFriend)', '    func check(clientID: String?) {}\n')
    model = app / "ViewModels/RuntimeSettingsModel.swift"
    change(model, r'NXNativeGameSettings\.forGame\(game\)', '''NXNativeGameSettings.forGame(game, store: MemorySavedChoices(),
            supportDirectory: AppData.supportRoot, preferences: AppData.preferences)''')
    section = app / "Views/Settings/SettingsAPISection.swift"
    change(section, r'remotePlayAdapters = \.current\(\)', 'remotePlayAdapters = ScreenVPN.adapters')
    # No filesystem-backed credentials, real mods or engine checks during fixture rendering.
    mods_model = app / "ViewModels/AppViewModel+Mods.swift"
    change(mods_model, r'    func modStore\(for game: PortedGame\) -> ModStore\? \{.*?(?=\n    func modsRowValue)',
           '    func modStore(for game: PortedGame) -> ModStore? { nil }\n')
    setup = app / "ViewModels/SetupModel.swift"
    change(setup, r'    func prepareBuildEnvironmentIfNeeded\(\) \{.*?\n    }', '    func prepareBuildEnvironmentIfNeeded() {}')
    with section.open("a") as swift:
        swift.write('''
enum ScreenVPN {
    static var connected = false
    static var mods = false
    static var adapters: RemotePlayAdapters { .screenFixture(connected: connected) }
}
''')
    if before:
        change(section, r'private var remotePlayAdapters = RemotePlayAdapters\(\)', 'private var remotePlayAdapters = ScreenVPN.adapters')
        more = app / "Views/GameOptions/MoreSettingsPanel.swift"
        change(more, r'        ScrollViewReader \{ proxy in\n            ScrollView \{\n                LazyVStack', '        VStack')
        change(more, r'            }\n            \.scrollIndicators\(\.hidden\).*?(?=\n    }\n\n    private func value)', '')
        mods = app / "Views/GameOptions/ModsPanel.swift"
        change(mods, r'private var mods: \[LocalMod\] = \[\]', '''private var mods: [LocalMod] = [
        .init(folderName: "Rules", folder: AppData.supportRoot, romfs: AppData.supportRoot, isOn: true),
        .init(folderName: "Code patch", folder: AppData.supportRoot, romfs: nil, exefs: AppData.supportRoot, isOn: true)
    ]''')
        change(mods, r'        return ScrollViewReader \{ proxy in\n            ScrollView \{\n', '        return Group {\n')
        change(mods, r'            }\n            \.scrollIndicators\(\.hidden\).*?(?=\n        }\n    }\n\n    private func sectionHeader)', '')
        change(mods, r'            sync\(preservingFocus: false\)\n', '')
        return host.replace("// MULTIPLAYER_CHECK", MULTIPLAYER.replace("// MULTIPLAYER_STATES", MULTIPLAYER_BEFORE))
    change(section, r'@State var remotePlayAdapters = RemotePlayAdapters\(\)', '@State var remotePlayAdapters = ScreenVPN.adapters')
    options = app / "Views/GameOptions/GameOptionsView.swift"
    change(options, r'@State var multiplayerAdapters = RemotePlayAdapters\(\)', '@State var multiplayerAdapters = ScreenVPN.adapters')
    change(options, r'            multiplayerAdapters = \.current\(\)', '            multiplayerAdapters = ScreenVPN.adapters')
    change(options, r'@State var onlineRiskMods: \[String: ModFolderScanner.OnlineContent\] = \[:\]',
           '@State var onlineRiskMods: [String: ModFolderScanner.OnlineContent] = ScreenVPN.mods ? ["Rules": .data] : [:]')
    change(options, r'cheatsValue = viewModel.cheats.cheatRowValue\(for: game\)', 'cheatsValue = L10n.text("None")')
    change(options, r'modsValue = viewModel.modsRowValue\(for: game\)', 'modsValue = ScreenVPN.mods ? "2" : L10n.text("None")')
    change(options, r'        \.task\(id: OnlineModsRequest.*?(?=\n        \.task \{)', '')
    rows = app / "Views/GameOptions/GameOptionsView+Rows.swift"
    change(rows, r'            ScrollViewReader \{ proxy in\n                ScrollView \{\n', '')
    change(rows, r'                }\n                \.scrollIndicators\(\.hidden\).*?\n            }\n            \.id\(level\)\n', '')
    change(rows, r'let entries = p\.entries\(level: level, origin: origin\)',
           'let entries = p.entries(level: level, origin: origin).prefix(ScreenVPN.mods ? 8 : 7)')
    return host.replace("// MULTIPLAYER_CHECK", MULTIPLAYER.replace("// MULTIPLAYER_STATES", MULTIPLAYER_STATES))


def change(file, old, new):
    text, count = re.subn(old, lambda _: new, file.read_text(), count=1, flags=re.S)
    assert count == 1, (file, old)
    file.write_text(text)


def main():
    # Without a folder, as a release regression, render into a throwaway folder under work/.
    output = Path(sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="cloud-screens-", dir=ROOT / "work")).resolve()
    output.mkdir(parents=True, exist_ok=True)
    before = len(sys.argv) > 2 and sys.argv[2] == "--before"
    with tempfile.TemporaryDirectory(prefix="cloud-screen-", dir=output.parent) as temp:
        package = Path(temp)
        shutil.copyfile(ROOT / "Package.swift", package / "Package.swift")
        if before:
            archived = subprocess.check_output(["git", "-C", str(ROOT), "archive", "528f4fb", "Sources"])
            subprocess.run(["tar", "-xf", "-", "-C", str(package)], input=archived, check=True)
        else:
            shutil.copytree(ROOT / "Sources", package / "Sources")
        for name in ("NXLibraryCoreTests", "ArcanePortingTests"):
            folder = package / "Tests" / name
            folder.mkdir(parents=True)
            (folder / "Empty.swift").touch()
        app = package / "Sources/NXLibrary"
        change(app / "NXLibraryApp.swift", r"@main\nstruct", "struct")
        change(app / "ViewModels/AppViewModel.swift", r"SteamGridDBKey\(\)\.load\(\) != nil", "false")
        change(app / "ViewModels/AppViewModel.swift", r"        applyCatalog\(catalog\).*?\n    }\n\n    // MARK: - Dynamic",
               "    }\n\n    // MARK: - Dynamic")
        change(package / "Sources/NXLibraryCore/App/AppDataProfile.swift",
               r'public static let profile = [^\n]*',
               f'public static let profile = AppDataProfile(home: URL(fileURLWithPath: "{temp}"), isDevelopment: true)')
        change(package / "Sources/NXLibraryCore/App/AppDataProfile.swift",
               r'public static var preferences: UserDefaults \{ \.standard \}',
               'public static let preferences = UserDefaults(suiteName: "local.arcane.screen-probe-' + package.name + '")!')
        change(app / "ViewModels/AppViewModel+CloudLibrary.swift",
               r'        let defaults = AppData\.preferences.*?(?=        rebuildArchive\(\))',
               '        preference = .init(storage: "fixture:Games", enabled: true, sourcesRoot: nil)\n'
               '        chosenExecutable = nil\n')
        section = app / "Views/Settings/SettingsCloudLibrarySection.swift"
        change(section,
               r'        \.task\(id: Inspection.*?\n        }\n', "")
        change(app / "Views/Detail/CloudLibraryPanel.swift",
               r'        \.task\(id: ReadRequest.*?\n', "")
        assistant = app / "Views/Settings/CloudSetupAssistant.swift"
        change(assistant, r'        \.onAppear \{\s*.*?installAssistantKeys\(\)(?: \}|\n        })\n', "")
        change(assistant, r'@State private var remotes: \[RcloneRemote\]\?', '@State private var remotes: [RcloneRemote]? = []')
        browser = "private var browsingPath" in assistant.read_text()
        if browser:
            change(assistant, r'        self.onClose = onClose', '''        self.onClose = onClose
        _listing = State(initialValue: .screenFixture)''')
            # Render the real breadcrumb and folder rows without AppKit-backed scrolling.
            change(assistant, r'                ScrollView\(\.horizontal\) \{\n(.*?)\n                }\n                if listing != nil',
                   re.search(r'                ScrollView\(\.horizontal\) \{\n(.*?)\n                }\n                if listing != nil',
                             assistant.read_text(), re.S)[1] + '\n                if listing != nil')
            change(assistant, r'                    ScrollViewReader \{ proxy in\n                        ScrollView \{\n'
                   r'                            LazyVStack', '                    VStack')
            change(assistant, r'                        }\n                        \.frame\(height: canvas.u\(CGFloat\(min\(folderNames.count.*?\n'
                   r'                    }\n                    option\(\.newFolder', '                    option(.newFolder')
            with (package / "Sources/ArcanePorting/Library/CloudDriveFolders.swift").open("a") as swift:
                swift.write('''
extension CloudDriveFolders.Listing {
    public static var screenFixture: Self { .init(ticket: UUID(), names: ["Nintendo", "Switch"]) }
}
''')
        else:
            # TextField is AppKit-backed and ImageRenderer shows a placeholder instead of its text.
            change(assistant, r'TextField\(text\("Game files folder"\), text: \$sourcesPath,\s+'
                   r'prompt: Text\(verbatim: [^\n]+\)\)\s+\.focused\([^\n]+',
                   'Text(verbatim: sourcesPath).frame(maxWidth: .infinity, alignment: .leading)')
        change(app / "Views/Components/SwitchBoxArtCover.swift",
               r'        \.task\(id: coverKey.*?\n        \.task\(id: game.id[^\n]*\n', "")
        activity = app / "Views/Shell/ActivityCenterView.swift"
        view = activity.read_text()
        assert 'section("Compilation", empty: "No compilation"' in view
        assert 'section("Cloud", empty: "No cloud transfer"' in view
        assert 'if rows.isEmpty, let empty' in view and 'Text(text(empty))' in view
        # ImageRenderer does not draw AppKit-backed scrolling. Keep the real rows and their layout.
        change(activity, r'                ScrollViewReader \{ scroll in\n                    ScrollView \{\n', "")
        change(activity, r'                    }\n                    \.padding\(EdgeInsets.*?\.onChange\(of: focused\)[^\n]*\n                }\n', "")
        change(activity, r'        LazyVStack\(', '        VStack(')
        host = HOST.replace("/* NOTICE_LAYOUT */", "vertical: notice.vertical," if before else "cancelIndex: notice.cancelIndex,")
        if not before:
            # Capture Spotlight after its entrance, without running the reveal in ImageRenderer.
            change(app / "Views/Spotlight/SpotlightInfoView.swift",
                   r'        \.onAppear \{ reveal\(\) \}\n        \.onChange\(of: game.id\) \{ reveal\(\) \}\n', "")
            host = host.replace("// DOWNLOAD_FILL_CHECK", "do {\n" + DOWNLOAD_FILL + "\n        }")
        if "onEditLibrary:" in section.read_text():
            host = host.replace("onEdit: {}, onEditSources:", "onEdit: {}, onEditLibrary: {}, onEditSources:")
            host = host.replace("/* ENTRY */", ", entry: .sources")
            host = host.replace("// CONNECTION_FIXTURE",
                '''model.connectionCheck = .init(date: Date(timeIntervalSince1970: 1_795_000_000), failure: .offline)
        let en = AppLocale(language: .english, region: "US")
        let fr = AppLocale(language: .french, region: "FR")
        var uploading = CloudLibraryState()
        uploading.action = .upload(nil)
        uploading.progress = .init(.uploading, kind: .cache)
        let pendingApp = CloudLibraryIndicator(state: uploading, item: .app)
        precondition(pendingApp.label(context: en) == "Sent · published when the upload ends")
        precondition(pendingApp.label(context: fr) == "Envoyée · publiée à la fin de l'envoi")
        precondition(CloudLibraryIndicator(state: model.states[game.id]!).label(context: en) == "Cloud only")''')
        if browser:
            host = host.replace("// TYPED_PATH_CHECK", '''
        model.active = nil
        model.queue = []
        let typedPath = CloudSetupAssistant(viewModel: vm, model: model, entry: .sources) {}
        typedPath.checkTypedPath("Arcane/../Sources", expected: nil)
        typedPath.checkTypedPath("  Future/Uncreated files  ", expected: "Future/Uncreated files")
''')
            with assistant.open("a") as swift:
                swift.write('''
extension CloudSetupAssistant {
    @MainActor func checkTypedPath(_ path: String, expected: String?) {
        var view = self
        view._listing = State(initialValue: nil)
        view._enteredSourcesPath = State(initialValue: path)
        precondition(view.focusRows.flatMap { $0 }.contains(.sourcesPath))
        precondition(view.primaryEnabled == (expected != nil))
        let previous = model.preference
        view.perform(.primary)
        precondition(model.preference.sourcesRootOverride == (expected ?? previous.sourcesRootOverride))
        precondition(model.preference.remote == previous.remote && model.preference.root == previous.root)
    }
}
''')
            host = host.replace("// ASSISTANT_CHECK", '''
        precondition(assistant.focusedTarget == .primary)
        precondition(CloudLibraryIndicator(state: model.states[game.id]!).status == .pending)
        precondition(CloudLibraryIndicator(state: model.states[game.id]!, item: .cache).status == .synchronized)
        precondition(pendingApp.status == .pending && !pendingApp.isTransferring)
        let transferring = CloudLibraryIndicator(state: uploading, item: .cache)
        precondition(transferring.status == .pending && transferring.isTransferring)
        uploading.queued = true
        let queued = CloudLibraryIndicator(state: uploading, item: .cache)
        precondition(queued.status.color == SeleneTheme.ink60 && !queued.isTransferring)
        precondition(transferring.status.color == SeleneTheme.statusCloud)
        precondition(CloudLibraryBadge(indicator: queued).isVisibleOnTile)
        precondition(CloudLibraryBadge(indicator: transferring).isVisibleOnTile)
        precondition(CloudLibraryBadge(indicator: .init(state: model.states[game.id]!)).isVisibleOnTile)
        var failed = CloudLibraryState()
        failed.sourceFailure = .offline
        precondition(CloudLibraryIndicator(state: failed, item: .sources).status == .failed)
        precondition(CloudLibraryIndicator(state: failed).status == .unknown)
        var local = CloudLibraryState()
        local.copies[.app] = .screenFixture(.notInCloud, hasLocalCopy: true)
        precondition(CloudLibraryIndicator(state: local).status == .needsUpload)
        precondition(!CloudLibraryBadge(indicator: .init(state: local)).isVisibleOnTile)
        precondition(!CloudLibraryBadge(indicator: .init(state: .init(refreshing: true))).isVisibleOnTile)
''')
        else:
            change(assistant, r'@State private var draft = CloudSetupAssistantDraft\(\)', '''
    @State private var draft: CloudSetupAssistantDraft = {
        var draft = CloudSetupAssistantDraft()
        draft.chooseAccount("fixture")
        draft.browse("Games")
        return draft
    }()
'''.strip())
            change(assistant, r'@State private var selectingSources = false', '@State private var selectingSources = true')
            change(assistant, r'@State private var sourcesPath = ""', '@State private var sourcesPath = "Games/GameFiles"')
        host = multiplayer_fixture(app, host, before)
        adapters = package / "Sources/ArcanePorting/GameSettings/RemotePlayAdapters.swift"
        with adapters.open("a") as swift:
            swift.write('''
extension RemotePlayAdapters {
    public static func screenFixture(connected: Bool) -> Self {
        var adapters = Self()
        if connected { adapters.consider("feth3971", flags: UInt32(IFF_UP), ipv4: 0x0ac7920b) }
        return adapters
    }
}
''')
        (app / "CloudScreenProbe.swift").write_text(host)
        with (app / "ViewModels/AppViewModel+CloudLibrary.swift").open("a") as swift:
            swift.write('''
extension AppViewModel {
    @MainActor func screenRebuildNotice() {
        let game = PortedGame(name: "Pokémon Legends: Z-A", url: AppData.supportRoot.appendingPathComponent("Fixture.app"),
                             platform: .macApp, sizeBytes: 0, modificationDate: .now)
        let archive = CloudGameArchive(backend: RcloneStorageBackend(remote: "fixture", root: "Games"))
        showCloudBuildNotice(for: game, archive: archive, extraArguments: [], onStarted: nil,
                             canDownload: true, hasLocalCache: true)
    }
}
''')
        with (package / "Sources/ArcanePorting/Library/CloudGameArchive.swift").open("a") as swift:
            swift.write('''
extension CloudArtifactStatus {
    public static func screenFixture(_ state: State, hasLocalCopy: Bool? = nil) -> Self {
        .init(state: state, hasLocalCopy: hasLocalCopy ?? (state == .synchronized), bytes: 100_000_000,
              uploadedAt: Date(timeIntervalSince1970: 1_795_000_000), skippedRoots: [])
    }
}
''')
        font = ROOT / "Resources/Selene/Fonts/MaterialIcons-Regular.ttf"
        icon = ROOT / "Resources/AppIcon-Light.png"
        subprocess.run(["swift", "run", "--package-path", str(package), "NXLibrary", str(output), str(font), str(icon)],
                       check=True, env=dict(os.environ, HOME=temp))


if __name__ == "__main__":
    main()
