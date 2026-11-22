#!/usr/bin/env python3
"""Render the real Inbox content and Selene confirmation offscreen, using fake packages."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]

HOST = r'''
import AppKit
import ArcanePorting
import CoreText
import NXLibraryCore
import SwiftUI

@main struct InboxProbe {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        precondition(CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, .process, nil))
        let locale = AppLocale(language: .french, region: "FR")
        L10n.setContext(locale)
        let support = AppData.supportRoot
        let app = AppViewModel(settingsStore: AppSettingsStore(fileURL: support.appendingPathComponent("settings.json")),
                               catalog: .init(), repository: .init(store: .init(directory: support)))
        let model = app.gameInbox
        let router = AppRouter()
        router.openGameInbox()
        precondition(router.route == .gameInbox && MenuAction.library.entries.contains(.gameInbox))
        let view = GameInboxView(model: model, router: router)
        let root = GameInboxModel.gamesRoot
        try render("01-empty", page: view.page, to: output, locale: locale)
        AppData.preferences.set(root.path, forKey: PortingModel.savedGameFolderKey)
        try FileManager.default.createDirectory(at: model.folder, withIntermediateDirectories: true)
        let title: UInt64 = 0x0100000000004000
        let files = try ["lunar-base.nsp", "lunar-update.nsz", "lunar-expansion.xci"].map { name in
            let url = model.folder.appendingPathComponent(name)
            try Data([1, 2, 3]).write(to: url)
            return url
        }
        let inputs = GameInbox.inputs(files)
        let metadata: [URL: PackageReading] = [
            files[0]: .contents([.init(kind: .base, titleId: title, version: 0)]),
            files[1]: .contents([.init(kind: .update, titleId: title + 0x800, version: 65536)]),
            files[2]: .contents([.init(kind: .dlc, titleId: title + 0x1001, version: 1)])
        ]
        func plan(_ readings: [URL: PackageReading]) -> [GameInbox.Entry] {
            GameInbox.plan(inputs: inputs, readings: readings, root: root) {
                $0 == title ? "Lunar Observatory" : "Far Side Expansion"
            }
        }
        model.entries = plan(metadata)
        precondition(model.entries.allSatisfy { $0.destination != nil })
        try render("02-three-files", page: view.page, to: output, locale: locale)
        model.entries = plan(metadata.filter { $0.key != files[2] })
        precondition(model.entries.filter { $0.issue != nil }.count == 1)
        model.confirm(model.entries.filter { $0.destination != nil })
        let notice = app.settingsNotice!
        precondition(notice.choices.count == 2 && notice.cancelIndex == 1 && notice.initialFocus == 0)
        try render("03-ambiguous", page: view.page, to: output, locale: locale)
        try render("04-confirmation", page: ZStack {
            view.page.blur(radius: 20)
            Color.black.opacity(0.55)
            SeleneChoiceDialog(title: notice.title, message: notice.message, choices: notice.choices,
                focus: .constant(notice.initialFocus), cancelIndex: notice.cancelIndex) { _ in }
        }, to: output, locale: locale)
        let artwork = ArtworkStore()
        let card = SpotlightItem.card(.inbox)
        try render("05-spotlight-card", page: VStack(alignment: .leading, spacing: 24) {
            SpotlightRowView(items: [card, .card(.addGame)], gamesByID: [:], selectedKey: card.key,
                isEmptyFilter: nil, artwork: artwork, cloud: app.cloudLibrary, showsCloudBadges: false,
                onSelect: { _ in }, onActivate: { _ in })
                .frame(height: 190)
            SpotlightCardInfoView(card: .inbox, gameCount: 0, installedCount: 0, poolLabel: "",
                activity: ActivitySummary(), topGames: [], focusedTop: nil, artwork: artwork, onTopGame: { _ in })
                .padding(.leading, 58)
        }.padding(.top, 90), to: output, locale: locale)
        print("Inbox: four fixture screens, Spotlight card and menu route verified offscreen.")
    }

    @MainActor static func render(_ name: String, page: some View, to output: URL, locale: AppLocale) throws {
        let size = CGSize(width: 1344, height: 756)
        let canvas = SeleneCanvas(size: size)
        let scene = ZStack(alignment: .top) {
            Rectangle().fill(SeleneTheme.baseGradient)
            page
            SeleneHintsBar(left: [HintItem(.b, L10n.text("Back"))],
                           right: [HintItem(.a, L10n.text("Select"))])
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(["04-confirmation", "05-spotlight-card"].contains(name) ? 0 : 1)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.seleneCanvas, canvas)
        .environment(\.nxAppLocale, locale)
        .environment(\.seleneReduceMotion, true)
        let renderer = ImageRenderer(content: scene)
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }
}
'''


def change(path, previous, replacement):
    text = path.read_text()
    assert text.count(previous) == 1, (path, previous)
    path.write_text(text.replace(previous, replacement))


def main():
    with tempfile.TemporaryDirectory(prefix="inbox-probe-") as temp:
        package = Path(temp).resolve()
        home = package / "Player"
        home.mkdir()
        output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "work/screens-inbox"
        output.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "Package.swift", package / "Package.swift")
        shutil.copytree(ROOT / "Sources", package / "Sources")
        for target in ("NXLibraryCoreTests", "ArcanePortingTests"):
            stub = package / "Tests" / target / "Empty.swift"
            stub.parent.mkdir(parents=True)
            stub.touch()
        app = package / "Sources/NXLibrary"
        change(app / "NXLibraryApp.swift", "@main\nstruct", "struct")
        model = app / "ViewModels/AppViewModel.swift"
        change(model, "SteamGridDBKey().load() != nil", "false")
        # Omit startup scans, key access and the bundle-only notification service.
        text = model.read_text()
        first = text.index("        applyCatalog(catalog)")
        last = text.index("    }\n\n    // MARK: - Dynamic", first)
        model.write_text(text[:first] + text[last:])
        change(app / "ViewModels/GameInboxModel.swift", "private(set) var entries:", "var entries:")
        # SwiftUI's AppKit-backed drop wrapper produces a placeholder in ImageRenderer.
        change(app / "Views/Porting/GameInboxView.swift",
               "            .dropDestination(for: URL.self) { urls, _ in model.accept(urls) } isTargeted: { dropTarget = $0 }\n",
               "")
        profile = package / "Sources/NXLibraryCore/App/AppDataProfile.swift"
        change(profile, 'AppDataProfile(isDevelopment: Bundle.main.object(forInfoDictionaryKey: "NXLibraryDevelopmentProfile") as? Bool == true)',
               f'AppDataProfile(home: URL(fileURLWithPath: {json.dumps(str(home))}), isDevelopment: true)')
        change(profile, "public static var preferences: UserDefaults { .standard }",
               f'public static let preferences = UserDefaults(suiteName: "local.arcane.{package.name}")!')
        (app / "InboxProbe.swift").write_text(HOST)
        font = ROOT / "Resources/Selene/Fonts/MaterialIcons-Regular.ttf"
        subprocess.run(["swift", "run", "--package-path", str(package), "NXLibrary", str(output), str(font)],
                       env=dict(os.environ, HOME=str(home)), check=True)


if __name__ == "__main__":
    main()
