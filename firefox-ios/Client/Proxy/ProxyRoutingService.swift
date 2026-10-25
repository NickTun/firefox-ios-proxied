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
/// created. GeoIP needs DNS, so addresses are resolved asynchronously and cached per host; the tab
/// is re-routed afterwards if the resolved route differs from the one it was created with.
@MainActor
final class ProxyRoutingService {
    static let shared = ProxyRoutingService()

    private let profile: Profile
    private let logger: Logger
    private var rulesCache: ProxyRoutingRules?
    private var routeCache: [String: ProxyRoute] = [:]
    private var resolvedAddresses: [String: UInt32] = [:]
    private var resolvedIPv6Addresses: [String: IPv6Address] = [:]

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
        resolvedIPv6Addresses.removeAll()
    }

    /// Whether a final route decision for the URL is already cached.
    func hasResolvedRoute(for url: URL?) -> Bool {
        guard let host = normalizedHost(for: url), isWebURL(url) else { return false }
        return routeCache[host] != nil
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
        let ipv4 = resolvedAddresses[host]
        let ipv6 = resolvedIPv6Addresses[host]
        let route = rules.route(forHost: host, ipv4: ipv4, ipv6: ipv6)
        if !isProvisional(host: host, ipv4: ipv4, ipv6: ipv6) {
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
        var ipv4 = resolvedAddresses[host]
        var ipv6 = resolvedIPv6Addresses[host]
        if ipv4 == nil, ipv6 == nil, rules.requiresResolution(forHost: host) {
            let addresses = await resolveAddresses(for: host)
            ipv4 = addresses.ipv4
            ipv6 = addresses.ipv6
            if let ipv4 {
                resolvedAddresses[host] = ipv4
            }
            if let ipv6 {
                resolvedIPv6Addresses[host] = ipv6
            }
        }
        let route = rules.route(forHost: host, ipv4: ipv4, ipv6: ipv6)
        if !isProvisional(host: host, ipv4: ipv4, ipv6: ipv6) {
            routeCache[host] = route
            logger.log("Proxy route \(route.rawValue) for \(host)", level: .debug, category: .webview)
            let address = ipv4.map(Self.formatIPv4) ?? ipv6?.displayName ?? "no address"
            let country = rules.matchingCountry(host: host, ipv4: ipv4, ipv6: ipv6)?.countryCode ?? "none"
            ProxyRoutingLog.shared.add("decide \(route.rawValue) \(host) ip=\(address) country=\(country)")
        } else {
            ProxyRoutingLog.shared.add("decide provisional \(route.rawValue) \(host) (no address)")
        }
        return route
    }

    // MARK: - Diagnostics

    /// Human readable snapshot of how the current configuration evaluates `url`, shown in settings
    /// so routing problems can be diagnosed without a debugger.
    func diagnostics(for url: URL?, tabRoute: ProxyRoute?) async -> String {
        let settings = self.settings
        let rules = await loadedRules()
        var lines: [String] = []

        lines.append("Proxy enabled: \(settings.isEnabled ? "yes" : "no")")
        lines.append("iOS 17+ supported: \(ProxyManager.isSupported ? "yes" : "no")")
        lines.append("Mode: \(settings.routingMode.rawValue)")
        if settings.isDoHEnabled {
            lines.append("DoH server: \(settings.dohEndpoint?.absoluteString ?? "invalid")")
        } else {
            lines.append("DoH server: disabled")
        }
        let countries = settings.countries
        lines.append("Countries selected: \(countries.isEmpty ? "none" : countries.joined(separator: ", "))")
        let ranges = rules.countryRanges
            .map { "\($0.countryCode) v4:\($0.ipv4RangeCount) v6:\($0.ipv6RangeCount)" }
        lines.append("Loaded ranges: \(ranges.isEmpty ? "none" : ranges.joined(separator: "; "))")

        guard let url, let host = normalizedHost(for: url) else {
            lines.append("Tab URL: none (open an http(s) page and check again)")
            return lines.joined(separator: "\n")
        }

        lines.append("Tab URL: \(url.absoluteString)")
        lines.append("Host: \(host)")
        let ipv4 = await Self.resolveIPv4(host: host)
        let ipv6 = await Self.resolveIPv6(host: host)
        var dohAddresses: ResolvedAddress?
        if let endpoint = settings.dohEndpoint {
            dohAddresses = await DoHResolver.shared.resolve(host: host, endpoint: endpoint)
        }
        if let ipv4 {
            lines.append("IPv4: \(Self.formatIPv4(ipv4)) (\(IPAddressKind.kind(ipv4: ipv4).rawValue))")
        } else {
            lines.append("IPv4: none")
        }
        if let ipv6 {
            lines.append("IPv6: \(ipv6.displayName) (\(IPAddressKind.kind(ipv6: ipv6).rawValue))")
        } else {
            lines.append("IPv6: none")
        }
        lines.append("Bypass list match: \(rules.bypassDomains.matches(host) ? "yes" : "no")")
        lines.append("Exception list match: \(rules.proxyExceptions.matches(host) ? "yes" : "no")")
        if settings.isDoHEnabled {
            if let dohAddresses {
                lines.append("DoH IPv4: \(dohAddresses.ipv4.map(Self.formatIPv4) ?? "none")")
                lines.append("DoH IPv6: \(dohAddresses.ipv6?.displayName ?? "none")")
            } else {
                lines.append("DoH: no answer")
            }
        }
        lines.append("Local host name: \(IPAddressKind.isLocalHostName(host) ? "yes" : "no")")
        if let match = rules.matchingCountry(host: host, ipv4: ipv4, ipv6: ipv6) {
            lines.append("Country match: \(match.countryCode) (\(match.source.rawValue))")
        } else {
            lines.append("Country match: none")
        }
        lines.append("Computed route: \(rules.route(forHost: host, ipv4: ipv4, ipv6: ipv6).rawValue)")
        lines.append("Tab route: \(tabRoute?.rawValue ?? "unknown")")
        return lines.joined(separator: "\n")
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
                                      countryRanges: ranges,
                                      selectedCountryCodes: Set(settings.countries))
        rulesCache = rules
        return rules
    }

    private func domainOnlyRules() -> ProxyRoutingRules {
        let settings = self.settings
        return ProxyRoutingRules(mode: settings.routingMode,
                                 bypassDomains: settings.bypassDomains,
                                 proxyExceptions: settings.proxyExceptions,
                                 countryRanges: [],
                                 selectedCountryCodes: Set(settings.countries))
    }

    private func isProvisional(host: String, ipv4: UInt32?, ipv6: IPv6Address?) -> Bool {
        guard ipv4 == nil, ipv6 == nil else { return false }
        return needsGeoIPLookup(host: host)
    }

    private func needsGeoIPLookup(host: String) -> Bool {
        let settings = self.settings
        guard settings.routingMode == .rules, !settings.countries.isEmpty else { return false }
        return !settings.proxyExceptions.matches(host) && !settings.bypassDomains.matches(host)
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

    private static func formatIPv4(_ address: UInt32) -> String {
        return [24, 16, 8, 0]
            .map { String((address >> UInt32($0)) & 0xFF) }
            .joined(separator: ".")
    }

    /// System addresses, replaced with DoH answers when DoH is enabled and the system resolver
    /// returns a fake-IP or nothing at all for a public host. Fake-IP answers carry no country data.
    private func resolveAddresses(for host: String) async -> ResolvedAddress {
        async let systemIPv4 = Self.resolveIPv4(host: host)
        async let systemIPv6 = Self.resolveIPv6(host: host)
        let system = ResolvedAddress(ipv4: await systemIPv4, ipv6: await systemIPv6)

        guard Self.isNonPublic(system), !IPAddressKind.isLocalHostName(host) else {
            return system
        }
        guard let endpoint = settings.dohEndpoint else {
            return system
        }
        if let doh = await DoHResolver.shared.resolve(host: host, endpoint: endpoint) {
            return doh
        }
        return system
    }

    private nonisolated static func isNonPublic(_ address: ResolvedAddress) -> Bool {
        if let ipv4 = address.ipv4, IPAddressKind.kind(ipv4: ipv4) == .local {
            return true
        }
        if let ipv6 = address.ipv6, IPAddressKind.kind(ipv6: ipv6) == .local {
            return true
        }
        return address.ipv4 == nil && address.ipv6 == nil
    }

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

    private nonisolated static func resolveIPv6(host: String) async -> IPv6Address? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET6
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
                let ipv6: IPv6Address? = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { raw in
                        guard raw.count >= 16 else { return nil }
                        var high: UInt64 = 0
                        var low: UInt64 = 0
                        for index in 0..<8 {
                            high = (high << 8) | UInt64(raw[index])
                        }
                        for index in 8..<16 {
                            low = (low << 8) | UInt64(raw[index])
                        }
                        return IPv6Address(high: high, low: low)
                    }
                }
                continuation.resume(returning: ipv6)
            }
        }
    }
}
