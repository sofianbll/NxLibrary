import SwiftUI
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
    @ObservedObject var nextendo: NextendoSettings
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var history: PlaySessionStore
    let onClose: () -> Void
    let onAppearOnline: (Bool) -> Void
    let onSwitch: () -> Void
    @State private var actions: [SettingsRowAction] = []
    @State private var row: String?
    @State private var button = 0
    @State private var online: Bool?
    @State private var checked = false
    @State private var removalFocus: SeleneConfirmButton = .cancel

    private var presence: ProfilePresence {
        if online == false { return .offline }
        if nextendo.isBusy && !nextendo.isRefreshingFriends { return .loading }
        if nextendo.status == .expired { return .expired }
        if nextendo.status == .unavailable || nextendo.failure != nil && nextendo.status == .signedOut { return .failed }
        if nextendo.status == .signedIn { return nextendo.account == nil ? .unknown : .connected }
        return checked ? .notLinked : .unknown
    }

    var body: some View {
        ZStack {
            ProfilePageLayout(profile: profile, presence: presence, games: recent, onClose: onClose, onSwitch: onSwitch) {
                SettingsAPISection(viewModel: viewModel, settings: settings, showsMultiplayer: true,
                                   supportsNextendo: true, accountOnly: true, accountOffline: online == false,
                                   appearOnline: Binding(get: { profile.appearsOnline != false }, set: onAppearOnline),
                                   advanced: .constant(false),
                                   onActions: updateActions, nextendo: nextendo)
                    .environment(\.seleneFocusedRowID, row)
                    .environment(\.seleneFocusedButton, button)
            }
            .environment(\.seleneFocusedRowID, row)
            .accessibilityHidden(nextendo.friendToRemove != nil || nextendo.isEditingClient)
            if nextendo.isEditingClient {
                NextendoClientDialog(settings: settings) { nextendo.isEditingClient = false }
            }
            if let friend = nextendo.friendToRemove {
                SeleneTheme.scrim.opacity(0.72).ignoresSafeArea()
                SeleneConfirmDialog(title: L10n.format("Remove %@?", [friend.name]),
                                    message: L10n.text("Remove this friend from your Nextendo account?"),
                                    confirmTitle: L10n.text("Remove"), focus: $removalFocus,
                                    onCancel: { nextendo.friendToRemove = nil }, onConfirm: removeFriend)
                    .onAppear { removalFocus = .cancel }
            }
        }
        .task {
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
        .onChange(of: nextendo.isBusy) { _, busy in if !busy { checked = true } }
        .onReceive(NotificationCenter.default.publisher(for: .nxProfileInput)) { note in
            if let action = note.object as? GamepadAction { handle(action) }
        }
        .onDisappear {
            nextendo.isEditingClient = false
            nextendo.friendToRemove = nil
        }
    }

    private var recent: [ProfilePageLayout<EmptyView>.Recent] {
        viewModel.visibleCatalogGames.compactMap { game -> ProfilePageLayout<EmptyView>.Recent? in
            guard let last = history.lastPlayed(for: game.id) else { return nil }
            return .init(id: game.id, name: game.name, last: last, duration: history.totalDuration(for: game.id))
        }.sorted { ($0.last, $0.name) > ($1.last, $1.name) }.prefix(5).map { $0 }
    }

    private func updateActions(_ updated: [SettingsRowAction]) {
        actions = updated
        if let current = updated.first(where: { $0.rowID == row }) {
            button = min(button, current.buttonCount - 1)
        } else {
            row = updated.first?.rowID
            button = 0
        }
    }

    private func handle(_ action: GamepadAction) {
        if nextendo.isEditingClient {
            if action == .cancel { nextendo.isEditingClient = false }
            return
        }
        if nextendo.friendToRemove != nil {
            switch action {
            case .navigateLeft: removalFocus = .cancel
            case .navigateRight: removalFocus = .confirm
            case .confirm where removalFocus == .confirm: removeFriend()
            case .confirm, .cancel: nextendo.friendToRemove = nil
            default: break
            }
            return
        }
        if action == .cancel { onClose(); return }
        if action == .menu { onSwitch(); return }
        guard let idx = actions.firstIndex(where: { $0.rowID == row }) else { return }
        let current = actions[idx]
        switch action {
        case .navigateUp, .navigateDown:
            let next = idx + (action == .navigateUp ? -1 : 1)
            if actions.indices.contains(next) { row = actions[next].rowID; button = 0 }
        case .navigateLeft, .navigateRight:
            let next = button + (action == .navigateLeft ? -1 : 1)
            if (0..<current.buttonCount).contains(next) { button = next }
        case .confirm where current.isEnabled: current.press(button: button)
        default: break
        }
    }

    private func removeFriend() {
        guard let friend = nextendo.friendToRemove else { return }
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
                            section("Linked Nextendo account")
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
            SeleneHintsBar(left: [HintItem(.b, "Back", action: onClose)],
                           right: onSwitch.map { [HintItem(.menu, "Switch profile", keyboard: .text("+"), action: $0)] } ?? [])
        }
        .foregroundStyle(SeleneTheme.ink)
    }

    private func section(_ key: String) -> some View {
        Text(L10n.text(key)).seleneFont(.sectionTitle, .semibold).accessibilityAddTraits(.isHeader)
    }
}
