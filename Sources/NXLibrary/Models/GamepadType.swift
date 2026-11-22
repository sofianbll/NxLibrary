import Foundation
import NXLibraryCore

enum GamepadBrand: String, CaseIterable, Identifiable {
    case nintendoSwitch = "Nintendo Switch"
    case xbox = "Xbox Series / One"
    case playstation = "PlayStation DualShock / DualSense"
    case generic = "8BitDo / Generic Gamepad"

    var id: String { rawValue }

    var confirmButtonName: String {
        switch self {
        case .nintendoSwitch: return "A (Confirm)"
        case .xbox: return "A (Confirm)"
        case .playstation: return "✕ (Confirm)"
        case .generic: return "A (Confirm)"
        }
    }

    var cancelButtonName: String {
        switch self {
        case .nintendoSwitch: return "B (Back)"
        case .xbox: return "B (Back)"
        case .playstation: return "○ (Back)"
        case .generic: return "B (Back)"
        }
    }

    var secondaryButtonName: String {
        switch self {
        case .nintendoSwitch: return "X (Settings)"
        case .xbox: return "X (Settings)"
        case .playstation: return "□ (Settings)"
        case .generic: return "X (Settings)"
        }
    }

    var contextButtonName: String {
        switch self {
        case .nintendoSwitch: return "Y (Save Folder)"
        case .xbox: return "Y (Save Folder)"
        case .playstation: return "△ (Save Folder)"
        case .generic: return "Y (Save Folder)"
        }
    }

    var shoulderTabsPrompt: String {
        switch self {
        case .nintendoSwitch: return "L / R"
        case .xbox: return "LB / RB"
        case .playstation: return "L1 / R1"
        case .generic: return "L / R"
        }
    }

    var menuButtonGlyph: String {
        switch self {
        case .nintendoSwitch: return "＋"
        case .playstation: return "☰"
        case .xbox, .generic: return "≡"
        }
    }
}

enum GamepadAction: Hashable {
    case navigateUp
    case navigateDown
    case navigateLeft
    case navigateRight
    case confirm           // A or Cross
    case cancel            // B or Circle
    case secondaryAction   // X or Square
    case contextAction     // Y or Triangle
    case tabPrevious       // Left Shoulder (L / LB)
    case tabNext           // Right Shoulder (R / RB)
    case menu              // Menu / + / Options (tap)
    case menuHold          // Menu / + / Options (hold)
    case view              // View / − / Touchpad
    case search            // ⌘F
    case jumpToStart       // Left trigger
    case jumpToEnd         // Right trigger
    case rightStickPress   // R3

    static func onPress(_ button: ControllerButton) -> Self? {
        switch button {
        case .up: return .navigateUp
        case .down: return .navigateDown
        case .left: return .navigateLeft
        case .right: return .navigateRight
        case .a: return .confirm
        case .b: return .cancel
        case .x: return .secondaryAction
        case .y: return .contextAction
        case .l: return .tabPrevious
        case .r: return .tabNext
        case .zl: return .jumpToStart
        case .zr: return .jumpToEnd
        case .r3: return .rightStickPress
        case .view: return .view
        case .menu, .home, .l3, .capture: return nil
        }
    }

    static func menuAction(_ result: HoldResult) -> Self {
        result == .tap ? .menu : .menuHold
    }
}
