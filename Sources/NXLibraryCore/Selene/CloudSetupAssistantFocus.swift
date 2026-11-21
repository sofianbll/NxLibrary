public struct CloudSetupAssistantFocus {
    public enum Target: Hashable {
        case console, guide, client, secret, changeCredentials, retry
        case breadcrumb(String), folder(String), newFolder, folderName
        case moveGames, confirmMove, cancel, primary, create
    }

    public enum Direction { case left, right, up, down }

    public private(set) var target: Target = .cancel

    public init() {}
    public mutating func reset() { target = .cancel }
    public mutating func select(_ target: Target) { self.target = target }

    public mutating func settle(in rows: [[Target]]) {
        let targets = rows.flatMap { $0 }
        if !targets.contains(target) { target = targets.contains(.cancel) ? .cancel : targets.first ?? .cancel }
    }

    public mutating func move(_ direction: Direction, in rows: [[Target]]) {
        let rows = rows.filter { !$0.isEmpty }
        settle(in: rows)
        guard let row = rows.firstIndex(where: { $0.contains(target) }),
              let column = rows[row].firstIndex(of: target) else { return }
        switch direction {
        case .left:
            if column > 0 { target = rows[row][column - 1] }
        case .right:
            if column + 1 < rows[row].count { target = rows[row][column + 1] }
        case .up:
            if row > 0 { target = rows[row - 1][min(column, rows[row - 1].count - 1)] }
        case .down:
            if row + 1 < rows.count { target = rows[row + 1][min(column, rows[row + 1].count - 1)] }
        }
    }
}
