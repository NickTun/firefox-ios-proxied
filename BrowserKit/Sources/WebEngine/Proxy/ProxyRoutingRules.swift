// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Decides the proxy route for a host.
///
/// Precedence while in `rules` mode: excluded domains win over everything, then explicitly proxied
/// domains, then the selected countries, and the default route is direct. In `allTraffic` mode every
/// host is proxied.
public struct ProxyRoutingRules: Sendable, Equatable {
    public var mode: ProxyRoutingMode
    public var proxyDomains: ProxyDomainList
    public var excludedDomains: ProxyDomainList
    public var countryRanges: [CountryCIDRRanges]

    public init(mode: ProxyRoutingMode,
                proxyDomains: ProxyDomainList = .empty,
                excludedDomains: ProxyDomainList = .empty,
                countryRanges: [CountryCIDRRanges] = []) {
        self.mode = mode
        self.proxyDomains = proxyDomains
        self.excludedDomains = excludedDomains
        self.countryRanges = countryRanges
    }

    public func route(forHost host: String, ipv4: UInt32?) -> ProxyRoute {
        switch mode {
        case .allTraffic:
            return .proxied

        case .rules:
            if excludedDomains.matches(host) {
                return .direct
            }
            if proxyDomains.matches(host) {
                return .proxied
            }
            if let ipv4, countryRanges.contains(where: { $0.contains(ipv4: ipv4) }) {
                return .proxied
            }
            return .direct
        }
    }

    /// Whether a route decision can be made without resolving the host name.
    public func requiresResolution(forHost host: String) -> Bool {
        guard mode == .rules else { return false }
        return !excludedDomains.matches(host) && !proxyDomains.matches(host) && !countryRanges.isEmpty
    }
}
