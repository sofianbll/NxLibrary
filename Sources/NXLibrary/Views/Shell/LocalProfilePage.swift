import SwiftUI
import Combine
import Network
import NXLibraryCore
import ArcanePorting

enum ProfilePresence: String {
    case notLinked = "No account linked"
    case unknown = "Presence unknown"
    case connected = "Nextendo connected"
    case offline = "Offline"
    case loading = "Checking…"
    case failed = "Could not check the Nextendo account. Try again."
    case expired = "Session expired"

    var color: Color {
        switch self {
        case .connected: SeleneTheme.statusOK
        case .expired, .failed: SeleneTheme.danger
        default: SeleneTheme.ink60
        }
    }
}

struct LocalProfilePage: View {
    let profile: LocalProfile
    let nextendo: NextendoSettings?
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var history: PlaySessionStore
    let onClose: () -> Void
    let onUpdate: (LocalProfile) -> Bool
    let onSwitch: () -> Void
    var isGuest = false
    @State private var actions: [SettingsRowAction] = []
    @State private var row: String?
    @State private var button = 0
    @State private var online: Bool?
    @State private var checked = false
    @State private var removalFocus: SeleneConfirmButton = .cancel
    @State private var accountChanged = false
    @State private var settingPIN = false
    @State private var firstPIN: String?

    private var lockButtonTitle: String { profile.isLocked ? "Remove code" : "Set code" }
    private var canUsePage: Bool { !settingPIN && nextendo?.friendToRemove == nil && nextendo?.isEditingClient != true }
    private var actionsWithProfile: [SettingsRowAction] {
        guard !isGuest else { return [] }
        let local = SettingsRowAction(id: "profile-lock", title: "Profile lock") { settingPIN = true }
        guard nextendo != nil else { return [local] }
        return [local,
                .init(id: "profile-presence", title: "Appear online") { togglePresence() },
                .init(id: "profile-game", title: "Show current game") { toggleGame() }] + actions
    }

    private var presence: ProfilePresence {
        guard let nextendo else { return .notLinked }
        if online == false { return .offline }
        if nextendo.isBusy && !nextendo.isRefreshingFriends { return .loading }
        if nextendo.status == .expired { return .expired }
        if nextendo.status == .unavailable || nextendo.failure != nil && nextendo.status == .signedOut { return .failed }
        if nextendo.status == .signedIn { return nextendo.account == nil ? .unknown : .connected }
        return checked ? .notLinked : .unknown
    }

