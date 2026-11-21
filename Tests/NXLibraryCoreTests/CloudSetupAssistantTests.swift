import XCTest
@testable import NXLibraryCore

final class CloudSetupAssistantTests: XCTestCase {
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

    func testConfirmationStartsOnCancelAndFocusSkipsDisabledControls() {
        var focus = CloudSetupAssistantFocus()
        let rows: [[CloudSetupAssistantFocus.Target]] = [[.folder("A")], [.cancel, .primary]]
        focus.move(.up, in: rows)
        XCTAssertEqual(focus.target, .folder("A"))
        focus.move(.down, in: rows)
        focus.move(.right, in: rows)
        XCTAssertEqual(focus.target, .primary)
        focus.settle(in: [[.cancel]])
        XCTAssertEqual(focus.target, .cancel)
        focus.move(.right, in: [[.cancel, .create]])
        XCTAssertEqual(focus.target, .create)
        focus.reset()
        XCTAssertEqual(focus.target, .cancel)
    }
}
