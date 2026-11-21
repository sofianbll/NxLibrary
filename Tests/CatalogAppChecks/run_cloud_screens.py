#!/usr/bin/env python3
"""Render real cloud views offscreen with synthetic states; never start the launcher."""
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
        let activity = ActivityCenterView(viewModel: vm, porting: vm.porting, cloudLibrary: model, focus: .init(),
            onFocus: { _ in }, onOpen: { _ in }, onCancel: { _ in }, onClose: {})
        precondition(ActivityCenterView.rows(vm).isEmpty)
        try render("activity-empty", output, activity)
        model.queue = [queuedRequest]
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
        // TYPED_PATH_CHECK
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


def change(file, old, new):
    text, count = re.subn(old, lambda _: new, file.read_text(), count=1, flags=re.S)
    assert count == 1, (file, old)
    file.write_text(text)


def main():
    # Without a folder, as a release regression, render into a throwaway folder under work/.
    output = Path(sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="cloud-screens-", dir=ROOT / "work")).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cloud-screen-", dir=output.parent) as temp:
        package = Path(temp)
        shutil.copyfile(ROOT / "Package.swift", package / "Package.swift")
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
        host = HOST
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
        (app / "CloudScreenProbe.swift").write_text(host)
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
        subprocess.run(["swift", "run", "--package-path", str(package), "NXLibrary", str(output), str(font)],
                       check=True, env=dict(os.environ, HOME=temp))


if __name__ == "__main__":
    main()
