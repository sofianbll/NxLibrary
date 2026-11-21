public struct CloudSetupAssistantFocus {
    public enum Target: Hashable {
        case console, guide, client, secret, advanced, changeCredentials, retry
        case breadcrumb(String), folder(String), newFolder, folderName
        case resumeFolder, otherFolder
        case enterSourcesPath, sourcesPath
        case moveGames, confirmMove, cancel, primary, create
    }

    public enum Direction { case left, right, up, down }

    private var selection: Target?

    public init() {}
    public mutating func reset() { selection = nil }
    public mutating func select(_ target: Target) { selection = target }
    public mutating func retainSelection(in rows: [[Target]]) {
        if let selection, !rows.contains(where: { $0.contains(selection) }) { reset() }
    }

    public func current(in rows: [[Target]]) -> Target {
        let targets = rows.flatMap { $0 }
        if let selection, targets.contains(selection) { return selection }
        if targets.contains(.primary) { return .primary }
        if targets.contains(.cancel) { return .cancel }
        return targets.first ?? .cancel
    }

    public mutating func move(_ direction: Direction, in rows: [[Target]]) {
        let rows = rows.filter { !$0.isEmpty }
        let target = current(in: rows)
        guard let row = rows.firstIndex(where: { $0.contains(target) }),
              let column = rows[row].firstIndex(of: target) else { return }
        switch direction {
        case .left:
            if column > 0 { selection = rows[row][column - 1] }
        case .right:
            if column + 1 < rows[row].count { selection = rows[row][column + 1] }
        case .up:
            if row > 0 { selection = rows[row - 1][min(column, rows[row - 1].count - 1)] }
        case .down:
            if row + 1 < rows.count { selection = rows[row + 1][min(column, rows[row + 1].count - 1)] }
        }
    }
}
