import ArcanePorting
import Foundation
import NXLibraryCore
import SwiftUI

extension Notification.Name {
    static let nxPersonalStoreAction = Notification.Name("nxPersonalStoreAction")
}

extension PersonalStoreView {
    static func keyAction(_ key: UInt16) -> GamepadAction? {
        switch key {
        case 12: return .tabPrevious
        case 14: return .tabNext
        case 7: return .secondaryAction
        default: return GameInboxView.keyAction(key)
        }
    }

    func input(_ action: GamepadAction) {
        if action == .cancel { back(); return }
        if detailOpen {
            guard let selected else { return }
            if action == .secondaryAction { manage(selected) }
            else if action == .confirm {
                if selected.action.isTransfer && !needsBudget(selected) { manage(selected) }
                else { run(selected) }
            }
            return
        }
        switch action {
        case .tabPrevious, .tabNext: select(tab == .apps ? .rom : .apps)
        case .secondaryAction: cycleFilter()
        case .navigateLeft, .navigateRight: move(columns: action == .navigateLeft ? -1 : 1)
        case .navigateUp, .navigateDown: move(rows: action == .navigateUp ? -1 : 1)
        case .confirm: openDetail()
        default: break
        }
    }

    private func move(rows deltaRow: Int = 0, columns deltaColumn: Int = 0) {
        let rows = self.rows
        guard rows.indices.contains(rowIndex) else { return }
        let column = rows[rowIndex].firstIndex { $0.id == selected?.id } ?? 0
        let row = min(max(rowIndex + deltaRow, 0), rows.count - 1)
        let target = rows[row][min(max(column + deltaColumn, 0), rows[row].count - 1)].id
        guard target != selected?.id else { return }
        withAnimation(Motion.rail(reduced, .spotlight)) { focusedID = target }
        SoundEffectService.shared.play(.focus)
    }

    func select(_ tab: PersonalStore.Tab) {
        guard tab != self.tab else { return }
        withAnimation(Motion.screen(reduced)) { self.tab = tab }
        SoundEffectService.shared.play(.tabSwitch)
    }

    func select(_ filter: PersonalStore.Filter) {
        guard filter != self.filter else { return }
        withAnimation(Motion.screen(reduced)) { self.filter = filter }
        SoundEffectService.shared.play(.tabSwitch)
    }

    func cycleFilter() {
        let filters = PersonalStore.Filter.allCases
        guard let index = filters.firstIndex(of: filter) else { return }
        select(filters[(index + 1) % filters.count])
    }

    func openDetail() {
        guard let selected else { return }
        focusedID = selected.id
        detailAction = selected.action
        budget = nil
        budgetError = nil
        withAnimation(Motion.screen(reduced)) { detailOpen = true }
        SoundEffectService.shared.play(.click)
    }

    func back() {
        if detailOpen {
            withAnimation(Motion.screen(reduced)) { detailOpen = false }
        } else { router.back() }
        SoundEffectService.shared.play(.back)
    }

    func manage(_ item: Item) {
        DetailsLink.openCloud(for: item.game, viewModel: app)
    }

    func needsBudget(_ item: Item) -> Bool {
        item.action.isTransfer && cloud.states[item.id]?.action == nil
    }

    func canRun(_ item: Item, budget: Budget?) -> Bool {
        guard item.action.isTransfer else { return true }
        guard needsBudget(item), let budget, budget.item == item, let free = budget.free else { return false }
        return free >= budget.offer.budget.required
    }

    func run(_ item: Item) {
        guard canRun(item, budget: budget), app.libraryGames.contains(item.game) else { return }
        switch item.action {
        case .play:
            guard item.game.isPlayableLocally else { return }
            app.launchGame(item.game)
        case .prepare: review(item.game)
        case .downloadApp, .update, .downloadROM:
            guard let budget else { return }
            let action: CloudLibraryAction = item.action == .downloadROM ? .downloadSources : .restore(.app)
            let message = [
                diskLine("Transfer size: %@", budget.bytes),
                diskLine("Space required: %@", budget.offer.budget.required),
                diskLine("Space available: %@", budget.free)
            ].joined(separator: "\n")
            app.showSettingsNotice(title: item.action.label, message: message,
                                   actionTitle: item.action.key, cancelTitle: "Cancel", primaryFirst: true) {
                guard cloud.storageScope(for: action) == budget.storage,
                      app.libraryGames.contains(item.game),
                      action != .restore(.app) ||
                        (app.cloudImportDestination(for: item.game, action: action) ?? item.game.url)
                            .deletingLastPathComponent() == budget.destination,
                      app.enqueueCloudLibrary(action, for: item.game, offer: budget.offer) else {
                    app.showSettingsNotice(title: item.action.label, message: L10n.text("Cloud operation no longer available."))
                    return
                }
            }
        }
    }
}
