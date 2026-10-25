// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import WebEngine

final class ProxyDomainListTests: XCTestCase {
    func testMatchesExactHostAndSubdomains() {
        let subject = ProxyDomainList(domains: ["example.com"])

        XCTAssertTrue(subject.matches("example.com"))
        XCTAssertTrue(subject.matches("www.example.com"))
        XCTAssertTrue(subject.matches("a.b.example.com"))
        XCTAssertFalse(subject.matches("example.org"))
        XCTAssertFalse(subject.matches("notexample.com"))
    }

    func testNormalizesUserInput() {
        let subject = ProxyDomainList(text: """
        https://Example.com/path?q=1
        *.foo.org
        bar.net:8080
        # comment
        """)

        XCTAssertTrue(subject.matches("example.com"))
        XCTAssertTrue(subject.matches("sub.example.com"))
        XCTAssertTrue(subject.matches("foo.org"))
        XCTAssertTrue(subject.matches("bar.net"))
        XCTAssertFalse(subject.matches("other.net"))
    }

    func testEmptyListMatchesNothing() {
        XCTAssertFalse(ProxyDomainList.empty.matches("example.com"))
        XCTAssertTrue(ProxyDomainList.empty.isEmpty)
    }
}

final class CountryCIDRRangesTests: XCTestCase {
    func testParsesAndMatchesCIDR() {
        let subject = CountryCIDRRanges(countryCode: "de", cidrText: """
        # comment
        2.28.0.0/14
        81.169.0.0/16
        invalid
        10.0.0.0/8
        """)

        XCTAssertEqual(subject.countryCode, "DE")
        XCTAssertTrue(subject.contains(ipv4: CountryCIDRRanges.parseIPv4("2.28.1.1")!))
        XCTAssertTrue(subject.contains(ipv4: CountryCIDRRanges.parseIPv4("2.31.255.255")!))
        XCTAssertFalse(subject.contains(ipv4: CountryCIDRRanges.parseIPv4("2.32.0.1")!))
        XCTAssertTrue(subject.contains(ipv4: CountryCIDRRanges.parseIPv4("81.169.10.10")!))
        XCTAssertTrue(subject.contains(ipv4: CountryCIDRRanges.parseIPv4("10.20.30.40")!))
    }

    func testEmptyInputIsSafe() {
        let subject = CountryCIDRRanges(countryCode: "US", cidrText: "")
        XCTAssertTrue(subject.isEmpty)
        XCTAssertFalse(subject.contains(ipv4: 0))
    }

    func testParseIPv4() {
        XCTAssertEqual(CountryCIDRRanges.parseIPv4("255.255.255.255"), UInt32.max)
        XCTAssertEqual(CountryCIDRRanges.parseIPv4("0.0.0.0"), 0)
        XCTAssertNil(CountryCIDRRanges.parseIPv4("1.2.3"))
        XCTAssertNil(CountryCIDRRanges.parseIPv4("1.2.3.256"))
        XCTAssertNil(CountryCIDRRanges.parseIPv4("1.2.3.a"))
    }
}

final class ProxyRoutingRulesTests: XCTestCase {
    private let germanRange = CountryCIDRRanges(countryCode: "DE", cidrs: ["2.28.0.0/14"])
    private let ipInGermany = CountryCIDRRanges.parseIPv4("2.28.1.1")!

    func testAllTrafficProxiesEverything() {
        let subject = ProxyRoutingRules(mode: .allTraffic)

        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: nil), .proxied)
    }

    func testRulesDefaultToDirect() {
        let subject = ProxyRoutingRules(mode: .rules)

        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: nil), .direct)
    }

    func testExclusionsWinOverEverything() {
        let subject = ProxyRoutingRules(mode: .rules,
                                        proxyDomains: ProxyDomainList(domains: ["example.com"]),
                                        excludedDomains: ProxyDomainList(domains: ["bank.example.com"]),
                                        countryRanges: [germanRange])

        XCTAssertEqual(subject.route(forHost: "bank.example.com", ipv4: ipInGermany), .direct)
        XCTAssertEqual(subject.route(forHost: "www.example.com", ipv4: nil), .proxied)
    }

    func testProxyDomainWinsOverGeoIP() {
        let subject = ProxyRoutingRules(mode: .rules,
                                        proxyDomains: ProxyDomainList(domains: ["example.com"]),
                                        countryRanges: [germanRange])

        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: nil), .proxied)
    }

    func testGeoIPRouting() {
        let subject = ProxyRoutingRules(mode: .rules, countryRanges: [germanRange])

        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: ipInGermany), .proxied)
        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: CountryCIDRRanges.parseIPv4("8.8.8.8")),
                       .direct)
    }

    func testResolutionNeededOnlyInRulesMode() {
        let rules = ProxyRoutingRules(mode: .rules, countryRanges: [germanRange])
        let allTraffic = ProxyRoutingRules(mode: .allTraffic, countryRanges: [germanRange])
        let decidedByDomain = ProxyRoutingRules(mode: .rules,
                                                proxyDomains: ProxyDomainList(domains: ["example.com"]),
                                                countryRanges: [germanRange])

        XCTAssertTrue(rules.requiresResolution(forHost: "example.com"))
        XCTAssertFalse(allTraffic.requiresResolution(forHost: "example.com"))
        XCTAssertFalse(decidedByDomain.requiresResolution(forHost: "example.com"))
    }
}