    var body: some View {
        let _ = accountChanged
        ZStack {
            ProfilePageLayout(profile: profile, presence: presence, games: recent, onClose: onClose, onSwitch: onSwitch,
                              showsAccount: false, showsHints: canUsePage) {
                if !isGuest {
                    SeleneButtonRow("Profile lock", buttonTitle: lockButtonTitle) { settingPIN = true }
                }
                if let nextendo {
                    Text(L10n.text("Nextendo — optional online play")).seleneFont(.sectionTitle, .semibold)
                        .accessibilityAddTraits(.isHeader)
                    SeleneToggleRow("Appear online", subtitle: nextendo.presenceShared == false ? "Presence not shared" : nil,
                                    isOn: Binding(get: { profile.sharesPresence }, set: { _ in togglePresence() }))
                    SeleneToggleRow("Show current game", subtitle: "Applies the next time you start a game.",
                                    isOn: Binding(get: { profile.showsCurrentGame == true }, set: { _ in toggleGame() }))
                    SettingsAPISection(viewModel: viewModel, settings: settings, showsMultiplayer: true,
                                   supportsNextendo: true, accountOnly: true, accountOffline: online == false,
                                   advanced: .constant(false),
                                   onActions: updateActions, nextendo: nextendo)
                    .environment(\.seleneFocusedRowID, row)
                    .environment(\.seleneFocusedButton, button)
                }
            }
            .environment(\.seleneFocusedRowID, row)
            .seleneOverlayOwnership(canUsePage)
            if settingPIN {
                SeleneOverlay(style: .profileRemoval, onOutside: cancelPIN) {
                    ProfilePINDialog(title: profile.isLocked ? "Remove profile code" : firstPIN == nil ? "Set profile code" : "Confirm profile code",
                                     allowsTouchID: profile.isLocked, onCancel: cancelPIN,
                                     onTouchID: { _ = savePIN(nil) }, onPIN: enterPIN)
                        .id(firstPIN != nil)
                }
                .transition(.opacity)
            }
            if let nextendo, nextendo.isEditingClient {
                NextendoClientDialog(settings: settings) { nextendo.isEditingClient = false }
            }
            if let nextendo, let friend = nextendo.friendToRemove {
                SeleneTheme.scrim.opacity(SeleneTokens.Effect.profileRemovalVeil).ignoresSafeArea()
                SeleneConfirmDialog(title: L10n.format("Remove %@?", [friend.name]),
                                    message: L10n.text("Remove this friend from your Nextendo account?"),
                                    confirmTitle: L10n.text("Remove"), focus: $removalFocus,
                                    onCancel: { nextendo.friendToRemove = nil }, onConfirm: removeFriend)
                    .onAppear { removalFocus = .cancel }
            }
        }
        .animation(Motion.overlay(reduceMotion), value: settingPIN)
        .task {
            guard nextendo != nil else { return }
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "Arcane.profile-connectivity")
            let changes = AsyncStream<Bool> { stream in
                monitor.pathUpdateHandler = { stream.yield($0.status == .satisfied) }
                stream.onTermination = { _ in monitor.cancel() }
            }
            await withTaskCancellationHandler {
                monitor.start(queue: queue)
                for await connected in changes { online = connected }
            } onCancel: { monitor.cancel() }
        }
        .onReceive(nextendo?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { accountChanged.toggle() }
        .onAppear { row = actionsWithProfile.first?.rowID }
        .onChange(of: nextendo?.isBusy) { _, busy in if busy == false { checked = true } }
        .onReceive(NotificationCenter.default.publisher(for: .nxProfileInput)) { note in
            if let action = note.object as? GamepadAction { handle(action) }
        }
        .onDisappear {
            nextendo?.isEditingClient = false
            nextendo?.friendToRemove = nil
        }
    }

    @Environment(\.seleneReduceMotion) private var reduceMotion

    private var recent: [ProfilePageLayout<EmptyView>.Recent] {
        viewModel.visibleCatalogGames.compactMap { game -> ProfilePageLayout<EmptyView>.Recent? in
            guard let last = history.lastPlayed(for: game.id) else { return nil }
            return .init(id: game.id, name: game.name, last: last, duration: history.totalDuration(for: game.id))
        }.sorted { ($0.last, $0.name) > ($1.last, $1.name) }.prefix(5).map { $0 }
    }

    private func updateActions(_ updated: [SettingsRowAction]) {
        actions = updated
        if let current = actionsWithProfile.first(where: { $0.rowID == row }) {
            button = min(button, current.buttonCount - 1)
        } else {
            row = actionsWithProfile.first?.rowID
            button = 0
        }
    }

    private func handle(_ action: GamepadAction) {
        guard !settingPIN else { return }
        if let nextendo, nextendo.isEditingClient {
            if action == .cancel { nextendo.isEditingClient = false }
            return
        }
        if let nextendo, nextendo.friendToRemove != nil {
            switch action {
            case .navigateLeft: removalFocus = .left
            case .navigateRight: removalFocus = .right
            case .confirm where removalFocus == .confirm: removeFriend()
            case .confirm, .cancel: nextendo.friendToRemove = nil
            default: break
            }
            return
        }
        if action == .cancel { onClose(); return }
        if action == .menu { onSwitch(); return }
        let rows = actionsWithProfile
        guard let idx = rows.firstIndex(where: { $0.rowID == row }) else { return }
        let current = rows[idx]
        switch action {
        case .navigateUp, .navigateDown:
            let next = idx + (action == .navigateUp ? -1 : 1)
            if rows.indices.contains(next) { row = rows[next].rowID; button = 0 }
        case .navigateLeft, .navigateRight:
            let next = button + (action == .navigateLeft ? -1 : 1)
            if (0..<current.buttonCount).contains(next) { button = next }
        case .confirm where current.isEnabled: current.press(button: button)
        default: break
        }
    }

