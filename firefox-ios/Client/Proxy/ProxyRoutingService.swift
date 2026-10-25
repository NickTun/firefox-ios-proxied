// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import WebEngine

/// Decides the proxy route for a URL using the persisted rules.
///
/// Domain rules are evaluated synchronously so a route is always available when a web view is
/// created. GeoIP needs a DNS lookup, so it is resolved asynchronously and cached per host; the
/// tab is re-routed afterwards if the resolved route differs from the one it was created with.
@MainActor
final class ProxyRoutingService {
    static let shared = ProxyRoutingService()

    private let profile: Profile
    private var rulesCache: ProxyRoutingRules?
    private var routeCache: [String: ProxyRoute] = [:]
    private var resolvedAddresses: [String: UInt32] = [:]

    init(profile: Profile = AppContainer.shared.resolve()) {
        self.profile = profile
    }

    var settings: ProxySettings {
        return ProxySettings(prefs: profile.prefs)
    }

    /// Drops cached rules and decisions after the configuration changed.
    func invalidate() {
        rulesCache = nil
        routeCache.removeAll()
        resolvedAddresses.removeAll()
    }

    /// Route that can be computed without waiting for DNS.
    func cachedRoute(for url: URL?) -> ProxyRoute {
        guard ProxyManager.isSupported, settings.isEnabled else { return .direct }
        guard let host = normalizedHost(for: url) else { return .direct }

        if let cached = routeCache[host] {
            return cached
        }
        if let rulesCache {
            if !rulesCache.requiresResolution(forHost: host) || resolvedAddresses[host] != nil {
                let route = rulesCache.route(forHost: host, ipv4: resolvedAddresses[host])
                routeCache[host] = route
                return route
            }
            return .direct
        }
        let rules = domainOnlyRules()
        guard !rules.requiresResolution(forHost: host) else { return .direct }
        let route = rules.route(forHost: host, ipv4: nil)
        routeCache[host] = route
        return route
    }

    /// Full route, resolving the host for the geoip rule when needed.
    func route(for url: URL?) async -> ProxyRoute {
        guard ProxyManager.isSupported, settings.isEnabled else { return .direct }
        guard let host = normalizedHost(for: url) else { return .direct }

        if let cached = routeCache[host] {
            return cached
        }

        let rules = await loadedRules()
        var address = resolvedAddresses[host]
        if rules.requiresResolution(forHost: host), address == nil {
            address = await Self.resolveIPv4(host: host)
            resolvedAddresses[host] = address
        }
        let route = rules.route(forHost: host, ipv4: address)
        routeCache[host] = route
        return route
    }

    // MARK: - Rules

    private func loadedRules() async -> ProxyRoutingRules {
        if let rulesCache {
            return rulesCache
        }
        let settings = self.settings
        var ranges: [CountryCIDRRanges] = []
        for country in settings.countries {
            if let countryRanges = await GeoIPDataStore.shared.ranges(for: country) {
                ranges.append(countryRanges)
            }
        }
        let rules = ProxyRoutingRules(mode: settings.routingMode,
                                      proxyDomains: settings.proxyDomains,
                                      excludedDomains: settings.excludedDomains,
                                      countryRanges: ranges)
        rulesCache = rules
        return rules
    }

    private func domainOnlyRules() -> ProxyRoutingRules {
        let settings = self.settings
        return ProxyRoutingRules(mode: settings.routingMode,
                                 proxyDomains: settings.proxyDomains,
                                 excludedDomains: settings.excludedDomains,
                                 countryRanges: [])
    }

    private func normalizedHost(for url: URL?) -> String? {
        guard let host = url?.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty
        else { return nil }
        return host
    }

    // MARK: - DNS

    private nonisolated static func resolveIPv4(host: String) async -> UInt32? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                hints.ai_flags = AI_ADDRCONFIG
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                defer {
                    if result != nil {
                        freeaddrinfo(result)
                    }
                }
                guard status == 0, let address = result?.pointee.ai_addr else {
                    continuation.resume(returning: nil)
                    return
                }
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
                }
                continuation.resume(returning: ipv4)
            }
        }
    }
}
