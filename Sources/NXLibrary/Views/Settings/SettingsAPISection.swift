import AppKit
import SwiftUI
import NXLibraryCore
import ArcanePorting

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
    @State private var recentExpanded = false
    @State private var friendCode = ""
    @FocusState private var friendCodeFocused: Bool
    @State private var copiedCode: String?

    private var clientID: String? { settings.settings.nextendoClientID ?? NextendoLaunch.buildClientID }
    private let accountRowID = "Nextendo"
    private let friendsRowID = "nextendoFriends"
    private let addRowID = "nextendoAddFriend"
    private let recentRowID = "nextendoRecentPlayers"
    private let linksRowID = "nextendoLinks"
    private let advancedRowID = "Nextendo client ID"
    private var canActivateNextendo: Bool { !nextendo.isBusy || nextendo.isWaitingForBrowser }
    private var hasFriendCode: Bool { nextendo.account?.friendCode != nil }
    private var showFriends: Bool { nextendo.status == .signedIn && nextendo.account != nil }
    private var friendData: NextendoAccountSnapshot? { nextendo.friendsNeedRefresh ? nil : nextendo.account }
    private var friends: [NextendoAccountSnapshot.Friend]? { friendData?.friends }
    private var canUpdateFriends: Bool { !nextendo.isBusy && !nextendo.friendsNeedRefresh && clientID != nil }

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
        .onChange(of: igdb.revision) { publishActions() }
        .onChange(of: supportsNextendo) { _, supported in
            if supported { nextendo.check(clientID: clientID) }
            else { endNextendoVisit() }
            publishActions()
        }
        .onChange(of: clientID) {
            if supportsNextendo {
                nextendo.clientChanged()
                publishActions()
            }
        }
        .onChange(of: nextendo.status) { _, status in
            if status != .signedIn { resetFriendsPanel() }
            if supportsNextendo { publishActions() }
        }
        .onChange(of: showFriends) { if supportsNextendo { publishActions() } }
        .onChange(of: hasFriendCode) { if supportsNextendo { publishActions() } }
        .onChange(of: friendsExpanded) { if supportsNextendo { publishActions() } }
        .onChange(of: recentExpanded) { if supportsNextendo { publishActions() } }
        .onChange(of: nextendo.revision) { if supportsNextendo { publishActions() } }
        .onChange(of: nextendo.friendsNeedRefresh) { if supportsNextendo { publishActions() } }
        .onChange(of: nextendo.submittedFriendCode) { _, submitted in
            if submitted == friendCode { friendCode = "" }
        }
        .onChange(of: focusedRow) { _, row in
            if row != addRowID, friendCodeFocused { friendCodeFocused = false }
        }
        .onChange(of: focusedButton) { _, button in
            if focusedRow == addRowID, button == 1 { friendCodeFocused = false }
        }
        .onChange(of: nextendo.isBusy) { if supportsNextendo { publishActions() } }
        .onChange(of: nextendo.isWaitingForBrowser) { if supportsNextendo { publishActions() } }
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
            addFriendRow
            if let message = nextendo.friendMessage {
                friendNotice(message.key, isError: message.isError)
            }
            if nextendo.friendsNeedRefresh, nextendo.friendMessage?.isError == false {
                friendNotice("Could not refresh the lists. Use Check status.", isError: true)
            }
            if let requests = friendData?.requests, !requests.isEmpty {
                SettingsSubheading(text("Received requests"))
                LazyVStack(spacing: canvas.u(8)) {
                    ForEach(requests) { player in
                        playerLine(player.name, row: requestRowID(player.id), buttons: requestButtons(player.id))
                    }
                }
            }
            if let sent = friendData?.sent, !sent.isEmpty {
                SettingsSubheading(text("Sent requests"))
                LazyVStack(spacing: canvas.u(8)) {
                    ForEach(sent) { player in
                        playerLine(player.name, row: "nextendoSent-\(player.id)", detail: text("Pending"))
                    }
                }
            }
            if friendData != nil, friendData?.requests == nil || friendData?.sent == nil {
                friendNotice("Friend requests unavailable", isError: true)
            }
            SeleneButtonRow("Recently played with", id: recentRowID, buttonTitle: recentExpanded ? "Hide" : "Show",
                            action: toggleRecent)
                .accessibilityValue(text(recentExpanded ? "Expanded" : "Collapsed"))
            if recentExpanded { recentPlayers }
            if let friends, !friends.isEmpty {
                LazyVStack(spacing: canvas.u(8)) {
                    ForEach(friends) { friend in
                        let row = friendRowID(friend.id)
                        NextendoFriendLine(friend: friend, revision: nextendo.revision) {
                            action(removeButton(friend), row: row, index: 0)
                                .disabled(!canUpdateFriends)
                        }
                        .id("selene-row-\(row)")
                    }
                }
            } else {
                NextendoValue(text: text(friends == nil ? "Friends unavailable" : "No friends yet."))
                    .padding(.horizontal, canvas.u(8))
            }
            HStack(spacing: canvas.u(8)) {
                Spacer(minLength: 0)
                action(openProfile, row: linksRowID, index: 0)
            }
            .id("selene-row-\(linksRowID)")
        }
    }

    private var addFriendRow: some View {
        SeleneRow("Add a friend", id: addRowID) {
            TextField(text("Friend code"), text: $friendCode, prompt: Text(verbatim: "SW-0000-0000-0000"))
                .textFieldStyle(.plain)
                .focused($friendCodeFocused)
                .onSubmit(sendFriendCode)
                .accessibilityLabel(text("Friend code"))
                .seleneFont(15)
                .foregroundColor(SeleneTheme.ink)
                .padding(canvas.u(8))
                .frame(maxWidth: canvas.u(195))
                .background(RoundedRectangle(cornerRadius: canvas.u(7)).fill(SeleneTheme.glassLight))
                .seleneRowFocus(friendCodeFocused || (focusedRow == addRowID && focusedButton == 0), radius: canvas.u(7))
            action(.init("Add", action: sendFriendCode), row: addRowID, index: 1)
        }
        .disabled(!canUpdateFriends)
    }

    private var recentPlayers: some View {
        Group {
            if let players = friendData?.recentPlayers, !players.isEmpty {
                LazyVStack(spacing: canvas.u(8)) {
                    ForEach(players) { player in
                        playerLine(player.name, row: recentPlayerRowID(player.id),
                                   buttons: recentButton(player).map { [$0] } ?? []) {
                            NextendoGameTitle(name: player.game, id: player.gameID)
                        }
                    }
                }
            } else {
                NextendoValue(text: text(friendData?.recentPlayers == nil ? "Recent players unavailable" : "No recent players."))
                    .padding(.horizontal, canvas.u(8))
            }
        }
    }

    private func playerLine(_ name: String, row: String, detail: String? = nil, buttons: [NextendoButton] = [],
                            @ViewBuilder game: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: canvas.u(8)) {
            Text(name).seleneFont(15).foregroundColor(SeleneTheme.ink90).lineLimit(1)
            Spacer(minLength: canvas.u(8))
            if let detail { NextendoValue(text: detail) }
            game()
            ForEach(buttons.indices, id: \.self) { index in
                action(buttons[index], row: row, index: index)
                    .disabled(!canUpdateFriends)
            }
        }
        .padding(.horizontal, canvas.u(8))
        .padding(.vertical, canvas.u(4))
        .id("selene-row-\(row)")
    }

    private func friendNotice(_ key: String, isError: Bool) -> some View {
        Text(text(key))
            .seleneFont(15)
            .foregroundColor(isError ? SeleneTheme.danger : SeleneTheme.ink90)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, canvas.u(8))
    }

    private func sendFriendCode() {
        guard canUpdateFriends else { return }
        updateFriend(.send(code: friendCode))
    }

    private func requestButtons(_ pid: UInt64) -> [NextendoButton] {
        [.init("Accept") { updateFriend(.accept(pid: pid)) },
         .init("Decline") { updateFriend(.decline(pid: pid)) }]
    }

    private func removeButton(_ friend: NextendoAccountSnapshot.Friend) -> NextendoButton {
        .init("Remove friend") {
            guard canUpdateFriends else { return }
            friendCodeFocused = false
            nextendo.friendToRemove = friend
        }
    }

    private func recentButton(_ player: NextendoAccountSnapshot.Player) -> NextendoButton? {
        guard friendData?.canAdd(player) == true, let code = player.friendCode else { return nil }
        return .init("Add") { updateFriend(.send(code: code)) }
    }

    private func updateFriend(_ action: NextendoFriendAction) {
        friendCodeFocused = false
        nextendo.updateFriend(action, clientID: clientID)
    }

    private func requestRowID(_ pid: UInt64) -> String { "nextendoRequest-\(pid)" }
    private func friendRowID(_ pid: UInt64) -> String { "nextendoFriend-\(pid)" }
    private func recentPlayerRowID(_ pid: UInt64) -> String { "nextendoRecent-\(pid)" }

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

    private func toggleRecent() {
        withAnimation(reduceMotion ? nil : SeleneTheme.quick) { recentExpanded.toggle() }
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
        resetFriendsPanel()
        copiedCode = nil
    }

    private func resetFriendsPanel() {
        friendsExpanded = false
        recentExpanded = false
        friendCode = ""
        friendCodeFocused = false
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
                    actions.append(.init(id: addRowID, title: "Add a friend", rowID: addRowID, isEnabled: canUpdateFriends,
                                         secondary: ("Add", sendFriendCode)) { friendCodeFocused = true })
                    for player in friendData?.requests ?? [] {
                        actions.append(friendActionRow(requestRowID(player.id), buttons: requestButtons(player.id)))
                    }
                    actions.append(.init(id: recentRowID, title: "Recently played with", rowID: recentRowID, activate: toggleRecent))
                    if recentExpanded {
                        for player in friendData?.recentPlayers ?? [] {
                            if let button = recentButton(player) {
                                actions.append(friendActionRow(recentPlayerRowID(player.id), buttons: [button]))
                            }
                        }
                    }
                    for friend in friends ?? [] {
                        actions.append(friendActionRow(friendRowID(friend.id), buttons: [removeButton(friend)]))
                    }
                    actions.append(.init(id: linksRowID, title: openProfile.title, rowID: linksRowID, activate: openProfile.action))
                }
            }
            actions.append(.init(id: "nextendoClientID", title: "Nextendo client ID", rowID: advancedRowID, isEnabled: !nextendo.isBusy) {
                nextendo.isEditingClient = true
            })
        }
        onActions(actions)
    }

    private func friendActionRow(_ row: String, buttons: [NextendoButton]) -> SettingsRowAction {
        .init(id: row, title: buttons[0].title, rowID: row, isEnabled: canUpdateFriends,
              secondary: buttons.dropFirst().first.map { ($0.title, $0.action) }, activate: buttons[0].action)
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

private struct NextendoFriendLine<Trailing: View>: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var locale
    let friend: NextendoAccountSnapshot.Friend
    let revision: UUID
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: canvas.u(8)) {
            NextendoAvatar(pid: friend.id, initial: String(friend.name.prefix(1)), revision: revision)
            Text(friend.name).seleneFont(15).foregroundColor(SeleneTheme.ink90).lineLimit(1)
            if friend.favorite {
                MaterialIconView(.favorite, size: 16).foregroundColor(SeleneTheme.glyph)
                    .accessibilityLabel(L10n.text("Favorite", context: locale))
            }
            Spacer(minLength: canvas.u(8))
            if friend.presence == .playing {
                NextendoGameTitle(name: friend.game, id: friend.gameID)
            }
            NextendoPresence(text: L10n.text(status, context: locale), color: color)
            trailing()
        }
        .padding(.horizontal, canvas.u(8))
        .padding(.vertical, canvas.u(4))
        .background(SeleneTheme.glass.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: canvas.u(7), style: .continuous))
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

private struct NextendoGameTitle: View {
    @Environment(\.nxAppLocale) private var locale
    @State private var resolved: (key: String, title: String)?
    let name: String?
    let id: String?
    private var key: String { "\(id ?? "")|\(locale.language.rawValue)" }

    var body: some View {
        Group {
            if let title = name ?? (resolved?.key == key ? resolved?.title : nil) {
                NextendoValue(text: title).help(title)
            }
        }
        .task(id: key) {
            guard name == nil, let id,
                  let title = try? await NextendoAccountService().gameTitle(id: id, language: locale.language),
                  !Task.isCancelled else { return }
            resolved = (key, title)
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
