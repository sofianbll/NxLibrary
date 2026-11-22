import XCTest

/// Screens read the keyboard through their own `NSEvent` monitors. A shell overlay drawn on top of them
/// (the update offer, the welcome) must make every such monitor let the key go, or Return reaches the screen
/// underneath: a game starts instead of the overlay's button.
final class ShellOverlayInputTests: XCTestCase {
    private var views: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NXLibrary/Views")
    }

    func testEveryMonitorThatYieldsToAShellDialogYieldsToTheWelcome() throws {
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var missing: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let offer = text.components(separatedBy: "!viewModel.shellDialogOwnsInput").count - 1
            let welcome = text.components(separatedBy: "!viewModel.isWelcomeOpen").count - 1
            if offer != welcome { missing.append("\(file.lastPathComponent): \(offer) vs \(welcome)") }
        }
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(missing.sorted(), [])
    }
}

/// The screens under the control center or the profile screen step aside from their hints: the shell marks each
/// full-page layer (screen, Add game, console) covered, and every `SeleneHintsBar` honours the mark.
final class ShellOverlayHintsTests: XCTestCase {
    private var views: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NXLibrary/Views")
    }

    private func source(_ path: String) throws -> String { try String(contentsOf: views.appendingPathComponent(path), encoding: .utf8) }

    func testEveryFullPageLayerUnderAnOverlayIsMarkedCovered() throws {
        let layers = try source("Shell/AppShellView+Layers.swift")
        XCTAssertEqual(layers.components(separatedBy: ".environment(\\.seleneHintsCovered, hintsCovered)").count - 1, 3)
        XCTAssertTrue(try source("Components/SeleneHintsBar.swift").contains(".seleneOverlaidHints(covered)"))
    }

    func testTheProfilePickerHidesItsSelectorAndHintsUnderTheWizard() throws {
        let picker = try source("Shell/ProfilePickerView.swift")
        XCTAssertTrue(picker.contains(".opacity(layers.showsSelector ? 1 : 0)"))
        XCTAssertTrue(picker.contains(".seleneOverlaidHints(!layers.isTop(.selector))"))
        XCTAssertTrue(picker.contains("layers.top != .editor"))
    }
}
