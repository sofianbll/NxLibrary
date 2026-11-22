import Foundation
import NXLibraryCore

/// A read-only projection of the Switch catalog and its existing cloud observations.
package enum PersonalStore {
    package enum Tab: CaseIterable, Hashable { case apps, rom }
    package enum Filter: CaseIterable, Hashable { case all, local, downloads, updates }
    package enum Action: Hashable { case play, downloadApp, update, downloadROM, prepare }

    /// Persisted with the existing FIFO. A fresh lookup must match this exact offer.
    package enum Offer: Equatable, Codable, Sendable {
        case app(reference: Bool, fingerprint: String, bytes: Int64, required: Int64, update: Bool)
        case rom(reference: Bool, folder: String, files: [CloudGameSources.OfferFile], bytes: Int64, required: Int64)

        package var budget: (bytes: Int64, required: Int64) {
            switch self {
            case .app(_, _, let bytes, let required, _), .rom(_, _, _, let bytes, let required):
                return (bytes, required)
            }
        }

        package var isReference: Bool {
            switch self {
            case .app(let reference, _, _, _, _), .rom(let reference, _, _, _, _): return reference
            }
        }

        package static func app(_ manifest: CloudGameManifest?, reference: Bool, update: Bool) -> Self? {
            guard let app = manifest?.artifacts.first(where: { $0.kind == .app }),
                  let bytes = app.files == nil ? app.size : app.unpackedSize,
                  let required = CloudGameArchive.requiredBytes(
                    bytes: app.files == nil ? app.unpackedSize : bytes,
                    entries: app.files?.entries.count ?? app.entryCount, archive: app.files == nil ? bytes : 0)
            else { return nil }
            return .app(reference: reference, fingerprint: app.inventorySHA256, bytes: bytes, required: required, update: update)
        }
    }

    package struct State: Equatable {
        package let app: Action?
        package let rom: Action?

        package init(app: Action?, rom: Action?) { self.app = app; self.rom = rom }

        package func action(_ tab: Tab) -> Action? { tab == .apps ? app : rom }

        package func matches(_ tab: Tab, _ filter: Filter) -> Bool {
            guard let action = action(tab) else { return false }
            switch filter {
            case .all: return true
            case .local: return [.play, .update, .prepare].contains(action)
            case .downloads: return [.downloadApp, .downloadROM].contains(action)
            case .updates: return action == .update
            }
        }
    }

    package static func games(_ records: [PortedGame]) -> [PortedGame] {
        var order: [String] = []
        var byTitle: [String: PortedGame] = [:]
        // A hidden record must not come back as another copy from the cloud.
        let hidden = Set(records.filter(\.isHidden).compactMap { $0.titleId?.uppercased() })
        for game in records where game.platform == .macApp {
            guard let id = game.titleId, SaveLocation.validID(id) else { continue }
            let title = id.uppercased()
            guard !hidden.contains(title) else { continue }
            if let previous = byTitle[title] {
                guard !previous.isPlayableLocally, game.isPlayableLocally else { continue }
            } else { order.append(title) }
            byTitle[title] = game
        }
        return order.compactMap { byTitle[$0] }
    }

    package static func isNewer(_ remote: String?, than local: String?) -> Bool {
        func version(_ string: String?) -> [Int]? {
            guard let string else { return nil }
            let parts = string.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { part -> Int? in
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return Int(part)
            }
            return numbers.count == parts.count ? numbers : nil
        }
        guard let remote = version(remote), let local = version(local) else { return false }
        for index in 0..<max(remote.count, local.count) {
            let r = remote.indices.contains(index) ? remote[index] : 0
            let l = local.indices.contains(index) ? local[index] : 0
            if r != l { return r > l }
        }
        return false
    }
}
