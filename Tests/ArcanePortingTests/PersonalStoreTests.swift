import ArcanePorting
import Foundation
import Testing

struct PersonalStoreTests {
    @Test func stateAndFiltersKeepInstallationSeparateFromUpdate() {
        let state = PersonalStore.State(app: .update, rom: .prepare)
        #expect(state.matches(.apps, .local))
        #expect(state.matches(.apps, .updates))
        #expect(!state.matches(.apps, .downloads))
        #expect(state.matches(.rom, .local))
        #expect(!state.matches(.rom, .updates))
        #expect(PersonalStore.State(app: nil, rom: .downloadROM).matches(.rom, .downloads))
        #expect(!PersonalStore.State(app: nil, rom: .prepare).matches(.apps, .all))
    }

    @Test func validIdentityDeduplicatesWithoutMatchingNamesOrHidingTheLocalCopy() {
        let placeholder = game("0100123456789abc")
        var local = game("0100123456789ABC")
        local.status = .built
        let unrelated = game("0100923456789ABC")
        #expect(PersonalStore.games([placeholder, local, unrelated, game("invalid")]).map(\.id)
            == [local.id, unrelated.id])
        local.isHidden = true
        #expect(PersonalStore.games([placeholder, local, unrelated]).map(\.id) == [unrelated.id])
    }

    @Test func versionComparisonDoesNotAdvertiseUnknownVersionsAsAnUpdate() {
        #expect(PersonalStore.isNewer("1.10", than: "1.9"))
        #expect(!PersonalStore.isNewer("1.2.0", than: "1.2"))
        #expect(!PersonalStore.isNewer("2.0 beta", than: "1.9"))
        #expect(!PersonalStore.isNewer("2.0", than: nil))
    }

    private func game(_ title: String) -> PortedGame {
        PortedGame(name: "Same name", url: URL(fileURLWithPath: "/synthetic/Game.app"),
                   platform: .macApp, sizeBytes: 0, modificationDate: .distantPast, titleId: title)
    }
}
