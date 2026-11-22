import ArcanePorting
import NXLibraryCore
import SwiftUI

struct PersonalStoreView: View {
    @Environment(\.seleneCanvas) var canvas
    @Environment(\.seleneReduceMotion) var reduced
    @Environment(\.nxAppLocale) private var locale
    @Environment(\.catalogPersonalizations) private var personalizations
    @ObservedObject var app: AppViewModel
    @ObservedObject var cloud: CloudLibraryModel
    @ObservedObject var router: AppRouter
    let artwork: ArtworkStore
    let showsHints: Bool
    let review: (PortedGame) -> Void

    struct Item: Identifiable, Equatable {
        let game: PortedGame
        let action: PersonalStore.Action
        var id: UUID { game.id }
    }
    struct Budget {
        let item: Item
        let offer: PersonalStore.Offer
        let bytes: Int64
        let destination: URL
        let free: Int64?
        let storage: String?
    }
    @State var tab: PersonalStore.Tab = .apps
    @State var filter: PersonalStore.Filter = .all
    @State var focusedID: UUID?
    @State var detailOpen = false
    @State var detailAction: PersonalStore.Action?
    @State var budget: Budget?
    @State var budgetError: String?
    @State private var localROM: Set<UUID> = []
    @State private var hero: NSImage?
    @State private var heroID: UUID?

    var games: [PortedGame] { PersonalStore.games(app.libraryGames) }
    var rows: [[Item]] {
        let visible = games.compactMap { game -> Item? in
            let state = app.personalStoreState(game, localROM: localROM.contains(game.id))
            guard state.matches(tab, filter), let action = state.action(tab) else { return nil }
            return Item(game: game, action: action)
        }
        let groups: [[PersonalStore.Action]] = tab == .apps ? [[.play, .update], [.downloadApp]] : [[.downloadROM], [.prepare]]
        return groups.map { group in visible.filter { group.contains($0.action) } }.filter { !$0.isEmpty }
    }
    var rowIndex: Int { rows.firstIndex { $0.contains { $0.id == focusedID } } ?? rows.startIndex }
    var selected: Item? {
        if detailOpen, let detailAction, let game = games.first(where: { $0.id == focusedID }) {
            let action = app.personalStoreState(game, localROM: localROM.contains(game.id)).action(tab)
            return Item(game: game, action: action ?? detailAction)
        }
        guard rows.indices.contains(rowIndex) else { return nil }
        return rows[rowIndex].first { $0.id == focusedID } ?? rows[rowIndex].first
    }

