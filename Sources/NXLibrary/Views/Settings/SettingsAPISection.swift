import AppKit
import SwiftUI
import NXLibraryCore

/// General, optional connections; moving them here leaves stored credentials and provider behaviour intact.
struct SettingsAPISection: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings: AppSettingsStore
    let supportsNextendo: Bool
    let onActions: ([SettingsRowAction]) -> Void
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneFocusedRowID) private var focusedRow
    @Environment(\.seleneFocusedButton) private var focusedButton
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.nxAppLocale) private var localization
    @ObservedObject private var igdb = IGDBSettings.shared
    @ObservedObject private var nextendo = NextendoSettings.shared
    @State private var friendsExpanded = false
    @State private var copiedCode: String?

    private var clientID: String? { settings.settings.nextendoClientID ?? NextendoLaunch.buildClientID }
    private let accountRowID = "Nextendo"
    private let friendsRowID = "nextendoFriends"
    private let linksRowID = "nextendoLinks"
    private let advancedRowID = "Nextendo client ID"
    private var canActivateNextendo: Bool { !nextendo.isBusy || nextendo.isWaitingForBrowser }
    private var hasFriendCode: Bool { nextendo.account?.friendCode != nil }
    private var showFriends: Bool { nextendo.status == .signedIn && nextendo.account != nil }
    private var friends: [NextendoAccountSnapshot.Friend]? { nextendo.account?.friends }

    var body: some View {
        VStack(alignment: .leading, spacing: canvas.u(8)) {
            Text(L10n.text("Connect optional services to enrich your library with ratings and artwork. Public sources remain available without API keys."))
                .seleneFont(16)
                .foregroundColor(SeleneTheme.ink60)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, canvas.u(8))

            SettingsSubheading(L10n.text("Ratings"))
            SeleneRow("IGDB", subtitle: igdb.message ?? (igdb.isConfigured
                      ? "IGDB connected · Wikidata is the fallback"
                      : "Optional critic scores with your own credentials")) {
                HStack(spacing: canvas.u(18)) {
                    Button(L10n.text(igdb.isConfigured ? "Edit credentials" : "Connect")) { igdb.isEditing = true }
                        .foregroundColor(SeleneTheme.glyph)
                    if igdb.isConfigured {
                        Button(L10n.text("Remove")) { Task { await igdb.remove() } }
                            .foregroundColor(SeleneTheme.ink60).disabled(igdb.isRemoving)
                    }
                }
                .buttonStyle(.plain).seleneFont(15, .semibold)
            }

            SettingsSubheading(L10n.text("Artwork"))
            SeleneButtonRow("SteamGridDB",
                            subtitle: viewModel.hasSteamGridDBKey
                                ? "Key saved · covers, backgrounds, logos and icons in Change artwork"
                                : "Add your free API key to find art in Change artwork",
                            buttonTitle: viewModel.hasSteamGridDBKey ? "Remove key" : "Add key") {
                steamGridDBAction()
            }

            if supportsNextendo { nextendoRows }
        }
        .onAppear {
            publishActions()
            if supportsNextendo { nextendo.check(clientID: clientID) }
        }
        .onChange(of: igdb.revision) { _ in publishActions() }
        .onChange(of: supportsNextendo) { supported in
            if supported { nextendo.check(clientID: clientID) }
            else { endNextendoVisit() }
            publishActions()
        }
        .onChange(of: clientID) { _ in
            if supportsNextendo {
                nextendo.clientChanged()
                publishActions()
            }
        }
        .onChange(of: nextendo.status) { status in
            if status != .signedIn { friendsExpanded = false }
            if supportsNextendo { publishActions() }
        }
        .onChange(of: showFriends) { _ in if supportsNextendo { publishActions() } }
        .onChange(of: hasFriendCode) { _ in if supportsNextendo { publishActions() } }
        .onChange(of: friendsExpanded) { _ in if supportsNextendo { publishActions() } }
        .onChange(of: nextendo.isBusy) { _ in if supportsNextendo { publishActions() } }
        .onChange(of: nextendo.isWaitingForBrowser) { _ in if supportsNextendo { publishActions() } }
        .onDisappear { if supportsNextendo { endNextendoVisit() } }
        .task(id: copiedCode) {
            guard let code = copiedCode else { return }
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            if !Task.isCancelled, copiedCode == code { copiedCode = nil }
        }
    }

    @ViewBuilder private var nextendoRows: some View {
        SettingsSubheading(text("Online play"))
        nextendoAccountRow
        if showFriends {
            let title = friends.map {
                L10n.format("Friends · %lld online out of %lld", [$0.filter { $0.presence != .offline }.count, $0.count],
                            context: localization)
            } ?? text("Friends")
            SeleneButtonRow(title, id: friendsRowID, verbatimTitle: true,
                            buttonTitle: friendsExpanded ? "Hide" : "Show", action: toggleFriends)
                .accessibilityValue(text(friendsExpanded ? "Expanded" : "Collapsed"))
            if friendsExpanded {
                friendsPanel
            }
        }
        SeleneRow("Advanced", id: advancedRowID, subtitle: "Public client ID") {
            Text(settings.settings.nextendoClientID ?? text(clientID == nil ? "Not set" : "Built-in value"))
                .seleneFont(15)
                .foregroundColor(SeleneTheme.ink60)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: canvas.u(200))
            Button(text("Edit")) { nextendo.isEditingClient = true }
                .buttonStyle(.plain)
                .seleneFont(15, .semibold)
                .foregroundColor(SeleneTheme.glyph)
                .disabled(nextendo.isBusy)
        }
    }

    private var nextendoAccountRow: some View {
        let account = nextendo.account
        let country = account?.countryCode.map {
            Locale(identifier: localization.language.rawValue).localizedString(forRegionCode: $0) ?? $0
        }
        let details = [account?.friendCode, country].compactMap { $0 }.joined(separator: " · ")
        let signedOut = nextendo.status == .signedOut
        let buttons = accountButtons
        return SeleneOptionRow(icon: nil, title: nextendo.accountName ?? text("Nextendo"),
                               about: signedOut ? text("Free community online play for compatible nxnative games. Requires a Nextendo account.")
                                   : details.isEmpty ? nil : details,
                               focused: focusedRow == accountRowID,
                               leading: signedOut ? nil : AnyView(NextendoAvatar(pid: account?.avatarPID, image: account?.avatar,
                                                                              revision: nextendo.revision)),
                               titleAccessory: signedOut ? nil : AnyView(accountStatus)) {
            VStack(alignment: .trailing, spacing: canvas.u(4)) {
                if let failure = nextendo.failure {
                    Text(failure.localizedDescription)
                        .seleneFont(15)
                        .foregroundColor(SeleneTheme.danger)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: canvas.u(340), alignment: .trailing)
                } else if nextendo.isWaitingForBrowser || nextendo.isBusy || signedOut {
                    NextendoValue(text: text(nextendo.isWaitingForBrowser ? "Waiting for your browser…"
                                             : nextendo.isBusy ? "Checking…" : "Signed out"))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: canvas.u(8)) { accountActions(buttons) }.fixedSize()
                    VStack(alignment: .trailing, spacing: canvas.u(2)) { accountActions(buttons) }
                }
                .disabled(!canActivateNextendo)
            }
        }
        .id("selene-row-\(accountRowID)")
    }

    private var accountStatus: some View {
        switch nextendo.status {
        case .signedIn: return NextendoPresence(text: text("Nextendo connected"), color: SeleneTheme.success)
        case .expired: return NextendoPresence(text: text("Session expired"), color: SeleneTheme.danger)
        case .signedOut, .unavailable: return NextendoPresence(text: text("Offline"), color: SeleneTheme.ink60)
        }
    }

    private var accountButtons: [NextendoButton] {
        if nextendo.isWaitingForBrowser { return [.init("Cancel", action: nextendo.cancelBrowser)] }
        let signIn = NextendoButton("Sign in…") { nextendo.signIn(clientID: clientID) }
        if nextendo.status == .signedOut { return [signIn] }
        var buttons: [NextendoButton] = []
        if let code = nextendo.account?.friendCode {
            buttons.append(.init(copiedCode == code ? "Copied" : "Copy code",
                                 symbol: copiedCode == code ? "checkmark" : "doc.on.doc", action: copyCode))
        }
        if nextendo.status == .expired { buttons.append(signIn) }
        buttons.append(.init("Check status") { nextendo.check(clientID: clientID) })
        buttons.append(.init("Sign out", action: nextendo.signOut))
        return buttons
    }

    private func accountActions(_ buttons: [NextendoButton]) -> some View {
        ForEach(buttons.indices, id: \.self) { index in
            action(buttons[index], row: accountRowID, index: index, outline: buttons.count > 1)
        }
    }

    private var friendsPanel: some View {
        SelenePanel {
            if let friends, !friends.isEmpty {
                LazyVStack(spacing: canvas.u(8)) {
                    ForEach(friends) { friend in
                        NextendoFriendLine(friend: friend, revision: nextendo.revision)
                    }
                }
            } else {
                NextendoValue(text: text(friends == nil ? "Friends unavailable" : "No friends yet."))
                    .padding(.horizontal, canvas.u(8))
            }
            HStack(spacing: canvas.u(8)) {
                Spacer(minLength: 0)
                action(addFriend, row: linksRowID, index: 0)
                action(openProfile, row: linksRowID, index: 1)
            }
            .id("selene-row-\(linksRowID)")
        }
    }

    private var addFriend: NextendoButton {
        .init("Add a friend", symbol: "arrow.up.right") { openURL(URL(string: "https://nextendo.network/account#form-ajout")!) }
    }

    private var openProfile: NextendoButton {
        .init("Open my profile", symbol: "arrow.up.right") { openURL(URL(string: "https://nextendo.network/account")!) }
    }

    private func action(_ button: NextendoButton, row: String, index: Int, outline: Bool = true) -> some View {
        Button(action: button.action) {
            HStack(spacing: canvas.u(4)) {
                Text(text(button.title))
                if let symbol = button.symbol {
                    Image(systemName: symbol).accessibilityHidden(true)
                }
            }
            .seleneFont(15, .semibold)
            .foregroundColor(SeleneTheme.glyph)
            .padding(.horizontal, canvas.u(8))
            .padding(.vertical, canvas.u(4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if outline && focusedRow == row && focusedButton == index {
                Capsule().strokeBorder(SeleneTheme.focus, lineWidth: canvas.u(2)).allowsHitTesting(false)
            }
        }
    }

    private func toggleFriends() {
        withAnimation(reduceMotion ? nil : SeleneTheme.quick) { friendsExpanded.toggle() }
    }

    private func copyCode() {
        guard let code = nextendo.account?.friendCode, copiedCode != code else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(code, forType: .string) else { SoundEffectService.shared.play(.error); return }
        SoundEffectService.shared.play(.success)
        copiedCode = code
    }

    private func endNextendoVisit() {
        nextendo.endVisit()
        friendsExpanded = false
        copiedCode = nil
    }

    private func text(_ key: String) -> String { L10n.text(key, context: localization) }

    private func steamGridDBAction() {
        if viewModel.hasSteamGridDBKey { viewModel.removeSteamGridDBKey() }
        else { viewModel.isEditingSteamGridDBKey = true }
    }
    private func publishActions() {
        var actions: [SettingsRowAction] = [
            .init(id: "IGDB", title: "IGDB",
                  secondary: igdb.isConfigured ? (title: "Remove", activate: { Task { await igdb.remove() }; return }) : nil) {
                igdb.isEditing = true
            },
            .init(id: "SteamGridDB", title: "SteamGridDB") { steamGridDBAction() },
        ]
        if supportsNextendo {
            let buttons = accountButtons
            actions.append(.init(id: "nextendo", title: "Nextendo", rowID: accountRowID, isEnabled: canActivateNextendo,
                                 secondary: buttons.dropFirst().first.map { ($0.title, $0.action) },
                                 additionalButtons: buttons.dropFirst(2).map(\.action), activate: buttons[0].action))
            if showFriends {
                actions.append(.init(id: friendsRowID, title: "Friends", rowID: friendsRowID, activate: toggleFriends))
                if friendsExpanded {
                    actions.append(.init(id: linksRowID, title: openProfile.title, rowID: linksRowID,
                                         secondary: (openProfile.title, openProfile.action), activate: addFriend.action))
                }
            }
            actions.append(.init(id: "nextendoClientID", title: "Nextendo client ID", rowID: advancedRowID, isEnabled: !nextendo.isBusy) {
                nextendo.isEditingClient = true
            })
        }
        onActions(actions)
    }
}

private struct NextendoButton {
    let title: String
    let symbol: String?
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }
}

