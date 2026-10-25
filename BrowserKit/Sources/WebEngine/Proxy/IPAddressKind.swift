// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Whether an address is routable on the public internet.
///
/// Local addresses are either LAN destinations or fake-IP addresses handed out by a local DNS or
/// transparent proxy. Sending them through the configured proxy cannot work, so the router treats
/// them as direct and lets the device route them.
public enum IPAddressKind: String, Sendable {
    case local
    case publicAddress

    public static func kind(ipv4: UInt32) -> IPAddressKind {
        let candidates: [(network: UInt32, prefix: Int)] = [
            (0x0000_0000, 8),   // 0.0.0.0/8
            (0x0A00_0000, 8),   // 10.0.0.0/8
            (0x6440_0000, 10),  // 100.64.0.0/10, CGNAT
            (0x7F00_0000, 8),   // 127.0.0.0/8
            (0xA9FE_0000, 16),  // 169.254.0.0/16
            (0xAC10_0000, 12),  // 172.16.0.0/12
            (0xC0A8_0000, 16),  // 192.168.0.0/16
            (0xC612_0000, 15),  // 198.18.0.0/15, benchmark range used by fake-IP clients
            (0xE000_0000, 4),   // 224.0.0.0/4, multicast
            (0xF000_0000, 4)    // 240.0.0.0/4, reserved
        ]
        for candidate in candidates {
            let mask: UInt32 = candidate.prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - candidate.prefix)
            if (ipv4 & mask) == candidate.network {
                return .local
            }
        }
        return .publicAddress
    }

    /// Whether a host name can only exist on the local network. Fake-IP answers for public domains
    /// look like private addresses, so the address alone is not enough to treat a host as local.
    public static func isLocalHostName(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        guard normalized.contains(".") else { return true }
        if CountryCIDRRanges.parseIPv4(normalized) != nil || IPv6Address(normalized) != nil {
            return true
        }
        let localSuffixes = ["lan", "local", "internal", "home", "localhost", "localdomain", "arpa", "test", "invalid"]
        guard let tld = normalized.split(separator: ".").last.map(String.init) else { return false }
        return localSuffixes.contains(tld)
    }

    public static func kind(ipv6: IPv6Address) -> IPAddressKind {
        if ipv6 == IPv6Address(high: 0, low: 0) || ipv6 == IPv6Address(high: 0, low: 1) {
            return .local
        }
        // fc00::/7 unique local addresses
        if (ipv6.high & 0xFE00_0000_0000_0000) == 0xFC00_0000_0000_0000 {
            return .local
        }
        // fe80::/10 link local addresses
        if (ipv6.high & 0xFFC0_0000_0000_0000) == 0xFE80_0000_0000_0000 {
            return .local
        }
        return .publicAddress
    }
}

/// Why the router considered a host part of a country.
public struct CountryMatch: Sendable, Equatable {
    public enum Source: String, Sendable {
        case address
        case domain
    }

    public let countryCode: String
    public let source: Source

    public init(countryCode: String, source: Source) {
        self.countryCode = countryCode
        self.source = source
    }
}
