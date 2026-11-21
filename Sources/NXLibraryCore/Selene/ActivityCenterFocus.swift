import Foundation

public struct ActivityCenterFocus: Equatable {
    public enum Row: Hashable {
        case porting, cancelBuild(UUID), queuedBuild(UUID), cancelCloud(UUID), queuedCloud(UUID), close
    }

    public var selected: Row?

    public init() {}

    public static func rows(isBuilding: Bool, activeBuild: UUID? = nil, queuedBuilds: [UUID] = [],
                            activeCloud: UUID? = nil, queuedCloud: [UUID] = []) -> [Row] {
        var rows: [Row] = isBuilding ? [.porting] : []
        if let activeBuild { rows.append(.cancelBuild(activeBuild)) }
        rows += queuedBuilds.map(Row.queuedBuild)
        if let activeCloud { rows.append(.cancelCloud(activeCloud)) }
        return rows + queuedCloud.map(Row.queuedCloud) + [.close]
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
