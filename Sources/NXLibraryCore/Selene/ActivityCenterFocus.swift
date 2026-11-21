import Foundation

public struct ActivityCenterFocus: Equatable {
    public enum Row: Hashable {
        case porting, queued(UUID), close
    }

    public var selected: Row?

    public init() {}

    public static func rows(isBuilding: Bool, queued: [UUID]) -> [Row] {
        (isBuilding ? [.porting] : []) + queued.map(Row.queued) + [.close]
    }

    public func current(in rows: [Row]) -> Row {
        guard let selected else { return rows.first ?? .close }
        // A vanished request must not silently focus another Cancel button.
        return rows.contains(selected) ? selected : .close
    }

    public mutating func move(by delta: Int, in rows: [Row]) {
        var index = FocusIndex(index: rows.firstIndex(of: current(in: rows)) ?? 0)
        index.move(by: delta, count: rows.count)
        selected = rows.indices.contains(index.index) ? rows[index.index] : .close
    }
}
