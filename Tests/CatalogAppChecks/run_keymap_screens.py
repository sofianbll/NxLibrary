#!/usr/bin/env python3
"""Render the real Selene help bar with injected controller identities, without opening a window."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / ".build/debug"
VIEWS = ROOT / "Sources/NXLibrary/Views"

HOST = r'''
import AppKit
import CoreText
import SwiftUI
import NXLibraryCore

final class AppViewModel { var isGameOptionsOpen = false }
final class GameControllerService: ObservableObject {
    static let shared = GameControllerService()
    var isGamepadConnected = true
    var activeBrand = GamepadBrand.generic
    var buttonSymbols: [PromptButton: String] = [:]
}
final class ThemeStore {
    static let shared = ThemeStore()
    let palette = SelenePalette.fallback
}

@main struct KeymapScreens {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let font = root.appendingPathComponent("Resources/Selene/Fonts/MaterialIcons-Regular.ttf")
        precondition(CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, brand): (String, GamepadBrand) in [
            ("xbox", .xbox), ("switch", .nintendoSwitch), ("ps5", .playstation),
        ] {
            GameControllerService.shared.activeBrand = brand
            let left = HintItem.homeGlobals(other: "Spotlight", onOther: {}, onMenu: {}, onSearch: {})
            let right = [HintItem(.a, "Play"), HintItem(.x, "Details"), HintItem(.y, "Game options")]
            let view = ZStack(alignment: .bottom) {
                Rectangle().fill(SeleneTheme.baseGradient)
                SeleneBottomScrim()
                SeleneHintsBar(left: left, right: right)
            }.frame(width: 1344, height: 756)
                .environment(\.seleneCanvas, SeleneCanvas(size: .init(width: 1344, height: 756)))
                .frame(height: 160, alignment: .bottom)
                .clipped()
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { fatalError("Could not render \(name)") }
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        print("Rendered three Selene help bars without a window.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="keymap-screens-") as folder:
    scratch = Path(folder)
    swift = scratch / "check.swift"
    swift.write_text(HOST)
    binary = scratch / "check"
    paths = [
        "Theme/AppLocaleEnvironment.swift", "Theme/SeleneCanvasEnvironment.swift",
        "Theme/SeleneFonts.swift", "Theme/SeleneTheme.swift",
        "Components/SeleneBottomScrim.swift", "Components/SeleneHomeChrome.swift",
        "Components/SeleneHintsBar.swift", "Components/SelenePromptBadge.swift",
    ]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-I", BIN, swift,
                    ROOT / "Sources/NXLibrary/Models/GamepadType.swift",
                    *(VIEWS / p for p in paths), BIN / "NXLibraryCore.o", "-o", binary], check=True)
    output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else scratch / "screens"
    subprocess.run([binary, ROOT, output], check=True,
                   env=dict(os.environ, PACKAGE_RESOURCE_BUNDLE_PATH=str(BIN)))
