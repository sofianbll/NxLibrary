import Foundation

/// The control-center row, left to right: five icons, as Selene's menu.png keeps it short.
/// Profile and Library open a card of entries above their icon; Power opens its pills.
public enum MenuAction: String, CaseIterable, Identifiable, Equatable {
    case profile, library, activityCenter, settings, power
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profile: return L10n.text("Profile")
        case .library: return L10n.text("Library")
        case .settings: return L10n.text("Settings")
        case .activityCenter: return L10n.text("Activity center")
        case .power: return L10n.text("Power")
        }
    }

    public var icon: MaterialIcon {
        switch self {
        case .profile: return .person
        case .library: return .add
        case .settings: return .tune
        case .activityCenter: return .notifications
        case .power: return .power
        }
    }

    /// What the icon's card lists, top to bottom; empty when the icon acts at once.
    public var entries: [MenuEntry] {
        switch self {
        case .profile: return [.switchProfile, .editProfile, .theme]
        case .library: return [.addGame, .manageSources, .refreshLibrary]
        default: return []
        }
    }
}

/// One line of the Profile or Library card.
public enum MenuEntry: String, CaseIterable, Identifiable, Equatable {
    case switchProfile, editProfile, theme, addGame, manageSources, refreshLibrary
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .switchProfile: return L10n.text("Switch profile")
        case .editProfile: return L10n.text("Edit profile")
        case .theme: return L10n.text("Theme")
        case .addGame: return L10n.text("Add Game")
        case .manageSources: return L10n.text("Manage sources")
        case .refreshLibrary: return L10n.text("Library refresh")
        }
    }

    public var icon: MaterialIcon {
        switch self {
        case .switchProfile: return .person
        case .editProfile: return .edit
        case .theme: return .palette
        case .addGame: return .add
        case .manageSources: return .collections
        case .refreshLibrary: return .sync
        }
    }
}

/// The pills stacked above Power.
public enum PowerAction: String, CaseIterable, Identifiable, Equatable {
    case quit, sleep, hide, relaunch
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quit: return L10n.text("Quit")
        case .sleep: return L10n.text("Sleep")
        case .hide: return L10n.text("Hide")
        case .relaunch: return L10n.text("Restart app")
        }
    }

    public var icon: MaterialIcon {
        switch self {
        case .quit: return .power
        case .sleep: return .bedtime
        case .hide: return .hidden
        case .relaunch: return .restartAlt
        }
    }
}

/// Focus on the control-center row, and on the card or pills open above its icon.
/// Row moves clamp at the ends; so do the card's entries and the Power pills.
/// Closing a card leaves the focus on its icon.
public struct MenuSelectionModel: Equatable {
    public var selected: MenuAction
    /// The focused pill while the Power pills are open.
    public var power: PowerAction = .quit
    /// The focused entry while the Profile or Library card is open.
    public var entry: MenuEntry = .switchProfile
    public private(set) var isPowerOpen = false
    public private(set) var isEntryOpen = false

    /// Opens on Power, as Selene's menu does.
    public init(selected: MenuAction = .power) { self.selected = selected }

    /// A card or the Power pills hold the focus: the row waits.
    public var isSubmenuOpen: Bool { isPowerOpen || isEntryOpen }

    public mutating func move(by delta: Int) {
        let all = MenuAction.allCases
        guard let index = all.firstIndex(of: selected) else { return }
        let next = min(max(index + delta, 0), all.count - 1)
        selected = all[next]
    }

    public mutating func movePower(by delta: Int) {
        let all = PowerAction.allCases
        guard let index = all.firstIndex(of: power) else { return }
        let next = min(max(index + delta, 0), all.count - 1)
        power = all[next]
    }

    /// Opens the Power pills with Quit focused.
    public mutating func openPower() {
        power = .quit
        isPowerOpen = true
    }

    public mutating func closePower() {
        isPowerOpen = false
    }

    /// Opens the selected icon's card with its first entry focused; nothing happens for an icon without one.
    public mutating func openEntries() {
        guard let first = selected.entries.first else { return }
        entry = first
        isEntryOpen = true
    }

    public mutating func moveEntry(by delta: Int) {
        let all = selected.entries
        guard isEntryOpen, let index = all.firstIndex(of: entry) else { return }
        entry = all[min(max(index + delta, 0), all.count - 1)]
    }

    public mutating func closeEntries() {
        isEntryOpen = false
    }
}
