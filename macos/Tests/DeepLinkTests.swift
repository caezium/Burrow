import XCTest
@testable import Burrow

/// burrow:// deep-link routing (fired by the Burrow Cards iMessage extension).
final class DeepLinkTests: XCTestCase {
    func testCleanActionRoutesToCleanTool() {
        XCTAssertEqual(AppDelegate.pane(forDeepLink: URL(string: "burrow://action?id=clean")!), .tool(.clean))
    }

    func testInspectActionRoutesToStatus() {
        XCTAssertEqual(AppDelegate.pane(forDeepLink: URL(string: "burrow://action?id=inspect")!), .tool(.status))
    }

    func testUnknownIdStillSurfacesHome() {
        XCTAssertEqual(AppDelegate.pane(forDeepLink: URL(string: "burrow://action?id=zzz")!), .home)
        XCTAssertEqual(AppDelegate.pane(forDeepLink: URL(string: "burrow://open")!), .home)
    }

    func testForeignSchemeIsIgnored() {
        XCTAssertNil(AppDelegate.pane(forDeepLink: URL(string: "https://example.com")!))
        XCTAssertNil(AppDelegate.pane(forDeepLink: URL(string: "burro://action?id=clean")!))
    }
}
