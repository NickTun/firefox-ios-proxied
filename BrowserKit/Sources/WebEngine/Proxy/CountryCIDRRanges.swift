// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// IPv4 address ranges allocated to one country.
///
/// Only IPv4 is supported; IPv6 lookups fall back to the default route.
public struct CountryCIDRRanges: Sendable, Equatable {
    public let countryCode: String
    private let ranges: [Range]

    private struct Range: Sendable, Equatable {
        let network: UInt32
        let mask: UInt32
    }

    public init(countryCode: String, cidrText: String) {
        self.countryCode = countryCode.uppercased()
        self.ranges = CountryCIDRRanges.parse(cidrText)
    }

    public init(countryCode: String, cidrs: [String]) {
        self.init(countryCode: countryCode, cidrText: cidrs.joined(separator: "\n"))
    }

    public var isEmpty: Bool {
        return ranges.isEmpty
    }

    public func contains(ipv4: UInt32) -> Bool {
        var lowerBound = 0
        var upperBound = ranges.count - 1
        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let range = ranges[middle]
            let masked = ipv4 & range.mask
            if masked == range.network {
                return true
            }
            if range.network < masked {
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }
        return false
    }

    // MARK: - Parsing

    private static func parse(_ text: String) -> [Range] {
        var parsed: [Range] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let range = parse(line: trimmed) else { continue }
            parsed.append(range)
        }
        return parsed.sorted { $0.network < $1.network }
    }

    private static func parse(line: String) -> Range? {
        let components = line.split(separator: "/", maxSplits: 1)
        guard let addressText = components.first, let address = parseIPv4(String(addressText)) else { return nil }
        let prefix: Int
        if components.count == 2 {
            guard let parsedPrefix = Int(components[1]), (0...32).contains(parsedPrefix) else { return nil }
            prefix = parsedPrefix
        } else {
            prefix = 32
        }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return Range(network: address & mask, mask: mask)
    }

    /// Parses a dotted quad into host byte order.
    public static func parseIPv4(_ text: String) -> UInt32? {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        var result: UInt32 = 0
        for component in components {
            guard let octet = UInt8(component) else { return nil }
            result = (result << 8) | UInt32(octet)
        }
        return result
    }
}
