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

final class IPv6RoutingTests: XCTestCase {
    func testParsesCompressedAndEmbeddedForms() {
        XCTAssertEqual(IPv6Address("::1"), IPv6Address(high: 0, low: 1))
        XCTAssertEqual(IPv6Address("2001:db8::"), IPv6Address(high: 0x2001_0db8_0000_0000, low: 0))
        XCTAssertEqual(IPv6Address("::ffff:192.168.1.1"), IPv6Address(high: 0, low: 0xffff_c0a8_0101))
        XCTAssertEqual(IPv6Address("2001:db8:0:0:1:0:0:1"),
                       IPv6Address(high: 0x2001_0db8_0000_0000, low: 0x0001_0000_0000_0001))
        XCTAssertNil(IPv6Address("2001:db8:::1"))
        XCTAssertNil(IPv6Address("2001:db8:::zz"))
        XCTAssertNil(IPv6Address("1.2.3.4"))
    }

    func testMatchesIPv6Ranges() {
        let subject = CountryCIDRRanges(countryCode: "de", cidrText: """
        2a00:1158::/32
        2001:db8::/32
        invalid
        """)

        XCTAssertEqual(subject.ipv6RangeCount, 2)
        XCTAssertTrue(subject.contains(ipv6: IPv6Address("2a00:1158::1")!))
        XCTAssertTrue(subject.contains(ipv6: IPv6Address("2a00:1158:ffff::1")!))
        XCTAssertFalse(subject.contains(ipv6: IPv6Address("2a00:1159::1")!))
        XCTAssertFalse(subject.contains(ipv6: IPv6Address("2001:db9::1")!))
    }

    func testMixedFamiliesInOneCountry() {
        let subject = CountryCIDRRanges(countryCode: "DE", cidrTexts: [
            "2.28.0.0/14",
            "2a00:1158::/32"
        ])

        XCTAssertEqual(subject.ipv4RangeCount, 1)
        XCTAssertEqual(subject.ipv6RangeCount, 1)
        XCTAssertTrue(subject.contains(ipv4: CountryCIDRRanges.parseIPv4("2.28.1.1")!))
        XCTAssertTrue(subject.contains(ipv6: IPv6Address("2a00:1158::1")!))
    }
}

final class ProxyRoutingRulesTests: XCTestCase {
    private let germanRange = CountryCIDRRanges(countryCode: "DE", cidrs: ["2.28.0.0/14"])
    private let ipInGermany = CountryCIDRRanges.parseIPv4("2.28.1.1")!

