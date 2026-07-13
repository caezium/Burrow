//
//  UpdateCheckTests.swift
//  BurrowTests
//
//  Manual "Check for Updates": compare the running version against the
//  latest GitHub release. Comparison is numeric per component (0.6.10 >
//  0.6.9 — lexicographic would get this wrong) and tolerant of a leading
//  "v" on tags. Parsing pins to the two release fields we use.
//

import XCTest
@testable import Burrow

final class UpdateCheckTests: XCTestCase {
    func testIsNewer_numericPerComponent() {
        XCTAssertTrue(UpdateCheck.isNewer("0.7.0", than: "0.6.7"))
        XCTAssertTrue(UpdateCheck.isNewer("0.6.10", than: "0.6.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.6.7", than: "0.6.7"))
        XCTAssertFalse(UpdateCheck.isNewer("0.6.7", than: "0.7.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))   // shorter remote
        XCTAssertTrue(UpdateCheck.isNewer("0.6.7.1", than: "0.6.7")) // longer remote
    }

    func testIsNewer_toleratesLeadingV() {
        XCTAssertTrue(UpdateCheck.isNewer("v0.7.0", than: "0.6.7"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.6.7", than: "v0.6.7"))
    }

    func testParseLatestRelease_readsTagAndURL() throws {
        let json = """
        {"tag_name": "v0.7.0", "html_url": "https://github.com/caezium/Burrow/releases/tag/v0.7.0",
         "name": "Burrow 0.7.0", "draft": false, "prerelease": false}
        """
        let release = try XCTUnwrap(UpdateCheck.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(release.version, "0.7.0")
        XCTAssertEqual(release.url.absoluteString, "https://github.com/caezium/Burrow/releases/tag/v0.7.0")
    }

    func testParseLatestRelease_rejectsGarbage() {
        XCTAssertNil(UpdateCheck.parseLatestRelease(Data("not json".utf8)))
        XCTAssertNil(UpdateCheck.parseLatestRelease(Data("{}".utf8)))
    }

    // MARK: - Homebrew update script (the "cannot be upgraded as-is" silent no-op)

    func testHomebrewUpdateScript_fallsBackToForcedReinstall() {
        let s = UpdateCheck.homebrewUpdateScript(releasesURL: "https://example.com/r")
        // Must detect Homebrew's exit-0 refusal by its message, not the exit code…
        XCTAssertTrue(s.contains("cannot be upgraded as-is"),
                      "must key off the warning text, since brew exits 0 on it")
        // …and fall back to the forced reinstall Homebrew recommends.
        XCTAssertTrue(s.contains("brew reinstall --cask --force burrow"),
                      "must reinstall when an in-place upgrade is refused")
        // Capture upgrade output so the refusal is detectable at all.
        XCTAssertTrue(s.contains("out=$(brew upgrade --cask burrow 2>&1); code=$?"))
        XCTAssertTrue(s.contains("open -a Burrow"))
        XCTAssertTrue(s.contains("https://example.com/r"))
    }
}