    private func togglePresence() {
        var updated = profile
        updated.appearsOnline = !profile.sharesPresence
        savePreferences(updated)
    }

    private func toggleGame() {
        var updated = profile
        updated.showsCurrentGame = profile.showsCurrentGame != true
        savePreferences(updated)
    }

    private func savePreferences(_ updated: LocalProfile) {
        if !onUpdate(updated) {
            viewModel.showSettingsNotice(title: L10n.text("Settings not saved"),
                                         message: L10n.text("Your changes could not be saved. Try again."))
        }
    }

    private func cancelPIN() { settingPIN = false; firstPIN = nil }

    private func enterPIN(_ pin: String) -> String? {
        if profile.isLocked {
            return profile.matchesPIN(pin) ? savePIN(nil) : "Incorrect code."
        }
        guard let firstPIN else { self.firstPIN = pin; return nil }
        guard firstPIN == pin else { return "The codes do not match." }
        return savePIN(pin)
    }

    private func savePIN(_ pin: String?) -> String? {
        var updated = profile
        guard updated.setPIN(pin), onUpdate(updated) else { return "Your changes could not be saved. Try again." }
        cancelPIN()
        return nil
    }

    private func removeFriend() {
        guard let nextendo, let friend = nextendo.friendToRemove else { return }
        nextendo.friendToRemove = nil
        nextendo.updateFriend(.remove(pid: friend.id), clientID: settings.settings.nextendoClientID ?? NextendoLaunch.buildClientID)
    }
}

struct ProfileRecentGame: Identifiable {
    let id: UUID
    let name: String
    let last: Date
    let duration: TimeInterval
}

struct ProfilePageLayout<Account: View>: View {
    typealias Recent = ProfileRecentGame
    let profile: LocalProfile
    let presence: ProfilePresence
    let games: [Recent]
    let onClose: () -> Void
    var onSwitch: (() -> Void)? = nil
    var showsAccount = true
    var showsHints = true
    @ViewBuilder let account: () -> Account
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var locale
    @Environment(\.seleneFocusedRowID) private var row

    var body: some View {
        ZStack(alignment: .bottom) {
            SeleneBackdrop().still(true).environment(\.seleneSharesBackdrop, false)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: canvas.u(38)) {
                        HStack(spacing: canvas.u(26)) {
                            ProfilePortrait(profile: profile, size: 106, ring: true)
                            VStack(alignment: .leading, spacing: canvas.u(10)) {
                                Text(profile.name).seleneFont(.profileScreenTitle).accessibilityAddTraits(.isHeader)
                                SeleneStatusDot(text: L10n.text(presence.rawValue), color: presence.color)
                            }
                        }
                        VStack(alignment: .leading, spacing: canvas.u(10)) {
                            section("Recently played")
                            if games.isEmpty {
                                Text(L10n.text("No games played yet.")).seleneFont(.menuCaption).foregroundStyle(SeleneTheme.ink60)
                            }
                            ForEach(games) { game in
                                SeleneOptionRow(icon: .gamepad, title: game.name,
                                                about: game.last.formatted(.dateTime.day().month().locale(locale.formatLocale)),
                                                focused: false) {
                                    Text(LibraryPresentation.duration(game.duration)).seleneFont(.menuCaption)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: canvas.u(10)) {
                            if showsAccount { section("Linked Nextendo account") }
                            account()
                        }
                    }
                    .padding(.top, canvas.u(100))
                    .padding(.bottom, canvas.u(134))
                    .frame(maxWidth: canvas.u(1120))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, canvas.u(70))
                }
                .onChange(of: row) { _, value in
                    if let value { proxy.scrollTo("selene-row-\(value)") }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if showsHints {
                SeleneHintsBar(left: [HintItem(.b, "Back", action: onClose)],
                               right: onSwitch.map { [HintItem(.menu, "Switch profile", keyboard: .text("+"), action: $0)] } ?? [])
            }
        }
        .foregroundStyle(SeleneTheme.ink)
    }

    private func section(_ key: String) -> some View {
        Text(L10n.text(key)).seleneFont(.sectionTitle, .semibold).accessibilityAddTraits(.isHeader)
    }
}
