// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// List of host names used by the proxy routing rules.
///
/// Entries match the host itself and its subdomains: `example.com` matches `example.com` and
/// `www.example.com`. Wildcards, ports, paths and schemes in user input are tolerated and stripped.
public struct ProxyDomainList: Sendable, Equatable {
    public static let empty = ProxyDomainList(domains: [])

    private let domains: [String]

    public init(domains: [String]) {
        self.domains = ProxyDomainList.normalize(domains)
    }

    /// Accepts a text with one entry per line or comma separated entries.
    public init(text: String) {
        let separators = CharacterSet(charactersIn: ",\n")
        self.init(domains: text.components(separatedBy: separators))
    }

    public var isEmpty: Bool {
        return domains.isEmpty
    }

    public func matches(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return false }
        for domain in domains {
            if normalizedHost == domain || normalizedHost.hasSuffix(".\(domain)") {
                return true
            }
        }
        return false
    }

    private static func normalize(_ raw: [String]) -> [String] {
        var result: [String] = []
        for entry in raw {
            var value = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty, !value.hasPrefix("#") else { continue }
            if let schemeRange = value.range(of: "://") {
                value = String(value[schemeRange.upperBound...])
            }
            while value.hasPrefix("*.") {
                value.removeFirst(2)
            }
            if let pathIndex = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                value = String(value[..<pathIndex])
            }
            if let portIndex = value.firstIndex(of: ":") {
                value = String(value[..<portIndex])
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if !value.isEmpty {
                result.append(value)
            }
        }
        return result
    }
}
