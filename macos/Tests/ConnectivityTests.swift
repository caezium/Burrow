//
//  ConnectivityTests.swift
//  BurrowTests
//
//  Pure classifiers behind the Get-Online pane (plan §2.2). The probes
//  themselves (URLSession / scutil / CFNetwork) are network/system I/O and
//  aren't covered here.
//

import XCTest
@testable import Burrow

final class ConnectivityTests: XCTestCase {
    func testCaptiveVerdict_successIsOnline() {
        let v = Connectivity.captiveVerdict(body: "<HTML><BODY>Success</BODY></HTML>", statusCode: 200)
        XCTAssertTrue(v.online)
        XCTAssertFalse(v.portal)
    }

    func testCaptiveVerdict_interceptedIsPortal() {
        let v = Connectivity.captiveVerdict(body: "<html>Sign in to Hotel WiFi</html>", statusCode: 200)
        XCTAssertFalse(v.online)
        XCTAssertTrue(v.portal)
        // A redirect status with no Success body is also a portal.
        XCTAssertTrue(Connectivity.captiveVerdict(body: "", statusCode: 302).portal)
    }

    func testCaptiveVerdict_noResponseIsOfflineNotPortal() {
        let v = Connectivity.captiveVerdict(body: nil, statusCode: nil)
        XCTAssertFalse(v.online)
        XCTAssertFalse(v.portal)
    }

    func testResolvers_parsesScutilDNS_dedupesAndDropsLoopback() {
        let publicOne = "1.1.1.1" // greenlight:ignore hardcoded-ipv4 — DNS parser fixture
        let publicTwo = "1.0.0.1" // greenlight:ignore hardcoded-ipv4 — DNS parser fixture
        let loopback = "127.0.0.1" // greenlight:ignore hardcoded-ipv4 — DNS parser fixture
        let sample = """
        DNS configuration
          resolver #1
            nameserver[0] : \(publicOne)
            nameserver[1] : \(publicTwo)
          resolver #2
            nameserver[0] : \(publicOne)
            nameserver[0] : \(loopback)
        """
        XCTAssertEqual(Connectivity.resolvers(fromScutilDNS: sample), [publicOne, publicTwo])
    }

    func testUsesPublicDNS() {
        let cloudflare = "1.1.1.1" // greenlight:ignore hardcoded-ipv4 — DNS comparison fixture
        let google = "8.8.8.8" // greenlight:ignore hardcoded-ipv4 — DNS comparison fixture
        let privateGateway = "192.168.1.1" // greenlight:ignore hardcoded-ipv4 — DNS comparison fixture
        XCTAssertTrue(Connectivity.usesPublicDNS([cloudflare]))
        XCTAssertTrue(Connectivity.usesPublicDNS([privateGateway, google]))
        XCTAssertFalse(Connectivity.usesPublicDNS([privateGateway]))
        XCTAssertFalse(Connectivity.usesPublicDNS([]))
    }

    func testVpnConnected_readsScutilNCList() {
        let connected = "* (Connected)   ABC123  IPSec  \"Work VPN\"\n  (Disconnected) DEF  IKEv2  \"Other\""
        XCTAssertTrue(Connectivity.vpnConnected(fromScutilNC: connected))
        let none = "  (Disconnected) DEF  IKEv2  \"Other\""
        XCTAssertFalse(Connectivity.vpnConnected(fromScutilNC: none))
    }

    func testProxyActive_readsEnableFlags() {
        XCTAssertTrue(Connectivity.proxyActive(["HTTPEnable": 1]))
        XCTAssertTrue(Connectivity.proxyActive(["SOCKSEnable": 1, "HTTPEnable": 0]))
        XCTAssertFalse(Connectivity.proxyActive(["HTTPEnable": 0]))
        XCTAssertFalse(Connectivity.proxyActive([:]))
    }

    func testMDMEnrolled_parsesProfilesStatus() {
        XCTAssertEqual(Connectivity.mdmEnrolled(fromProfilesStatus: "Enrolled via DEP: No\nMDM enrollment: No\n"), false)
        XCTAssertEqual(Connectivity.mdmEnrolled(fromProfilesStatus: "MDM enrollment: Yes (User Approved)"), true)
        XCTAssertNil(Connectivity.mdmEnrolled(fromProfilesStatus: "Enrolled via DEP: No"))
    }

    func testDefaultRoute_gatewayAndInterface() {
        let gateway = "192.168.1.1" // greenlight:ignore hardcoded-ipv4 — route parser fixture
        let wifi = "   route to: default\ndestination: default\n    gateway: \(gateway)\n  interface: en0\n"
        let r = Connectivity.defaultRoute(fromRouteGet: wifi)
        XCTAssertEqual(r.gateway, gateway)
        XCTAssertEqual(r.interface, "en0")
        // A point-to-point VPN tunnel has an interface but no gateway.
        let tun = "destination: default\n  interface: utun7\n"
        let r2 = Connectivity.defaultRoute(fromRouteGet: tun)
        XCTAssertNil(r2.gateway)
        XCTAssertEqual(r2.interface, "utun7")
    }
}
