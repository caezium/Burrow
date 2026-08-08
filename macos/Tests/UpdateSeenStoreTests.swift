import XCTest
@testable import Burrow

final class UpdateSeenStoreTests: XCTestCase {
    func testUnseenAndMarkSeen() {
        let avail = [(bundleID: "a", version: "1.0"), (bundleID: "b", version: "2.0")]
        XCTAssertEqual(UpdateSeenStore.unseenCount(available: avail, seen: []), 2)
        let seen = UpdateSeenStore.markAllSeen(available: avail, seen: [])
        XCTAssertEqual(UpdateSeenStore.unseenCount(available: avail, seen: seen), 0)
    }

    func testNewVersionRebadges() {
        let seen: Set<String> = [UpdateSeenStore.key(bundleID: "a", version: "1.0")]
        XCTAssertEqual(UpdateSeenStore.unseenCount(available: [(bundleID: "a", version: "1.1")], seen: seen), 1)
        XCTAssertEqual(UpdateSeenStore.unseenCount(available: [(bundleID: "a", version: "1.0")], seen: seen), 0)
    }

    func testDismissedVersionRemainsAcknowledgedWhenTheSameVersionIsForcedAgain() {
        let dismissed = UpdateSeenStore.markAllSeen(
            available: [(bundleID: "a", version: "2.0")],
            seen: []
        )

        XCTAssertEqual(
            UpdateSeenStore.unseenCount(
                available: [(bundleID: "a", version: "2.0")],
                seen: dismissed
            ),
            0
        )
    }
}
