// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// An IPv6 address split into two 64 bit halves for cheap comparison.
public struct IPv6Address: Sendable, Equatable, Hashable {
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public init?(_ text: String) {
        guard let parsed = IPv6Address.parse(text) else { return nil }
        self = parsed
    }

    public var displayName: String {
        let groups: [UInt16] = [
            UInt16(truncatingIfNeeded: high >> 48),
            UInt16(truncatingIfNeeded: high >> 32),
            UInt16(truncatingIfNeeded: high >> 16),
            UInt16(truncatingIfNeeded: high),
            UInt16(truncatingIfNeeded: low >> 48),
            UInt16(truncatingIfNeeded: low >> 32),
            UInt16(truncatingIfNeeded: low >> 16),
            UInt16(truncatingIfNeeded: low)
        ]
        return groups.map { String($0, radix: 16) }.joined(separator: ":")
    }

    // MARK: - Parsing

    private static func parse(_ text: String) -> IPv6Address? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains("%") else { return nil }

        let halves = input.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        guard let left = parseGroups(halves[0]) else { return nil }
        let right: [UInt16]
        if halves.count == 2 {
            guard let parsedRight = parseGroups(halves[1]) else { return nil }
            right = parsedRight
        } else {
            right = []
        }
        let groups: [UInt16]
        if halves.count == 2 {
            let missing = 8 - left.count - right.count
            guard missing >= 0 else { return nil }
            groups = left + Array(repeating: UInt16(0), count: missing) + right
        } else {
            groups = left
        }
        guard groups.count == 8 else { return nil }

        var high: UInt64 = 0
        var low: UInt64 = 0
        for (index, group) in groups.enumerated() {
            if index < 4 {
                high = (high << 16) | UInt64(group)
            } else {
                low = (low << 16) | UInt64(group)
            }
        }
        return IPv6Address(high: high, low: low)
    }

    private static func parseGroups(_ part: String) -> [UInt16]? {
        guard !part.isEmpty else { return [] }
        var result: [UInt16] = []
        let components = part.split(separator: ":", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            guard !component.isEmpty else { return nil }
            if component.contains(".") {
                // Embedded IPv4 must be the last component.
                guard index == components.count - 1,
                      let ipv4 = CountryCIDRRanges.parseIPv4(String(component))
                else { return nil }
                result.append(UInt16(truncatingIfNeeded: ipv4 >> 16))
                result.append(UInt16(truncatingIfNeeded: ipv4 & 0xFFFF))
            } else {
                guard component.count <= 4, let value = UInt16(component, radix: 16) else { return nil }
                result.append(value)
            }
        }
        return result
    }
}

/// IPv4 and IPv6 address ranges allocated to one country.
public struct CountryCIDRRanges: Sendable, Equatable {
    public let countryCode: String
    private let ranges: [RangeV4]
    private let rangesV6: [RangeV6]

    private struct RangeV4: Sendable, Equatable {
        let network: UInt32
        let mask: UInt32
    }

    private struct RangeV6: Sendable, Equatable {
        let networkHigh: UInt64
        let networkLow: UInt64
        let maskHigh: UInt64
        let maskLow: UInt64
    }

    public init(countryCode: String, cidrText: String) {
        self.init(countryCode: countryCode, cidrTexts: [cidrText])
    }

    public init(countryCode: String, cidrTexts: [String]) {
        self.countryCode = countryCode.uppercased()
        var parsedV4: [RangeV4] = []
        var parsedV6: [RangeV6] = []
        for text in cidrTexts {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                if trimmed.contains(":") {
                    if let range = CountryCIDRRanges.parseV6Line(trimmed) {
                        parsedV6.append(range)
                    }
                } else if let range = CountryCIDRRanges.parseV4Line(trimmed) {
                    parsedV4.append(range)
                }
            }
        }
        self.ranges = parsedV4.sorted { $0.network < $1.network }
        self.rangesV6 = parsedV6.sorted {
            $0.networkHigh == $1.networkHigh ? $0.networkLow < $1.networkLow : $0.networkHigh < $1.networkHigh
        }
    }

    public init(countryCode: String, cidrs: [String]) {
        self.init(countryCode: countryCode, cidrTexts: [cidrs.joined(separator: "\n")])
    }

    public var isEmpty: Bool {
        return ranges.isEmpty && rangesV6.isEmpty
    }

    public var ipv4RangeCount: Int {
        return ranges.count
    }

    public var ipv6RangeCount: Int {
        return rangesV6.count
    }

    public func contains(ipv4: UInt32) -> Bool {
        guard let candidate = lastV4Range(startingAtOrBefore: ipv4) else { return false }
        return (ipv4 & candidate.mask) == candidate.network
    }

    public func contains(ipv6: IPv6Address) -> Bool {
        var lowerBound = 0
        var upperBound = rangesV6.count - 1
        var candidate: RangeV6?
        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let range = rangesV6[middle]
            let isBefore = range.networkHigh < ipv6.high
                || (range.networkHigh == ipv6.high && range.networkLow <= ipv6.low)
            if isBefore {
                candidate = range
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }
        guard let candidate else { return false }
        return (ipv6.high & candidate.maskHigh) == candidate.networkHigh
            && (ipv6.low & candidate.maskLow) == candidate.networkLow
    }

    // MARK: - Searching

    private func lastV4Range(startingAtOrBefore address: UInt32) -> RangeV4? {
        var lowerBound = 0
        var upperBound = ranges.count - 1
        var candidate: RangeV4?
        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let range = ranges[middle]
            if range.network <= address {
                candidate = range
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }
        return candidate
    }

    // MARK: - Parsing helpers

    private static func parseV4Line(_ line: String) -> RangeV4? {
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
        return RangeV4(network: address & mask, mask: mask)
    }

    private static func parseV6Line(_ line: String) -> RangeV6? {
        let components = line.split(separator: "/", maxSplits: 1)
        guard let addressText = components.first, let address = IPv6Address(String(addressText)) else { return nil }
        let prefix: Int
        if components.count == 2 {
            guard let parsedPrefix = Int(components[1]), (0...128).contains(parsedPrefix) else { return nil }
            prefix = parsedPrefix
        } else {
            prefix = 128
        }
        let (maskHigh, maskLow) = prefixMask(prefix)
        return RangeV6(networkHigh: address.high & maskHigh,
                       networkLow: address.low & maskLow,
                       maskHigh: maskHigh,
                       maskLow: maskLow)
    }

    private static func prefixMask(_ prefix: Int) -> (UInt64, UInt64) {
        switch prefix {
        case 0:
            return (0, 0)
        case 1...63:
            return (~UInt64(0) << UInt64(64 - prefix), 0)
        case 64:
            return (UInt64.max, 0)
        case 65...127:
            return (UInt64.max, ~UInt64(0) << UInt64(128 - prefix))
        default:
            return (UInt64.max, UInt64.max)
        }
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