    func testAllTrafficProxiesEverything() {
        let subject = ProxyRoutingRules(mode: .allTraffic)

        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: nil), .proxied)
    }

    func testRulesProxyByDefault() {
        let subject = ProxyRoutingRules(mode: .rules)

        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: nil), .proxied)
    }

    func testProxyExceptionsWinOverBypassRules() {
        let subject = ProxyRoutingRules(mode: .rules,
                                        bypassDomains: ProxyDomainList(domains: ["example.com"]),
                                        proxyExceptions: ProxyDomainList(domains: ["bank.example.com"]),
                                        countryRanges: [germanRange])

        XCTAssertEqual(subject.route(forHost: "bank.example.com", ipv4: ipInGermany), .proxied)
        XCTAssertEqual(subject.route(forHost: "www.example.com", ipv4: nil), .direct)
    }

    func testBypassDomainWinsOverGeoIP() {
        let subject = ProxyRoutingRules(mode: .rules,
                                        bypassDomains: ProxyDomainList(domains: ["example.com"]),
                                        countryRanges: [germanRange])

        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: ipInGermany), .direct)
    }

    func testGeoIPBypassesProxy() {
        let subject = ProxyRoutingRules(mode: .rules, countryRanges: [germanRange])

        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: ipInGermany), .direct)
        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: CountryCIDRRanges.parseIPv4("8.8.8.8")),
                       .proxied)
    }

    func testIPv6GeoIPBypass() {
        let ranges = CountryCIDRRanges(countryCode: "DE", cidrs: ["2a00:1158::/32"])
        let subject = ProxyRoutingRules(mode: .rules, countryRanges: [ranges])

        XCTAssertEqual(
            subject.route(forHost: "example.de", ipv4: nil, ipv6: IPv6Address("2a00:1158::1")),
            .direct
        )
        XCTAssertEqual(
            subject.route(forHost: "example.de", ipv4: nil, ipv6: IPv6Address("2a00:1159::1")),
            .proxied
        )
        let match = subject.matchingCountry(host: "example.de",
                                            ipv4: nil,
                                            ipv6: IPv6Address("2a00:1158::1"))
        XCTAssertEqual(match?.countryCode, "DE")
        XCTAssertEqual(match?.source, .address)
    }

    func testLocalAddressesAreDirect() {
        let subject = ProxyRoutingRules(mode: .rules, countryRanges: [germanRange])

        XCTAssertEqual(subject.route(forHost: "ya.ru", ipv4: CountryCIDRRanges.parseIPv4("172.19.0.19")),
                       .direct)
        XCTAssertEqual(subject.route(forHost: "router.lan",
                                     ipv4: CountryCIDRRanges.parseIPv4("192.168.1.1")),
                       .direct)
        XCTAssertEqual(subject.route(forHost: "nas.local",
                                     ipv4: CountryCIDRRanges.parseIPv4("10.0.0.5")),
                       .direct)
        XCTAssertEqual(subject.route(forHost: "example.com",
                                     ipv4: CountryCIDRRanges.parseIPv4("8.8.8.8")),
                       .proxied)
    }

    func testLocalIPv6IsDirect() {
        let subject = ProxyRoutingRules(mode: .rules, countryRanges: [germanRange])

        XCTAssertEqual(subject.route(forHost: "device.lan", ipv4: nil, ipv6: IPv6Address("fe80::1")),
                       .direct)
        XCTAssertEqual(subject.route(forHost: "device.lan", ipv4: nil, ipv6: IPv6Address("fd00::1")),
                       .direct)
        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: nil, ipv6: IPv6Address("2a00:1158::1")),
                       .proxied)
    }

    func testCountryTLDMatchesSelectedCountry() {
        let subject = ProxyRoutingRules(mode: .rules,
                                        countryRanges: [germanRange],
                                        selectedCountryCodes: ["RU"])

        XCTAssertEqual(subject.route(forHost: "ya.ru", ipv4: nil), .direct)
        XCTAssertEqual(subject.route(forHost: "example.ru", ipv4: nil), .direct)
        XCTAssertEqual(subject.route(forHost: "example.рф", ipv4: nil), .direct)
        XCTAssertEqual(subject.route(forHost: "example.su", ipv4: nil), .direct)
        XCTAssertEqual(subject.route(forHost: "example.com", ipv4: nil), .proxied)
        XCTAssertEqual(subject.route(forHost: "example.de", ipv4: nil), .proxied)
        XCTAssertFalse(subject.requiresResolution(forHost: "ya.ru"))
    }

    func testCountryTLDRequiresSelectedCountry() {
        let subject = ProxyRoutingRules(mode: .rules, selectedCountryCodes: ["DE"])

        XCTAssertEqual(subject.route(forHost: "ya.ru", ipv4: nil), .proxied)
        XCTAssertEqual(subject.route(forHost: "example.de", ipv4: nil), .direct)
    }

    func testResolutionNeededOnlyInRulesMode() {
        let rules = ProxyRoutingRules(mode: .rules, countryRanges: [germanRange])
        let allTraffic = ProxyRoutingRules(mode: .allTraffic, countryRanges: [germanRange])
        let decidedByDomain = ProxyRoutingRules(mode: .rules,
                                                bypassDomains: ProxyDomainList(domains: ["example.com"]),
                                                countryRanges: [germanRange])
        let excepted = ProxyRoutingRules(mode: .rules,
                                         proxyExceptions: ProxyDomainList(domains: ["example.com"]),
                                         countryRanges: [germanRange])

        XCTAssertTrue(rules.requiresResolution(forHost: "example.com"))
        XCTAssertFalse(allTraffic.requiresResolution(forHost: "example.com"))
        XCTAssertFalse(decidedByDomain.requiresResolution(forHost: "example.com"))
        XCTAssertFalse(excepted.requiresResolution(forHost: "example.com"))
    }
}
