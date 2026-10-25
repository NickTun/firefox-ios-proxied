// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Decides the proxy route for a host.
///
/// Traffic is proxied by default. In `rules` mode a host is loaded directly when it matches the
/// bypass domain list or one of the selected countries. Proxy exceptions always win and keep the
/// host on the proxy, even when it would otherwise be bypassed.
public struct ProxyRoutingRules: Sendable, Equatable {
    public var mode: ProxyRoutingMode
    public var bypassDomains: ProxyDomainList
    public var proxyExceptions: ProxyDomainList
    public var countryRanges: [CountryCIDRRanges]

    public init(mode: ProxyRoutingMode,
                bypassDomains: ProxyDomainList = .empty,
                proxyExceptions: ProxyDomainList = .empty,
                countryRanges: [CountryCIDRRanges] = []) {
        self.mode = mode
        self.bypassDomains = bypassDomains
        self.proxyExceptions = proxyExceptions
        self.countryRanges = countryRanges
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
            if matchingCountry(ipv4: ipv4, ipv6: ipv6) != nil {
                return .direct
            }
            return .proxied
        }
    }

    public func matchingCountry(ipv4: UInt32?, ipv6: IPv6Address?) -> String? {
        if let ipv4, let match = countryRanges.first(where: { $0.contains(ipv4: ipv4) }) {
            return match.countryCode
        }
        if let ipv6, let match = countryRanges.first(where: { $0.contains(ipv6: ipv6) }) {
            return match.countryCode
        }
        return nil
    }

    /// Whether a route decision can be made without resolving the host name.
    public func requiresResolution(forHost host: String) -> Bool {
        guard mode == .rules else { return false }
        if proxyExceptions.matches(host) || bypassDomains.matches(host) {
            return false
        }
        return !countryRanges.isEmpty
    }
}
