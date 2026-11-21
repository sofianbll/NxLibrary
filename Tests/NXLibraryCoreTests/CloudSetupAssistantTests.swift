import XCTest
@testable import NXLibraryCore

final class CloudSetupAssistantTests: XCTestCase {
    func testOptInBlocksActivationUntilMoveCompletesForCurrentFolder() {
        var draft = CloudSetupAssistantDraft()
        draft.chooseAccount("drive")
        draft.browse("New")
        XCTAssertFalse(draft.wantsMove)
        let stale = draft.ticket
        draft.toggleMove()
        XCTAssertTrue(draft.useFolder())
        draft.acceptAccessCheck(draft.ticket)
        draft.acceptMove(stale)
        XCTAssertNil(draft.activation)
        draft.acceptMove(draft.ticket)
        XCTAssertEqual(draft.activation?.root, "New")
        draft.backToFolders()
        draft.browse("Other")
        XCTAssertFalse(draft.wantsMove)
        XCTAssertNil(draft.activation)
    }

    func testGoogleIDIsStricterThanCredentialSyntax() {
        XCTAssertTrue(CloudSetupAssistantDraft.validGoogleClientID(" 123-example.apps.googleusercontent.com "))
        XCTAssertTrue(RcloneConfiguration.validCredential("not-a-google-client"))
        XCTAssertFalse(CloudSetupAssistantDraft.validGoogleClientID("not-a-google-client"))
        XCTAssertFalse(CloudSetupAssistantDraft.validGoogleClientID(".apps.googleusercontent.com"))
        XCTAssertFalse(CloudSetupAssistantDraft.validGoogleClientID("x.apps.googleusercontent.com.evil"))
    }

    func testBrowsingAndOldTicketsCannotAuthorizeActivation() {
        var draft = CloudSetupAssistantDraft()
        draft.chooseAccount("drive")
        let stale = draft.browse("Games")
        let current = draft.browse("Archive/Games")
        XCTAssertFalse(draft.matches(stale))
        XCTAssertTrue(draft.matches(current))
        XCTAssertNil(draft.activation)
        XCTAssertTrue(draft.useFolder())
        let check = draft.ticket
        draft.backToFolders()
        draft.browse("Other")
        XCTAssertTrue(draft.useFolder())
        draft.acceptAccessCheck(check)
        XCTAssertNil(draft.activation)
        draft.acceptAccessCheck(draft.ticket)
        XCTAssertEqual(draft.activation?.storage, "drive:Other")
        XCTAssertEqual(draft.activation?.enabled, true)
    }

    func testPrimaryTakesDefaultFocusWhenReadyButExplicitCancelIsPreserved() {
        var focus = CloudSetupAssistantFocus()
        let rows: [[CloudSetupAssistantFocus.Target]] = [[.folder("A")], [.cancel, .primary]]
        XCTAssertEqual(focus.current(in: [[.cancel]]), .cancel)
        XCTAssertEqual(focus.current(in: rows), .primary)
        focus.move(.left, in: rows)
        XCTAssertEqual(focus.current(in: rows), .cancel)
        focus.move(.up, in: rows)
        XCTAssertEqual(focus.current(in: rows), .folder("A"))
        focus.reset()
        XCTAssertEqual(focus.current(in: rows), .primary)
        XCTAssertEqual(focus.current(in: [[.cancel, .create]]), .cancel)
        XCTAssertEqual(focus.current(in: [[.cancel, .confirmMove]]), .cancel)
    }
}