private struct NextendoValue: View {
    let text: String

    var body: some View {
        Text(text).seleneFont(15).foregroundColor(SeleneTheme.ink60).lineLimit(1)
    }
}

private struct NextendoPresence: View {
    @Environment(\.seleneCanvas) private var canvas
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: canvas.u(8)) {
            Circle().fill(color).frame(width: canvas.u(7), height: canvas.u(7)).accessibilityHidden(true)
            NextendoValue(text: text)
        }
        .fixedSize()
    }
}

private struct NextendoFriendLine: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var locale
    @State private var resolvedGame: (key: String, title: String)?
    let friend: NextendoAccountSnapshot.Friend
    let revision: UUID
    private var gameKey: String { "\(friend.gameID ?? "")|\(locale.language.rawValue)" }

    var body: some View {
        HStack(spacing: canvas.u(8)) {
            NextendoAvatar(pid: friend.id, initial: String(friend.name.prefix(1)), revision: revision)
            Text(friend.name).seleneFont(15).foregroundColor(SeleneTheme.ink90).lineLimit(1)
            if friend.favorite {
                MaterialIconView(.favorite, size: 16).foregroundColor(SeleneTheme.glyph)
                    .accessibilityLabel(L10n.text("Favorite", context: locale))
            }
            Spacer(minLength: canvas.u(8))
            if friend.presence == .playing, let game = friend.game ?? (resolvedGame?.key == gameKey ? resolvedGame?.title : nil) {
                NextendoValue(text: game).help(game)
            }
            NextendoPresence(text: L10n.text(status, context: locale), color: color)
        }
        .padding(.horizontal, canvas.u(8))
        .padding(.vertical, canvas.u(4))
        .background(SeleneTheme.glass.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: canvas.u(7), style: .continuous))
        .accessibilityElement(children: .combine)
        .task(id: gameKey) {
            guard friend.game == nil, let id = friend.gameID,
                  let title = try? await NextendoAccountService().gameTitle(id: id, language: locale.language),
                  !Task.isCancelled else { return }
            resolvedGame = (gameKey, title)
        }
    }

    private var status: String {
        switch friend.presence {
        case .offline: return "Offline"
        case .online: return "Online"
        case .playing: return "In game"
        }
    }

    private var color: Color {
        switch friend.presence {
        case .offline: return SeleneTheme.ink60
        case .online: return SeleneTheme.success
        case .playing: return SeleneTheme.glyph
        }
    }
}