    var body: some View {
        let _ = locale
        return scene(rows: rows, activeRow: rowIndex, item: selected,
                     image: heroID == selected?.id ? hero : nil, tab: tab, filter: filter,
                     detailOpen: detailOpen, budget: budget, canvas: canvas)
            .task(id: games.filter { !$0.sources.isEmpty }.map { "\($0.id)|\($0.sources)|\(cloud.states[$0.id]?.action == nil)" }) {
                let candidates = games.filter { !$0.sources.isEmpty }
                let ids = await Task.detached(priority: .utility) {
                    Set(candidates.filter { GameResourceState.sourcesAvailable(for: $0) }.map(\.id))
                }.value
                if !Task.isCancelled { localROM = ids }
            }
            .task(id: selected?.id) {
                guard let game = selected?.game else { return }
                let image = await GameArtLoader.shared.hero(for: game, metadata: nil, artwork: artwork, personalizations: personalizations)
                if !Task.isCancelled { hero = image; heroID = game.id }
            }
            .task(id: selected.flatMap { detailOpen && needsBudget($0) ? $0 : nil }) {
                budget = nil
                budgetError = nil
                guard detailOpen, let selected, needsBudget(selected) else { return }
                do {
                    let plan = try await app.planPersonalStoreTransfer(selected.action, game: selected.game)
                    guard !Task.isCancelled else { return }
                    budget = Budget(item: selected, offer: plan.offer, bytes: plan.bytes, destination: plan.destination,
                                    free: plan.free, storage: plan.storage)
                } catch {
                    if !Task.isCancelled { budgetError = app.cloudMessage(for: error) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .nxPersonalStoreAction)) { note in
                guard router.route == .personalStore, let action = note.object as? GamepadAction else { return }
                input(action)
            }
            .onChange(of: selected?.id) {
                if detailOpen { detailOpen = false; budget = nil; budgetError = nil }
            }
    }

    func scene(rows: [[Item]], activeRow: Int, item: Item?, image: NSImage?, tab: PersonalStore.Tab,
               filter: PersonalStore.Filter, detailOpen: Bool, budget: Budget?, canvas: SeleneCanvas) -> some View {
        ZStack(alignment: .bottom) {
            SeleneBackdrop()
            if let image {
                Color.clear.overlay(alignment: .trailing) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: canvas.size.width / 2 + canvas.u(SeleneTokens.Space.stageGutter),
                               height: canvas.size.height)
                        .clipped()
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .center))
                }.clipped()
                    .id(item?.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            SeleneShades()
            SeleneBottomScrim()
            VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.section)) {
                if !detailOpen { controls(tab: tab, filter: filter, canvas: canvas) }
                if let item {
                    heading(item, canvas: canvas)
                    if detailOpen {
                        HStack(alignment: .top, spacing: canvas.u(SeleneTokens.Space.section)) {
                            detail(item, budget: budget, canvas: canvas)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            let height = canvas.u(SeleneTokens.Space.stageHeader + SeleneTokens.Space.stageGutter)
                            cover(item, width: height * SeleneCanvas.design.width / SeleneCanvas.design.height,
                                  height: height, radius: canvas.u(SeleneTokens.Radius.card))
                                .accessibilityHidden(true)
                        }
                    }
                } else {
                    Text(L10n.text("No games match this filter."))
                        .seleneFont(.sectionTitle, .semibold)
                }
                if cloud.connectionCheck?.failure != nil || cloud.referenceCheck?.failure != nil {
                    Text(L10n.text("Cloud unavailable")).seleneFont(.caption)
                }
                Spacer(minLength: 0)
                if !detailOpen, rows.indices.contains(activeRow) {
                    if activeRow > rows.startIndex, let previous = rows[activeRow - 1].first {
                        Button(previous.action.row) { focusedID = previous.id }
                            .buttonStyle(.plain).seleneFont(.caption)
                    }
                    rail(rows[activeRow], selected: item?.id, preview: false, canvas: canvas)
                    if rows.indices.contains(activeRow + 1) {
                        rail(rows[activeRow + 1], selected: nil, preview: true, canvas: canvas)
                    } else {
                        Color.clear.frame(height: canvas.u(SeleneTokens.Space.stageHeader))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, canvas.u(SeleneTokens.Space.chromeGutter))
            .padding(.top, canvas.u(SeleneTokens.Space.section))
            .padding(.bottom, canvas.u(SeleneBottomScrim.contentClearance))
            if showsHints {
                SeleneHintsBar(left: [HintItem(.b, L10n.text("Back"), action: back)] + (detailOpen ? [] :
                    [HintItem(.lb, L10n.text("Previous tab")), HintItem(.rb, L10n.text("Next tab")),
                     HintItem(.x, L10n.text("Filter"), action: cycleFilter)]),
                    right: item.map { item in
                        if detailOpen && item.action.isTransfer && !needsBudget(item) {
                            return [HintItem(.a, L10n.text("Cloud library"), action: { manage(item) })]
                        }
                        let primary = !detailOpen || canRun(item, budget: budget)
                            ? [HintItem(.a, detailOpen ? item.action.label : L10n.text("Details"))] : []
                        return primary + (detailOpen
                            ? [HintItem(.x, L10n.text("Cloud library"), action: { manage(item) })] : [])
                    } ?? [])
            }
        }
        .frame(width: canvas.size.width, height: canvas.size.height)
        .foregroundStyle(SeleneTheme.ink)
        .clipShape(Rectangle())
        .animation(Motion.detailArt(reduced), value: item?.id)
    }

    private func controls(tab: PersonalStore.Tab, filter: PersonalStore.Filter, canvas: SeleneCanvas) -> some View {
        VStack(spacing: canvas.u(SeleneTokens.Space.small)) {
            Text(L10n.text("My library")).seleneFont(.title, .semibold).accessibilityAddTraits(.isHeader)
            HStack(spacing: canvas.u(SeleneTokens.Space.small)) {
                ForEach(PersonalStore.Tab.allCases, id: \.self) { candidate in
                    SelenePillButton(title: candidate == .apps ? "Apps" : "ROM", focused: tab == candidate) { select(candidate) }
                }
            }
            HStack(spacing: canvas.u(SeleneTokens.Space.small)) {
                ForEach(PersonalStore.Filter.allCases, id: \.self) { candidate in
                    SelenePillButton(title: candidate.key, focused: filter == candidate) { select(candidate) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func heading(_ item: Item, canvas: SeleneCanvas) -> some View {
        VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.small)) {
            Text(verbatim: item.game.name).seleneFont(.heroTitle, .semibold).accessibilityAddTraits(.isHeader)
            Text(item.action.row).seleneFont(.rowTitle).foregroundStyle(SeleneTheme.ink82)
            if let transfer = cloud.states[item.id]?.transfer() {
                Text(L10n.text(transfer.titleKey)).seleneFont(.caption)
            } else if item.action == .update {
                Text(L10n.text("Update available")).seleneFont(.caption)
            }
        }
    }

    private func detail(_ item: Item, budget: Budget?, canvas: SeleneCanvas) -> some View {
        VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.medium)) {
            if let version = item.game.versionString { Text(verbatim: version).seleneFont(.rowTitle) }
            if needsBudget(item) {
                if let budget, budget.item == item {
                    Text(budget.offer.isReference ? L10n.text("Source: reference library") : L10n.text("Source: personal cloud"))
                    Text(verbatim: budget.destination.path).lineLimit(1).truncationMode(.middle)
                    Text(diskLine("Transfer size: %@", budget.bytes))
                    Text(diskLine("Space required: %@", budget.offer.budget.required))
                    Text(diskLine("Space available: %@", budget.free))
                    if let free = budget.free, free < budget.offer.budget.required {
                        Text(L10n.text("Not enough space on this Mac."))
                    }
                } else { Text(budgetError ?? L10n.text("Checking files…")) }
            }
            HStack(spacing: canvas.u(SeleneTokens.Space.small)) {
                if !item.action.isTransfer || needsBudget(item) {
                    SelenePillButton(title: item.action.key, focused: true, enabled: canRun(item, budget: budget)) { run(item) }
                }
                CloudLibraryPill(indicator: .init(state: cloud.states[item.id] ?? .init()),
                                 focused: item.action.isTransfer && !needsBudget(item)) { manage(item) }
            }
        }
        .seleneFont(.panelBody)
    }

    private func cover(_ item: Item, width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        SpotlightTileArtwork(game: item.game, side: width, artwork: artwork, ownIconFirst: true)
            .frame(width: width, height: height)
            .clipped()
            .portingLook(cloud.states[item.id]?.coverLook(.normal) ?? .normal, cornerRadius: radius)
            .frame(width: width, height: height)
    }

    private func rail(_ items: [Item], selected: UUID?, preview: Bool, canvas: SeleneCanvas) -> some View {
        let radius = canvas.u(SeleneTokens.Radius.card)
        let height = canvas.u(SeleneTokens.Space.stageHeader + SeleneTokens.Space.stageGutter)
        let width = height * SeleneCanvas.design.width / SeleneCanvas.design.height
        let gap = canvas.u(SeleneTokens.Space.panel)
        let viewport = max(0, canvas.size.width - canvas.u(SeleneTokens.Space.chromeGutter + SeleneTokens.Space.chromeGutter))
        let index = items.firstIndex { $0.id == selected } ?? 0
        let pitch = max(width + gap, .leastNonzeroMagnitude)
        let visible = pitch.isNormal ? Int(((viewport + gap) / pitch).rounded(.up)) : 0
        let start = max(0, min(index, items.count - visible) - SpotlightRowGeometry.spareTiles)
        let end = min(items.count, index + visible + SpotlightRowGeometry.spareTiles)
        let maxOffset = max(0, CGFloat(items.count - start) - (viewport + gap) / pitch)
        return VStack(alignment: .leading, spacing: canvas.u(SeleneTokens.Space.small)) {
            Text(items.first?.action.row ?? "").seleneFont(.rowTitle, .semibold).accessibilityAddTraits(.isHeader)
            HStack(spacing: gap) {
                ForEach(items[start..<end]) { item in
                    Button {
                        if self.selected?.id == item.id { openDetail() }
                        else { withAnimation(Motion.rail(reduced, .spotlight)) { focusedID = item.id } }
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            cover(item, width: width, height: height, radius: radius)
                            Text(verbatim: item.game.name)
                                .seleneFont(.rowTitle, .semibold)
                                .lineLimit(1)
                                .padding(canvas.u(SeleneTokens.Space.small))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(SeleneTheme.glassSolid)
                        }
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: radius))
                        .overlay { SeleneTileRing(cornerRadius: radius, active: selected == item.id) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == item.id ? .isSelected : [])
                    .accessibilityValue(cloud.states[item.id]?.transfer().map { L10n.text($0.titleKey) } ?? "")
                }
            }
            .padding(canvas.u(SeleneTokens.Space.hairline))
            .fixedSize(horizontal: true, vertical: false)
            .modifier(RailCamera(position: CGFloat(index - start), maximum: maxOffset, pitch: pitch))
            .modifier(GlideGroup())
            .frame(width: viewport, height: preview ? canvas.u(SeleneTokens.Space.settingsInfoClearance)
                                   : height + canvas.u(SeleneTokens.Space.compact), alignment: .topLeading)
            .clipped()
        }
        .opacity(preview ? SeleneTokens.Effect.bandOpacity : 1)
    }

    func diskLine(_ key: String, _ bytes: Int64?) -> String {
        L10n.format(key, [bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? L10n.text("Unknown")])
    }
}

extension PersonalStore.Filter {
    var key: String {
        switch self {
        case .all: return "All library items"
        case .local: return "On this Mac"
        case .downloads: return "To download"
        case .updates: return "Updates"
        }
    }
}

extension PersonalStore.Action {
    var key: String {
        switch self {
        case .play: return "Play"
        case .downloadApp: return "Download app"
        case .update: return "Update app"
        case .downloadROM: return "Download ROM"
        case .prepare: return "Prepare porting"
        }
    }
    var label: String { L10n.text(key) }
    var isTransfer: Bool { self != .play && self != .prepare }
    var row: String {
        switch self {
        case .play, .update: return L10n.text("Ready to play")
        case .downloadApp: return L10n.text("In your cloud")
        case .downloadROM: return L10n.text("Your ROM library")
        case .prepare: return L10n.text("Ready to build")
        }
    }
}
