import XCTest
@testable import NXLibraryCore
@testable import ArcanePorting

final class CloudTransferQueueTests: XCTestCase {
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
        let active = CloudTransferQueue.Entry(id: UUID(), action: .upload(nil), token: UUID(), storage: "fixture:Games")
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
        for text in ["not JSON", #"{"version":2,"entries":[]}"#] {
            let store = CloudTransferQueue(file: file)
            let data = Data(text.utf8)
            try data.write(to: file)
            let loaded = await store.load()
            XCTAssertEqual(loaded, [])
            store.save([.init(id: UUID(), action: .restore(.app))])
            await store.flush()
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testResumedFreeOnlyKeepsItemsStillSafeToRemove() {
        let action = CloudLibraryAction.free([.app, .cache, .sources])
        XCTAssertEqual(action.resumableFree(synchronized: [.cache]), .free([.cache]))
        XCTAssertNil(action.resumableFree(synchronized: []))
    }
}
