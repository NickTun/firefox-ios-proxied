// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Decides the proxy route for a host.
///
/// Traffic is proxied by default. In `rules` mode a host is loaded directly when:
/// * it resolves to a local or fake-IP address, which the device has to route itself,
/// * it resolves to an address of a selected country,
/// * its domain belongs to a selected country (ccTLD), or
/// * it matches the bypass domain list.
///
/// Proxy exceptions always win and keep the host on the proxy.
public struct ProxyRoutingRules: Sendable, Equatable {
    public var mode: ProxyRoutingMode
    public var bypassDomains: ProxyDomainList
    public var proxyExceptions: ProxyDomainList
    public var countryRanges: [CountryCIDRRanges]
    /// Selected countries, used for the ccTLD rule before the ranges are downloaded.
    public var selectedCountryCodes: Set<String>

    private static let countryTLDAliases = ["рф": "RU", "su": "RU"]

    public init(mode: ProxyRoutingMode,
                bypassDomains: ProxyDomainList = .empty,
                proxyExceptions: ProxyDomainList = .empty,
                countryRanges: [CountryCIDRRanges] = [],
                selectedCountryCodes: Set<String> = []) {
        self.mode = mode
        self.bypassDomains = bypassDomains
        self.proxyExceptions = proxyExceptions
        self.countryRanges = countryRanges
        self.selectedCountryCodes = selectedCountryCodes
    }

    public func route(forHost host: String, ipv4: UInt32?, ipv6: IPv6Address? = nil) -> ProxyRoute {
        switch mode {
        case .allTraffic:
            return .proxied

        case .rules:
            if proxyExceptions.matches(host) {
                return .proxied
            }
            if bypassDomains.matches(host) {
                return .direct
            }
            if let ipv4, IPAddressKind.kind(ipv4: ipv4) == .local {
                return .direct
            }
            if let ipv6, IPAddressKind.kind(ipv6: ipv6) == .local {
                return .direct
            }
            if matchingCountry(host: host, ipv4: ipv4, ipv6: ipv6) != nil {
                return .direct
            }
            return .proxied
        }
    }

    /// Country of the host, either from the resolved address or from its ccTLD.
    public func matchingCountry(host: String, ipv4: UInt32?, ipv6: IPv6Address?) -> CountryMatch? {
        if let ipv4, let match = countryRanges.first(where: { $0.contains(ipv4: ipv4) }) {
            return CountryMatch(countryCode: match.countryCode, source: .address)
        }
        if let ipv6, let match = countryRanges.first(where: { $0.contains(ipv6: ipv6) }) {
            return CountryMatch(countryCode: match.countryCode, source: .address)
        }
        if let countryCode = countryCodeFromDomain(host) {
            return CountryMatch(countryCode: countryCode, source: .domain)
        }
        return nil
    }

    /// Whether a route decision can be made without resolving the host name.
    public func requiresResolution(forHost host: String) -> Bool {
        guard mode == .rules else { return false }
        if proxyExceptions.matches(host) || bypassDomains.matches(host) {
            return false
        }
        return !countryRanges.isEmpty || countryCodeFromDomain(host) != nil
    }

    // MARK: - Domain country

    private func countryCodeFromDomain(_ host: String) -> String? {
        guard let tld = host.split(separator: ".").last.map({ String($0).lowercased() }),
              !tld.isEmpty
        else { return nil }

        let countryCode: String
        if let alias = Self.countryTLDAliases[tld] {
            countryCode = alias
        } else if tld.count == 2 {
            countryCode = tld.uppercased()
        } else {
            return nil
        }

        let selected = selectedCountryCodes.isEmpty
            ? Set(countryRanges.map(\.countryCode))
            : selectedCountryCodes
        guard selected.contains(countryCode) else { return nil }
        return countryCode
    }
}
