import SwiftUI
import Combine
import NXLibraryCore
import ArcanePorting

extension Notification.Name {
    static let nxProfileCardsSaveFailed = Self("NXProfileCardsSaveFailed")
}

struct ProfilePage: View {
    enum Focus: Hashable {
        case edit, change, account, lock, card(ProfilePageCard), game(ProfilePageCard, UUID), achievement(UUID, String)
    }

    let profile: LocalProfile
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var history: PlaySessionStore
    let artwork: ArtworkStore
    let nextendo: NextendoSettings?
    @ObservedObject var router: AppRouter
    @Binding var focus: Focus?
    var isGuest = false
    let onEdit: () -> Void
    let onSwitch: () -> Void
    let onAccount: () -> Void

    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @Environment(\.nxAppLocale) private var locale
    @Environment(\.seleneBackdropStyle) private var backdrop
    @ObservedObject private var theme = ThemeStore.shared
    @State private var accountRevision = false
    @State private var frames: [Focus: CGRect] = [:]
    @State private var achievement: AchievementEntry?
    @State private var achievementScreen: AchievementsScreenModel?
    @State private var showFriends = false
    @State private var friendIndex = 0

    private struct AchievementEntry {
        let game: CatalogGame
        let summary: AchievementSummary
    }

    private struct PageData {
        let now: Date
        let activity: [UUID: CarriedPlaytime]
        let week: ActivitySummary
        let games: [CatalogGame]
        let achievements: [AchievementEntry]

        func games(for card: ProfilePageCard) -> [CatalogGame] {
            card.games(in: games, activity: activity, week: week, now: now)
        }
    }

    private struct Frames: PreferenceKey {
        static let defaultValue: [Focus: CGRect] = [:]
        static func reduce(value: inout [Focus: CGRect], nextValue: () -> [Focus: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
        }
    }

    private var account: NextendoAccountSnapshot? {
        nextendo?.status == .signedIn ? nextendo?.account : nil
    }

    private var cards: [ProfilePageCard] {
        (profile.pageCards ?? .init()).visible(hasAccount: account != nil)
    }

    private var pageData: PageData {
        let now = Date.now
        let games = viewModel.visibleCatalogGames
        return .init(now: now, activity: history.profileActivity(at: now),
                     week: Activity.summary(sessions: history.sessions, now: now, calendar: .current),
                     games: games, achievements: games.compactMap { game in
            guard let native = game.nxnativeGame,
                  let summary = viewModel.localAchievementSummary(for: native, profile: profile.id) else { return nil }
            return .init(game: game, summary: summary)
        })
    }

    private var style: SeleneBackdropStyle {
        var style = backdrop
        if let url = theme.wallpaper(for: profile.look.wallpaper)?.url, profile.look.wallpaper != nil {
            style.wallpaperURL = url
            style.sizing = profile.look.sizing
        }
        return style
    }

    private var gap: CGFloat { canvas.u(SeleneTokens.Space.large) }
    private var layoutScale: CGFloat {
        max(SeleneTokens.Text.metadata.rawValue / SeleneTokens.Text.body.rawValue,
            canvas.size.height / SeleneCanvas.design.height)
    }
    private var radius: CGFloat { canvas.u(SeleneTokens.Radius.card) }
    private var defaultFocus: Focus { isGuest ? .change : .edit }
    private var ownsPage: Bool { !viewModel.profileOwnsInput && !router.isMenuPresented && !viewModel.isGameOptionsOpen }

