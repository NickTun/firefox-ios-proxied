// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Addresses resolved independently of the system resolver.
public struct ResolvedAddress: Sendable, Equatable {
    public let ipv4: UInt32?
    public let ipv6: IPv6Address?

    public init(ipv4: UInt32?, ipv6: IPv6Address?) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

/// Resolves real addresses over DNS-over-HTTPS.
///
/// Transparent proxy setups (Mihomo/Clash fake-IP mode and friends) answer the system resolver with
/// virtual addresses, which carry no country information. Asking a DoH endpoint for the real records
/// keeps the GeoIP rule usable in those setups. Only the routing decision uses these answers; the web
/// view still loads through the system resolver.
public actor DoHResolver {
    public static let shared = DoHResolver()

    private static let endpoints = [
        "https://1.1.1.1/dns-query?name=%@&type=%@",
        "https://dns.google/resolve?name=%@&type=%@"
    ]

    private var cache: [String: ResolvedAddress] = [:]

    public init() {}

    public func resolve(host: String) async -> ResolvedAddress? {
        if let cached = cache[host] {
            return cached
        }
        async let queryA = query(host: host, type: "A")
        async let queryAAAA = query(host: host, type: "AAAA")
        let (recordsA, recordsAAAA) = await (queryA, queryAAAA)
        guard !recordsA.isEmpty || !recordsAAAA.isEmpty else { return nil }

        let ipv4 = recordsA.compactMap { CountryCIDRRanges.parseIPv4($0) }.first
        let ipv6 = recordsAAAA.compactMap { IPv6Address($0) }.first
        let resolved = ResolvedAddress(ipv4: ipv4, ipv6: ipv6)
        cache[host] = resolved
        return resolved
    }

    public func invalidate() {
        cache.removeAll()
    }

    // MARK: - Private

    private func query(host: String, type: String) async -> [String] {
        for template in DoHResolver.endpoints {
            guard let url = URL(string: String(format: template, host, type)) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            request.setValue("application/dns-json", forHTTPHeaderField: "accept")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = json["Answer"] as? [[String: Any]]
            else { continue }

            let records = answers.compactMap { $0["data"] as? String }
            if !records.isEmpty {
                return records
            }
        }
        return []
    }
}
