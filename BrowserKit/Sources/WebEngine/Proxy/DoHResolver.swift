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

/// Resolves real addresses over DNS-over-HTTPS (RFC 8484).
///
/// Transparent proxy setups (Mihomo/Clash fake-IP mode and friends) answer the system resolver with
/// virtual addresses, which carry no country information. Asking a DoH endpoint for the real records
/// keeps the GeoIP rule usable in those setups. Only the routing decision uses these answers; the web
/// view still loads through the system resolver.
public actor DoHResolver {
    public static let shared = DoHResolver()
    public static let defaultEndpoint = URL(string: "https://1.1.1.1/dns-query")!

    private var cache: [String: ResolvedAddress] = [:]

    public init() {}

    /// Normalizes user input into a DoH endpoint. Accepts `1.1.1.1`, `dns.example/dns-query` or a
    /// full HTTPS URL, and defaults the path to `/dns-query`.
    public nonisolated static func endpoint(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var value = trimmed
        if !value.contains("://") {
            value = "https://" + value
        }
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/dns-query"
        }
        return components.url
    }

    public func resolve(host: String, endpoint: URL) async -> ResolvedAddress? {
        let key = endpoint.absoluteString + "|" + host
        if let cached = cache[key] {
            return cached
        }

        async let answerA = query(host: host, type: 1, endpoint: endpoint)
        async let answerAAAA = query(host: host, type: 28, endpoint: endpoint)
        let (recordsA, recordsAAAA) = await (answerA, answerAAAA)

        guard !recordsA.isEmpty || !recordsAAAA.isEmpty else { return nil }

        let ipv4 = recordsA.first(where: { $0.count == 4 }).map { record in
            record.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let ipv6 = recordsAAAA.first(where: { $0.count == 16 }).flatMap { record -> IPv6Address? in
            var high: UInt64 = 0
            var low: UInt64 = 0
            for index in 0..<8 {
                high = (high << 8) | UInt64(record[index])
            }
            for index in 8..<16 {
                low = (low << 8) | UInt64(record[index])
            }
            return IPv6Address(high: high, low: low)
        }

        let resolved = ResolvedAddress(ipv4: ipv4, ipv6: ipv6)
        cache[key] = resolved
        return resolved
    }

    public func invalidate() {
        cache.removeAll()
    }

    // MARK: - Wire format

    private func query(host: String, type: UInt16, endpoint: URL) async -> [Data] {
        guard let message = DoHResolver.makeQuery(host: host, type: type) else { return [] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = message
        request.timeoutInterval = 5
        request.setValue("application/dns-message", forHTTPHeaderField: "content-type")
        request.setValue("application/dns-message", forHTTPHeaderField: "accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else { return [] }

        return DoHResolver.parseAnswers(data: data, type: type)
    }

    static func makeQuery(host: String, type: UInt16) -> Data? {
        var data = Data()
        let identifier = UInt16.random(in: 0...UInt16.max)
        data.append(UInt8(identifier >> 8))
        data.append(UInt8(identifier & 0xFF))
        data.append(contentsOf: [0x01, 0x00]) // recursion desired
        data.append(contentsOf: [0x00, 0x01]) // one question
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
        data.append(UInt8(type >> 8))
        data.append(UInt8(type & 0xFF))
        data.append(contentsOf: [0x00, 0x01]) // class IN
        return data
    }

    static func parseAnswers(data: Data, type: UInt16) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return [] }

        let questionCount = Int(bytes[4]) << 8 | Int(bytes[5])
        let answerCount = Int(bytes[6]) << 8 | Int(bytes[7])

        var offset = 12
        for _ in 0..<questionCount {
            guard let nameEnd = skipName(bytes, from: offset) else { return [] }
            offset = nameEnd + 4
            guard offset <= bytes.count else { return [] }
        }

        var records: [Data] = []
        for _ in 0..<answerCount {
            guard let nameEnd = skipName(bytes, from: offset) else { break }
            offset = nameEnd
            guard offset + 10 <= bytes.count else { break }

            let recordType = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let length = Int(bytes[offset + 8]) << 8 | Int(bytes[offset + 9])
            offset += 10

            guard offset + length <= bytes.count else { break }
            if recordType == type {
                records.append(Data(bytes[offset..<offset + length]))
            }
            offset += length
        }
        return records
    }

    private static func skipName(_ bytes: [UInt8], from start: Int) -> Int? {
        var offset = start
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 {
                return offset + 1
            }
            if length & 0xC0 == 0xC0 {
                return offset + 2
            }
            offset += 1 + length
        }
        return nil
    }
}
