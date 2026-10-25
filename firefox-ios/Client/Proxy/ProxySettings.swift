// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Shared
import WebEngine

/// Persisted user configuration of the browser wide HTTP proxy and its per tab routing rules.
struct ProxySettings {
    struct Key {
        static let enabled = "proxy.enabled"
        static let host = "proxy.host"
        static let port = "proxy.port"
        static let routingMode = "proxy.routingMode"
        static let proxyDomains = "proxy.proxyDomains"
        static let excludedDomains = "proxy.excludedDomains"
        static let countries = "proxy.countries"
        static let geoIPUpdatedAt = "proxy.geoipUpdatedAt"
    }

    private let prefs: Prefs

    init(prefs: Prefs) {
        self.prefs = prefs
    }

    // MARK: - Proxy server

    var isEnabled: Bool {
        get { return prefs.boolForKey(Key.enabled) ?? false }
        nonmutating set { prefs.setBool(newValue, forKey: Key.enabled) }
    }

    var host: String {
        return prefs.stringForKey(Key.host) ?? ""
    }

    var port: Int? {
        guard let port = prefs.intForKey(Key.port) else { return nil }
        return Int(port)
    }

    var endpoint: HTTPProxyEndpoint? {
        guard let port else { return nil }
        let endpoint = HTTPProxyEndpoint(host: host, port: port)
        return endpoint.isValid ? endpoint : nil
    }

    var isConfigured: Bool {
        return endpoint != nil
    }

    func update(host: String, port: Int) {
        prefs.setString(host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.host)
        prefs.setInt(Int32(port), forKey: Key.port)
    }

    // MARK: - Routing

    var routingMode: ProxyRoutingMode {
        get {
            guard let rawValue = prefs.stringForKey(Key.routingMode) else { return .allTraffic }
            return ProxyRoutingMode(rawValue: rawValue) ?? .allTraffic
        }
        nonmutating set { prefs.setString(newValue.rawValue, forKey: Key.routingMode) }
    }

    var proxyDomainsText: String {
        return prefs.stringForKey(Key.proxyDomains) ?? ""
    }

    var excludedDomainsText: String {
        return prefs.stringForKey(Key.excludedDomains) ?? ""
    }

    var proxyDomains: ProxyDomainList {
        return ProxyDomainList(text: proxyDomainsText)
    }

    var excludedDomains: ProxyDomainList {
        return ProxyDomainList(text: excludedDomainsText)
    }

    func update(proxyDomainsText: String) {
        prefs.setString(proxyDomainsText, forKey: Key.proxyDomains)
    }

    func update(excludedDomainsText: String) {
        prefs.setString(excludedDomainsText, forKey: Key.excludedDomains)
    }

    // MARK: - GeoIP

    var countries: [String] {
        let rawValue = prefs.stringForKey(Key.countries) ?? ""
        return rawValue
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { $0.count == 2 }
    }

    func update(countries: [String]) {
        let value = countries
            .map { $0.uppercased() }
            .filter { $0.count == 2 }
            .joined(separator: ",")
        prefs.setString(value, forKey: Key.countries)
    }

    var geoIPUpdatedAt: Date? {
        guard let timestamp = prefs.longForKey(Key.geoIPUpdatedAt), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    func update(geoIPUpdatedAt date: Date) {
        prefs.setLong(Int64(date.timeIntervalSince1970), forKey: Key.geoIPUpdatedAt)
    }
}
