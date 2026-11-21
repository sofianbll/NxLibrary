import XCTest
@testable import NXLibraryCore
@testable import ArcanePorting

final class CloudTransferQueueTests: XCTestCase {
    func testQueueSaveFailureReportsOnceAndLaterSnapshotsStillWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder)
        let store = CloudTransferQueue(file: folder.appendingPathComponent("queue.json"))
        let notice = expectation(description: "One nonfatal queue error")
        notice.assertForOverFulfill = true
        let report: @Sendable (CloudLibraryFailure) -> Void = {
            XCTAssertEqual($0, .queueNotSaved)
            XCTAssertEqual($0.action, .dismiss)
            notice.fulfill()
        }
        let entry = CloudTransferQueue.Entry(id: UUID(), action: .downloadSources)
        store.save([entry], onFailure: report)
        store.save([], onFailure: report)
        await store.flush()
        await fulfillment(of: [notice], timeout: 2)
        try FileManager.default.removeItem(at: folder)
        store.save([entry], onFailure: report)
        await store.flush()
        let loaded = await store.load()
        XCTAssertEqual(loaded, [entry])
    }

    func testQuitDecisionWaitsForConfirmationAndQueueCleanup() {
        XCTAssertEqual(CloudQuitDecision.resolve(isWorking: true, hasQueueWrites: true), .confirm)
        XCTAssertEqual(CloudQuitDecision.resolve(isWorking: true, relaunchScheduled: true), .cancel)
        XCTAssertEqual(CloudQuitDecision.resolve(hasQueueWrites: true), .flush)
        XCTAssertEqual(CloudQuitDecision.resolve(isWorking: true, isQuitting: true), .cancel)
        XCTAssertEqual(CloudQuitDecision.resolve(hasQueueWrites: true, isQuitting: true), .cancel)
        XCTAssertEqual(CloudQuitDecision.resolve(isWorking: true, hasQueueWrites: true,
                                                 isQuitting: true, cleanupComplete: true), .quit)
        XCTAssertEqual(CloudQuitDecision.resolve(), .quit)
    }

    func testRoundTripKeepsInterruptedTransferFirstAndFiltersMissingGames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CloudTransferQueue(file: folder.appendingPathComponent("queue.json"))
        let active = CloudTransferQueue.Entry(id: UUID(), action: .upload(nil))
        let missing = CloudTransferQueue.Entry(id: UUID(), action: .restore(.app))
        let waiting = CloudTransferQueue.Entry(id: UUID(), action: .free([.app, .cache, .sources]))
        let entries = [active, missing, waiting, active]
        store.save([missing])
        store.save(entries)
        await store.flush()
        let loaded = await store.load()
        XCTAssertEqual(loaded, entries)
        XCTAssertEqual(CloudTransferQueue.restoring(loaded, gameIDs: [active.id, waiting.id]), [active, waiting])
    }

    func testInvalidAndFutureFilesLoadEmptyWithoutBeingOverwritten() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CloudTransferQueue(file: file)
        for text in ["not JSON", #"{"version":2,"entries":[]}"#] {
            let data = Data(text.utf8)
            try data.write(to: file)
            let loaded = await store.load()
            XCTAssertEqual(loaded, [])
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testResumedFreeOnlyKeepsItemsStillSafeToRemove() {
        let action = CloudLibraryAction.free([.app, .cache, .sources])
        XCTAssertEqual(action.resumableFree(synchronized: [.cache]), .free([.cache]))
        XCTAssertNil(action.resumableFree(synchronized: []))
    }
}
