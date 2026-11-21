import Foundation
import XCTest
@testable import NXLibraryCore
@testable import ArcanePorting

final class BuildQueueTests: XCTestCase {
    func testOnlyOneRequestPerGameAndCancellationKeepsFIFO() {
        let active = UUID(), first = UUID(), cancelled = UUID(), last = UUID()
        let queue = BuildQueue<String>()
        XCTAssertFalse(queue.enqueue("active", id: active, activeID: active))
        XCTAssertTrue(queue.enqueue("first", id: first, activeID: active))
        XCTAssertTrue(queue.enqueue("cancelled", id: cancelled, activeID: active))
        XCTAssertFalse(queue.enqueue("duplicate", id: first, activeID: active))
        XCTAssertTrue(queue.enqueue("last", id: last, activeID: active))
        XCTAssertTrue(queue.cancel(cancelled))
        XCTAssertFalse(queue.cancel(active))
        XCTAssertEqual(queue.ids, [first, last])
        XCTAssertEqual(queue.takeNext { _ in .start }?.value, "first")
        XCTAssertEqual(queue.takeNext { _ in .start }?.value, "last")
        XCTAssertTrue(queue.ids.isEmpty)
    }

    func testBusyHeadWaitsWithoutOvertakingAndMissingHeadIsSkipped() {
        let first = UUID(), second = UUID()
        let queue = BuildQueue<Int>()
        queue.enqueue(1, id: first, activeID: nil)
        queue.enqueue(2, id: second, activeID: nil)
        XCTAssertNil(queue.takeNext { $0 == first ? .wait : .start })
        XCTAssertEqual(queue.ids, [first, second])
        let skipped = queue.takeNext { $0 == first ? .skip : .start }
        XCTAssertEqual(skipped?.id, first)
        XCTAssertEqual(skipped?.decision, .skip)
        XCTAssertEqual(queue.takeNext { _ in .start }?.id, second)
    }

    func testHeadThatBecomesBusyDuringPreflightGoesBackFirst() throws {
        let first = UUID(), second = UUID()
        let queue = BuildQueue<Int>()
        queue.enqueue(1, id: first, activeID: nil)
        queue.enqueue(2, id: second, activeID: nil)
        let entry = try XCTUnwrap(queue.takeNext { _ in .start })
        queue.retryFirst((entry.id, entry.value))
        XCTAssertEqual(queue.ids, [first, second])
        XCTAssertEqual(queue.takeNext { _ in .start }?.value, 1)
    }

    func testSaveRecoveryReleaseWakesAWaitingTitle() {
        let gate = SaveOperationGate()
        let queue = BuildQueue<String>()
        let id = UUID(), title = "0100A00000000000"
        queue.enqueue(title, id: id, activeID: nil)
        gate.setRecoveryBlocked(true, titleID: title)
        XCTAssertNil(queue.takeNext { _ in gate.isBusy(titleID: title) ? .wait : .start })
        var started: UUID?
        gate.onActivityChange = { started = queue.takeNext { _ in gate.isBusy(titleID: title) ? .wait : .start }?.id }
        gate.setRecoveryBlocked(false, titleID: title.lowercased())
        XCTAssertEqual(started, id)
    }
}