    var body: some View {
        let _ = accountRevision
        let data = pageData
        ZStack(alignment: .bottom) {
            SeleneBackdrop(still: true)
                .environment(\.seleneBackdropStyle, style)
            page(data)
                .seleneOverlayOwnership(!showFriends && achievementScreen == nil)
            if showFriends { friendsDetail }
            if let achievement, let screen = achievementScreen {
                achievementDetail(achievement, screen)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(SeleneTheme.ink)
        .environment(\.seleneMinimumFont, SeleneTokens.Text.metadata.rawValue)
        .animation(Motion.screen(reduceMotion), value: achievementScreen != nil)
        .animation(Motion.overlay(reduceMotion), value: showFriends)
        .onChange(of: achievementScreen != nil) { _, open in router.isScreenshotViewerOpen = open }
        .onDisappear { if achievementScreen != nil { router.isScreenshotViewerOpen = false } }
        .onReceive(nextendo?.objectWillChange.map { true }.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()) { _ in
            accountRevision.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nxProfileInput)) { note in
            guard ownsPage, router.route == .profile, let action = note.object as? GamepadAction else { return }
            handle(action, data: data)
        }
        .onChange(of: nextendo?.status) { if nextendo?.status != .signedIn { showFriends = false } }
    }

    private func page(_ data: PageData) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let inset = min(canvas.u(SeleneTokens.Space.stageGutter),
                                geometry.size.width * SeleneTokens.Space.stageGutter / SeleneCanvas.design.width)
                let width = max(0, geometry.size.width - inset * 2)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: gap) {
                            hero(data, width: width)
                            sections(data, width: width)
                        }
                        .padding(.horizontal, inset)
                        .padding(.vertical, gap)
                        .coordinateSpace(.named("profile-page"))
                    }
                    .onChange(of: focus, initial: true) { _, next in
                        if let next { withAnimation(Motion.focus(reduceMotion)) { proxy.scrollTo(next) } }
                        else { focus = defaultFocus }
                    }
                    .onPreferenceChange(Frames.self) { current in
                        let initial = frames.isEmpty
                        frames = current
                        if let focus, !current.isEmpty {
                            if current[focus] == nil { self.focus = defaultFocus }
                            else if initial { proxy.scrollTo(focus) }
                        }
                    }
                }
            }
            if ownsPage && !showFriends && achievementScreen == nil {
                SeleneHintsBar(left: [HintItem(.b, "Back", action: router.back)],
                               right: (isGuest ? [] : [HintItem(.y, "Edit profile", action: onEdit)])
                               + [HintItem(.a, "Open", action: { activate(focus ?? defaultFocus, data: data) })])
            }
        }
    }

    private func hero(_ data: PageData, width: CGFloat) -> some View {
        let most = data.games(for: .mostPlayed).first
        return VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                ProfilePortrait(profile: profile, size: SeleneTokens.Space.stageGutter, ring: true)
                VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.compact)) {
                    Text(L10n.text("My profile")).seleneFont(.metadata).foregroundStyle(SeleneTheme.ink75)
                    Text(profile.name).seleneFont(.heroTitle, .semibold).accessibilityAddTraits(.isHeader)
                    if let account, profile.sharesPresence, nextendo?.presenceShared == true {
                        SeleneStatusDot(text: L10n.text("Nextendo connected") + " · " + account.name,
                                        color: SeleneTheme.statusOK)
                    }
                }
                Spacer(minLength: 0)
            }
            let statsWidth = layoutScale * SeleneTokens.Space.transferMeasure
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .leading),
                                     count: width >= statsWidth ? 4 : 2),
                      alignment: .leading, spacing: gap) {
                stat("Playtime", LibraryPresentation.duration(data.activity.values.reduce(0) { $0 + $1.duration }))
                stat("This week", LibraryPresentation.duration(data.week.thisWeek))
                stat("Games", data.games.count.formatted(.number.locale(locale.formatLocale)))
                if let date = profile.createdAt {
                    stat("Member since", date.formatted(.dateTime.month(.abbreviated).year().locale(locale.formatLocale)))
                }
            }
            .frame(maxWidth: statsWidth, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: canvas.u(SeleneTokens.Space.small)) { pills(data) }
                VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.small)) { pills(data) }
            }
            if let most, let played = data.activity[most.id] {
                VStack(alignment: .trailing, spacing: canvas.u(SeleneTokens.Space.hairline)) {
                    Text(L10n.text("Most played")).seleneFont(.metadata).foregroundStyle(SeleneTheme.ink75)
                    Text(most.name).seleneFont(.sectionTitle, .semibold)
                    Text(LibraryPresentation.duration(played.duration)).seleneFont(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(gap)
        .background {
            ZStack {
                SeleneTheme.glassLight
                if let most {
                    ProfileGameArt(game: most, artwork: artwork, metadata: viewModel.store.storeMetadata[most.id])
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [SeleneTheme.scrim45, SeleneTheme.scrim], startPoint: .top, endPoint: .bottom)
                        }
                        .mask(alignment: .trailing) {
                            HStack(spacing: 0) {
                                Color.clear
                                LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                                Color.white
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func pills(_ data: PageData) -> some View {
        if !isGuest { pill("Edit profile", icon: "pencil", id: .edit, data: data) }
        pill("Switch profile", icon: "arrow.left.arrow.right", id: .change, data: data)
        if nextendo != nil { pill("Nextendo settings", icon: "gearshape", id: .account, data: data) }
        else if !isGuest { pill("Profile lock", icon: "lock", id: .lock, data: data) }
    }

    private func pill(_ title: String, icon: String, id: Focus, data: PageData) -> some View {
        button(id, data: data, radius: canvas.u(SeleneTokens.Radius.field)) {
            Label(L10n.text(title), systemImage: icon)
                .seleneFont(.caption, .medium)
                .padding(.horizontal, canvas.u(SeleneTokens.Space.control))
                .padding(.vertical, canvas.u(SeleneTokens.Space.small))
                .background(SeleneTheme.ink15, in: Capsule())
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.hairline)) {
            Text(L10n.text(title)).seleneFont(.metadata, .medium).foregroundStyle(SeleneTheme.ink75)
            Text(value).seleneFont(.selectionTitle, .semibold).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func sections(_ data: PageData, width: CGFloat) -> some View {
        if let index = cards.firstIndex(of: .friends),
           let units = ProfilePageCards.friendsColumnWidth(available: width / layoutScale) {
            let narrow = units * layoutScale
            let left = Array(cards.filter { $0 != .friends }.prefix(max(1, index)))
            let rest = cards.filter { $0 != .friends && !left.contains($0) }
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    ForEach(left) { section($0, data: data, width: width - narrow - gap) }
                }
                .frame(maxWidth: .infinity)
                section(.friends, data: data, width: narrow).frame(width: narrow)
            }
            ForEach(rest) { section($0, data: data, width: width) }
        } else {
            ForEach(cards) { section($0, data: data, width: width) }
        }
    }

    private func section(_ card: ProfilePageCard, data: PageData, width: CGFloat) -> some View {
        let count = ProfilePageCards.columns(width: width / layoutScale)
        let tileWidth = max(0, (width - gap * CGFloat(count - 1)) / CGFloat(count))
        let items = data.games(for: card)
        return VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.small)) {
            button(.card(card), data: data, radius: radius) {
                HStack {
                    Text(L10n.text(card.title)).seleneFont(.sectionTitle, .semibold)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(SeleneTheme.ink75)
                }
                .padding(.vertical, canvas.u(SeleneTokens.Space.tight))
            }
            .accessibilityAddTraits(.isHeader)
            switch card {
            case .friends:
                button(.card(card), data: data, radius: radius, tracked: false) {
                    friendsList(limit: 4)
                }
            case .achievements:
                achievements(data, columns: count, tileWidth: tileWidth)
            case .week:
                button(.card(card), data: data, radius: radius, tracked: false) { week(data) }
            default:
                if items.isEmpty {
                    empty("No games in this view.")
                } else {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(items.prefix(count)) { game in
                            tile(game, card: card, data: data).frame(width: tileWidth)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ game: CatalogGame, card: ProfilePageCard, data: PageData) -> some View {
        button(.game(card, game.id), data: data, radius: radius) {
            Rectangle().fill(SeleneTheme.glass)
                .aspectRatio(SeleneCanvas.design.width / SeleneCanvas.design.height, contentMode: .fit)
                .overlay {
                    ProfileGameArt(game: game, artwork: artwork, metadata: viewModel.store.storeMetadata[game.id])
                    LinearGradient(colors: [.clear, SeleneTheme.scrim], startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .topLeading) {
                    if let activity = data.activity[game.id] {
                        Label(LibraryPresentation.duration(activity.duration), systemImage: "clock")
                            .seleneFont(.metadata, .semibold)
                            .padding(canvas.u(SeleneTokens.Space.compact))
                            .background(SeleneTheme.glassSolid, in: Capsule())
                            .padding(canvas.u(SeleneTokens.Space.small))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.seam)) {
                        if let date = data.activity[game.id]?.lastPlayed {
                            Text(date.formatted(.dateTime.day().month(.abbreviated).locale(locale.formatLocale)))
                                .seleneFont(.metadata).foregroundStyle(SeleneTheme.ink75)
                        }
                        Text(game.name).seleneFont(.body, .semibold).lineLimit(2)
                    }
                    .padding(canvas.u(SeleneTokens.Space.small))
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
        }
        .accessibilityLabel(game.name)
        .accessibilityValue(data.activity[game.id].map { LibraryPresentation.duration($0.duration) } ?? "")
    }

    private func week(_ data: PageData) -> some View {
        let peak = max(1, data.week.perDay.max() ?? 0)
        let formatter = DateFormatter()
        formatter.locale = locale.formatLocale
        let labels = formatter.shortStandaloneWeekdaySymbols ?? []
        return HStack(alignment: .bottom, spacing: canvas.u(SeleneTokens.Space.compact)) {
            ForEach(data.week.perDay.indices, id: \.self) { index in
                let day = labels.count == data.week.perDay.count ? labels[(index + 1) % labels.count] : ""
                let duration = data.week.perDay[index]
                VStack(spacing: canvas.u(SeleneTokens.Space.compact)) {
                    RoundedRectangle(cornerRadius: canvas.u(SeleneTokens.Radius.cover))
                        .fill(duration > 0 ? SeleneTheme.focus : SeleneTheme.ink25)
                        .frame(width: canvas.u(SeleneTokens.Space.group),
                               height: canvas.u(max(SeleneTokens.Space.hairline, SeleneTokens.Space.chromeGutter * duration / peak)))
                    Text(day).seleneFont(.metadata).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day)
                .accessibilityValue(LibraryPresentation.duration(duration))
                .help(LibraryPresentation.duration(duration))
            }
        }
        .padding(gap)
        .background(SeleneTheme.glass, in: RoundedRectangle(cornerRadius: radius))
    }

    @ViewBuilder private func achievements(_ data: PageData, columns count: Int, tileWidth: CGFloat) -> some View {
        let total = data.achievements.reduce(0) { $0 + $1.summary.total }
        let unlocked = data.achievements.reduce(0) { $0 + $1.summary.unlocked }
        if total == 0 {
            empty("No local achievements available.")
        } else {
            let recent = data.achievements.flatMap { entry in entry.summary.rows(.unlocked).map { (entry.game, $0) } }
                .sorted { ($0.1.unlockedAt ?? .distantPast) > ($1.1.unlockedAt ?? .distantPast) }
            HStack(alignment: .top, spacing: gap) {
                button(.card(.achievements), data: data, radius: radius, tracked: false) {
                    surface {
                        stat("Overall progress", "\(unlocked) / \(total)")
                        AchievementProgressBar(fraction: Double(unlocked) / Double(total), height: SeleneTokens.Space.hairline,
                                               track: SeleneTheme.ink25)
                    }
                }
                .frame(width: tileWidth)
                ForEach(Array(recent.prefix(count - 1).enumerated()), id: \.offset) { _, item in
                    achievementTile(item.1, game: item.0, data: data).frame(width: tileWidth)
                }
            }
            if count == 1, let (game, row) = recent.first { achievementTile(row, game: game, data: data) }
        }
    }

    private func achievementTile(_ row: AchievementRow, game: CatalogGame, data: PageData) -> some View {
        button(.achievement(game.id, row.id), data: data, radius: radius) {
            surface {
                Label(row.name, systemImage: row.icon ?? "trophy")
                    .seleneFont(.body, .semibold)
                Text(row.description).seleneFont(.metadata).foregroundStyle(SeleneTheme.ink75)
                if let date = row.unlockedAt {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).locale(locale.formatLocale)))
                        .seleneFont(.metadata).foregroundStyle(SeleneTheme.ink75)
                }
            }
        }
    }

    private func friendText(_ friend: NextendoAccountSnapshot.Friend) -> String {
        switch friend.presence {
        case .offline: return L10n.text("Offline")
        case .online: return L10n.text("Online")
        case .playing: return friend.game ?? L10n.text("Playing")
        }
    }

    @ViewBuilder private func friendsList(limit: Int? = nil) -> some View {
        if let friends = account?.friends {
            if friends.isEmpty {
                empty("No friends yet.")
            } else {
                surface {
                    ForEach(Array(friends.prefix(limit ?? friends.count).enumerated()), id: \.element.id) { index, friend in
                        friendRow(friend)
                            .seleneRowFocus(limit == nil && friendIndex == index, radius: radius)
                            .id(index)
                    }
                }
            }
        } else {
            empty("Friends list unavailable.")
        }
    }

    private func friendRow(_ friend: NextendoAccountSnapshot.Friend) -> some View {
        HStack(spacing: canvas.u(SeleneTokens.Space.small)) {
            ZStack {
                Circle().strokeBorder(SeleneTheme.ink25).background(SeleneTheme.glassSolid, in: Circle())
                Text(String(friend.name.prefix(1))).seleneFont(.caption, .semibold)
            }
            .frame(width: canvas.u(SeleneTokens.Space.section), height: canvas.u(SeleneTokens.Space.section))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.seam)) {
                Text(friend.name).seleneFont(.body, .semibold)
                SeleneStatusDot(text: friendText(friend),
                                color: friend.presence == .offline ? SeleneTheme.ink60 : SeleneTheme.statusOK)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var friendsDetail: some View {
        VStack(spacing: gap) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: gap) {
                        Text(L10n.text("Friends")).seleneFont(.screenTitle, .semibold).accessibilityAddTraits(.isHeader)
                        friendsList()
                    }
                    .frame(maxWidth: canvas.u(SeleneTokens.Space.transferMeasure))
                    .padding(gap)
                }
                .onChange(of: friendIndex) {
                    withAnimation(Motion.focus(reduceMotion)) { proxy.scrollTo(friendIndex) }
                }
            }
            SeleneHintsBar(left: [HintItem(.b, "Back", action: { showFriends = false })],
                           right: [HintItem(.a, "Nextendo settings", action: onAccount)])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SeleneTheme.scrim)
        .transition(.opacity)
    }

    private func achievementDetail(_ entry: AchievementEntry, _ screen: AchievementsScreenModel) -> some View {
        AchievementsScreen(model: screen, game: entry.game, summary: entry.summary, art: nil,
                           onFilter: { screen.setFilter($0, summary: entry.summary) },
                           onShiftFilter: { screen.shiftFilter(by: $0, summary: entry.summary) },
                           onCycleOrder: {}, onFocus: { index in
            if screen.state.index == index { _ = screen.openDetail() } else { screen.focus(index) }
        }, onOpen: { _ = screen.openDetail() }, onCloseDetail: screen.closeDetail,
                           onClose: { achievementScreen = nil })
    }

    private func empty(_ title: String) -> some View {
        surface { Text(L10n.text(title)).seleneFont(.caption).foregroundStyle(SeleneTheme.ink75) }
    }

    private func surface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.small), content: content)
            .padding(canvas.u(SeleneTokens.Space.panel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SeleneTheme.glass, in: RoundedRectangle(cornerRadius: radius))
    }

    private func button<Content: View>(_ id: Focus, data: PageData, radius: CGFloat, tracked: Bool = true,
                                       @ViewBuilder content: () -> Content) -> some View {
        Button {
            focus = id
            activate(id, data: data)
        } label: {
            content().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .seleneRowFocus(tracked && focus == id, radius: radius)
        .background {
            if tracked {
                GeometryReader { geometry in
                    Color.clear.preference(key: Frames.self, value: [id: geometry.frame(in: .named("profile-page"))])
                }
            }
        }
        .id(tracked ? id : nil)
    }

    private func activate(_ id: Focus, data: PageData) {
        switch id {
        case .edit: onEdit()
        case .change: onSwitch()
        case .account, .lock: onAccount()
        case .card(.friends):
            friendIndex = 0
            showFriends = account != nil
        case .card(.achievements): openAchievements(data.achievements.max {
            ($0.summary.lastUnlockedAt ?? .distantPast) < ($1.summary.lastUnlockedAt ?? .distantPast)
        })
        case .achievement(let id, let row): openAchievements(data.achievements.first { $0.game.id == id }, row: row)
        case .card(let card):
            viewModel.librarySelection.query.filter = .all
            viewModel.librarySelection.query.searchText = ""
            router.navigate(to: .profileCollection(card))
        case .game(_, let id):
            guard let game = data.games.first(where: { $0.id == id }) else { return }
            if game.nxnativeGame != nil { router.showDetail(id) }
            else {
                router.openSpotlightDetails(id, returningTo: viewModel.spotlight.selectedKey)
            }
        }
    }

    private func openAchievements(_ entry: AchievementEntry?, row: String? = nil) {
        guard let entry else { return }
        let ids = entry.summary.rows(.all).map(\.id)
        let screen = AchievementsScreenModel(ids: ids)
        if let row, let index = ids.firstIndex(of: row) { screen.focus(index); _ = screen.openDetail() }
        achievement = entry
        achievementScreen = screen
    }

    private func handle(_ action: GamepadAction, data: PageData) {
        if let achievement, let screen = achievementScreen {
            guard action != .contextAction else { return }
            if screen.handle(action, summary: achievement.summary) == .close { achievementScreen = nil }
            return
        }
        if showFriends {
            if action == .cancel { showFriends = false }
            if action == .confirm { onAccount() }
            if action == .navigateUp || action == .navigateDown {
                friendIndex = min(max(0, friendIndex + (action == .navigateUp ? -1 : 1)),
                                  max(0, (account?.friends?.count ?? 0) - 1))
            }
            return
        }
        let current = focus ?? defaultFocus
        switch action {
        case .cancel: router.back()
        case .confirm: activate(current, data: data)
        case .menu: router.isMenuPresented = true
        case .menuHold: router.openSettings(.profiles)
        case .contextAction where !isGuest: focus = .edit; onEdit()
        case .tabNext, .tabPrevious:
            let ordered = frames.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }.map(\.key)
            guard let index = ordered.firstIndex(of: current) else { return }
            let next = index + (action == .tabNext ? 1 : -1)
            if ordered.indices.contains(next) { focus = ordered[next] }
        case .navigateUp, .navigateDown, .navigateLeft, .navigateRight:
            guard let origin = frames[current] else { focus = defaultFocus; return }
            let vertical = action == .navigateUp || action == .navigateDown
            let forward = action == .navigateDown || action == .navigateRight
            let direction: CGFloat = forward ? 1 : -1
            let candidates = frames.compactMap { id, rect -> (Focus, CGFloat, CGFloat)? in
                let primary = vertical ? rect.midY - origin.midY : rect.midX - origin.midX
                let secondary = vertical ? rect.midX - origin.midX : rect.midY - origin.midY
                guard primary * direction > canvas.u(SeleneTokens.Space.compact) else { return nil }
                if !vertical && !rect.intersects(CGRect(x: rect.minX, y: origin.minY, width: rect.width, height: origin.height)) { return nil }
                return (id, abs(primary), abs(secondary))
            }
            if let next = candidates.min(by: { ($0.1, $0.2) < ($1.1, $1.2) })?.0 {
                focus = next
                SoundEffectService.shared.play(.focus)
            }
        default: break
        }
    }
}

private struct ProfileGameArt: View {
    let game: CatalogGame
    let artwork: ArtworkStore
    let metadata: NintendoStoreMetadata?
    @Environment(\.catalogPersonalizations) private var personalizations
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @State private var image: NSImage?

    private var played: PlayedGame { game.nxnativeGame.map(PlayedGame.nxnative) ?? .steam(game) }

    var body: some View {
        Color.clear.overlay {
            if let art = image ?? GameArtLoader.shared.cachedHero(for: played) {
                Image(nsImage: art).resizable().scaledToFill()
            } else if let game = game.nxnativeGame {
                Image(nsImage: GameIconProvider.icon(for: game)).resizable().scaledToFit()
            } else {
                Image(systemName: "gamecontroller").seleneFont(.heroTitle).foregroundStyle(SeleneTheme.ink25)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .task(id: game.id) {
            image = nil
            let art = await GameArtLoader.shared.hero(for: played, metadata: metadata, artwork: artwork,
                                                      personalizations: personalizations)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.detailArt(reduceMotion)) { image = art }
        }
    }
}