private struct NextendoAvatar: View {
    @Environment(\.seleneCanvas) private var canvas
    @State private var loaded: (key: String, image: NSImage)?
    let pid: UInt64?
    var image: Data? = nil
    var initial: String? = nil
    let revision: UUID
    private var key: String { "nextendo-avatar|\(revision)|\(pid ?? 0)" }

    var body: some View {
        let side = canvas.u(initial == nil ? 28 : 20)
        ZStack {
            Circle().fill(SeleneTheme.glassSolid)
            if let avatar = image.flatMap(NSImage.init(data:)) ?? TileArtMemo.shared.object(forKey: key as NSString)
                ?? (loaded?.key == key ? loaded?.image : nil) {
                Image(nsImage: avatar).resizable().scaledToFill()
            } else if let initial {
                Text(initial).seleneFont(13, .semibold).foregroundColor(SeleneTheme.ink90)
            } else {
                Image(systemName: "person.fill").seleneFont(16, .semibold).foregroundColor(SeleneTheme.rowIcon)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(SeleneTheme.ink15, lineWidth: canvas.u(1)) }
        .accessibilityHidden(true)
        .task(id: key) {
            guard image == nil, let pid, TileArtMemo.shared.object(forKey: key as NSString) == nil,
                  let data = try? await NextendoAccountService().avatar(pid: pid),
                  !Task.isCancelled, let avatar = NSImage(data: data) else { return }
            TileArtMemo.store(avatar, for: key as NSString)
            loaded = (key, avatar)
        }
    }
}
