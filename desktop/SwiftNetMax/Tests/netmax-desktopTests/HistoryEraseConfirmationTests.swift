import XCTest
@testable import netmax_desktop

final class HistoryEraseConfirmationTests: XCTestCase {
    func testCancelCausesZeroStoreCalls() {
        var coordinator = HistoryEraseCoordinator()

        coordinator.cancel()

        XCTAssertEqual(coordinator.storeCallCount, 0)
        XCTAssertFalse(coordinator.isErasing)
        XCTAssertNil(coordinator.errorMessage)
    }

    func testConfirmCallsEraseExactlyOnceAndUpdatesState() {
        var coordinator = HistoryEraseCoordinator()
        var callCount = 0

        let ok = coordinator.confirm {
            callCount += 1
            return ["history.jsonl": true, "history.db": true]
        }

        XCTAssertTrue(ok)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(coordinator.storeCallCount, 1)
        XCTAssertFalse(coordinator.isErasing)
        XCTAssertNil(coordinator.errorMessage)
    }

    func testPartialFailureNeverShownAsSuccess() {
        var coordinator = HistoryEraseCoordinator()
        var callCount = 0

        let ok = coordinator.confirm {
            callCount += 1
            return [
                "history.jsonl": true,
                "history.db": false,
                "archive-history.jsonl": true
            ]
        }

        XCTAssertFalse(ok)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(coordinator.storeCallCount, 1)
        XCTAssertFalse(coordinator.isErasing)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(coordinator.errorMessage?.contains("Failed to erase") == true)
    }

    func testEmptyResultsTreatedAsFailure() {
        var coordinator = HistoryEraseCoordinator()

        let ok = coordinator.confirm {
            [:]
        }

        XCTAssertFalse(ok)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testConfirmationCopyMentionsLiveArchiveHoldingBinAndCannotBeUndone() {
        let title = HistoryEraseCoordinator.confirmationTitle
        let message = HistoryEraseCoordinator.confirmationMessage
        let button = HistoryEraseCoordinator.eraseButtonTitle

        XCTAssertFalse(title.isEmpty)
        XCTAssertFalse(button.isEmpty)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("live history"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("retention archive"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("cleared-history"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("cannot be undone"))
    }
}
