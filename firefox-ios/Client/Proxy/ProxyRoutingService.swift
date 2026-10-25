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
    private let logger: Logger
    private var rulesCache: ProxyRoutingRules?
    private var routeCache: [String: ProxyRoute] = [:]
    private var resolvedAddresses: [String: UInt32] = [:]

    init(profile: Profile = AppContainer.shared.resolve(),
         logger: Logger = DefaultLogger.shared) {
        self.profile = profile
        self.logger = logger
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

    /// Route used when no host is known yet. Proxying is the safe default.
    var defaultRoute: ProxyRoute {
        guard ProxyManager.isSupported, settings.isEnabled else { return .direct }
        return .proxied
    }

    /// Route that can be computed without waiting for DNS.
    ///
    /// A decision that still depends on a DNS lookup is returned but not cached, otherwise the
    /// GeoIP rule would never get a chance to run for that host.
    func cachedRoute(for url: URL?) -> ProxyRoute {
        guard ProxyManager.isSupported, settings.isEnabled else { return .direct }
        guard isWebURL(url), let host = normalizedHost(for: url) else { return defaultRoute }

        if let cached = routeCache[host] {
            return cached
        }

        let rules = rulesCache ?? domainOnlyRules()
        let address = resolvedAddresses[host]
        let route = rules.route(forHost: host, ipv4: address)
        if !isProvisional(host: host, address: address) {
            routeCache[host] = route
        }
        return route
    }

    /// Full route, resolving the host for the geoip rule when needed.
    func route(for url: URL?) async -> ProxyRoute {
        guard ProxyManager.isSupported, settings.isEnabled else { return .direct }
        guard isWebURL(url), let host = normalizedHost(for: url) else { return defaultRoute }

        if let cached = routeCache[host] {
            return cached
        }

        let rules = await loadedRules()
        var address = resolvedAddresses[host]
        if address == nil, rules.requiresResolution(forHost: host) {
            address = await Self.resolveIPv4(host: host)
            if let address {
                resolvedAddresses[host] = address
            }
        }
        let route = rules.route(forHost: host, ipv4: address)
        if !isProvisional(host: host, address: address) {
            routeCache[host] = route
            logger.log("Proxy route \(route.rawValue) for \(host)",
                       level: .debug,
                       category: .webview)
        }
        return route
    }

    /// Whether the route may change once the host has been resolved.
    private func isProvisional(host: String, address: UInt32?) -> Bool {
        guard address == nil else { return false }
        return needsGeoIPLookup(host: host)
    }

    private func needsGeoIPLookup(host: String) -> Bool {
        let settings = self.settings
        guard settings.routingMode == .rules, !settings.countries.isEmpty else { return false }
        return !settings.proxyExceptions.matches(host) && !settings.bypassDomains.matches(host)
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
                                      bypassDomains: settings.bypassDomains,
                                      proxyExceptions: settings.proxyExceptions,
                                      countryRanges: ranges)
        rulesCache = rules
        return rules
    }

    private func domainOnlyRules() -> ProxyRoutingRules {
        let settings = self.settings
        return ProxyRoutingRules(mode: settings.routingMode,
                                 bypassDomains: settings.bypassDomains,
                                 proxyExceptions: settings.proxyExceptions,
                                 countryRanges: [])
    }

    private func isWebURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
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
