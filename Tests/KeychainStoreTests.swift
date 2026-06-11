//
//  KeychainStoreTests.swift
//  BurrowTests
//
//  Roundtrip the one secret-storage seam (audit M11). Uses a dedicated
//  test account name so the developer's real `ai_openai_key` entry is
//  never touched, and removes it in tearDown.
//

import XCTest
@testable import Burrow

final class KeychainStoreTests: XCTestCase {
    private let account = "test.burrow.keychain-roundtrip"

    override func tearDown() {
        KeychainStore.set("", for: account)   // empty deletes
    }

    func testMissingKeyReadsNil() {
        XCTAssertNil(KeychainStore.string(for: "test.burrow.never-written"))
    }

    func testRoundtripAndOverwrite() {
        KeychainStore.set("sk-first", for: account)
        XCTAssertEqual(KeychainStore.string(for: account), "sk-first")
        KeychainStore.set("sk-second", for: account)
        XCTAssertEqual(KeychainStore.string(for: account), "sk-second",
                       "set must upsert, not duplicate")
    }

    func testEmptyValueDeletesTheEntry() {
        KeychainStore.set("sk-temp", for: account)
        KeychainStore.set("", for: account)
        XCTAssertNil(KeychainStore.string(for: account),
                     "a cleared field must leave nothing behind")
    }
}
