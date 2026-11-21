import Foundation

/// Session-only FIFO. The owner revalidates the head against current game and operation state.
package final class BuildQueue<Value> {
    package enum Decision { case start, wait, skip }
    package typealias Entry = (id: UUID, value: Value)
    private var entries: [Entry] = []
    package var ids: [UUID] { entries.map(\.id) }

    package init() {}

    @discardableResult
    package func enqueue(_ value: Value, id: UUID, activeID: UUID?) -> Bool {
        guard id != activeID, !ids.contains(id) else { return false }
        entries.append((id, value))
        return true
    }

    package func retryFirst(_ entry: Entry) {
        entries.insert(entry, at: 0)
    }

    @discardableResult
    package func cancel(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    package func takeNext(_ decide: (UUID) -> Decision) -> (id: UUID, value: Value, decision: Decision)? {
        guard let first = entries.first else { return nil }
        let decision = decide(first.id)
        guard decision != .wait else { return nil }
        entries.removeFirst()
        return (first.id, first.value, decision)
    }
}
