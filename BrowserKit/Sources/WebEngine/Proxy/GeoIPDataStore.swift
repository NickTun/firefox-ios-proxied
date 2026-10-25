// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Stores per country IPv4 ranges used by the geoip routing rule.
///
/// Data is downloaded on demand from the public `ipverse/rir-ip` dataset (aggregated RIR delegations
/// per country, refreshed daily upstream) and cached in the app container.
public actor GeoIPDataStore {
    public static let shared = GeoIPDataStore()

    public struct DownloadError: Error, CustomStringConvertible {
        public let countryCode: String
        public let statusCode: Int?

        public var description: String {
            if let statusCode {
                return "geoip download for \(countryCode) failed with HTTP \(statusCode)"
            }
            return "geoip download for \(countryCode) failed"
        }
    }

    private static let urlTemplate = "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/%@/ipv4-aggregated.txt"

    private let directory: URL
    private var rangesCache: [String: CountryCIDRRanges] = [:]

    public init(directory: URL? = nil) {
        let resolvedDirectory = directory ?? GeoIPDataStore.defaultDirectory()
        self.directory = resolvedDirectory
        try? FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
    }

    /// Whether the country ranges are already stored, without touching the actor.
    nonisolated public static func localDataExists(for countryCode: String) -> Bool {
        let path = defaultDirectory()
            .appendingPathComponent("\(countryCode.uppercased()).cidr")
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    nonisolated private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("GeoIP", isDirectory: true)
    }

    public func storedCountries() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "cidr" }
            .map { $0.deletingPathExtension().lastPathComponent.uppercased() }
            .sorted()
    }

    public func ranges(for countryCode: String) -> CountryCIDRRanges? {
        let code = countryCode.uppercased()
        if let cached = rangesCache[code] {
            return cached
        }
        let url = fileURL(for: code)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let ranges = CountryCIDRRanges(countryCode: code, cidrText: text)
        rangesCache[code] = ranges
        return ranges
    }

    public func hasData(for countryCode: String) -> Bool {
        return FileManager.default.fileExists(atPath: fileURL(for: countryCode.uppercased()).path)
    }

    /// Downloads the ranges for the given countries, replacing the cached copies.
    @discardableResult
    public func update(countries: [String]) async throws -> Date {
        let codes = countries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { $0.count == 2 }
        for code in Set(codes) {
            try await download(countryCode: code)
        }
        return Date()
    }

    public func remove(countryCode: String) {
        let code = countryCode.uppercased()
        rangesCache[code] = nil
        try? FileManager.default.removeItem(at: fileURL(for: code))
    }

    // MARK: - Private

    private func fileURL(for countryCode: String) -> URL {
        return directory.appendingPathComponent("\(countryCode).cidr")
    }

    private func download(countryCode: String) async throws {
        guard let url = URL(string: String(format: GeoIPDataStore.urlTemplate, countryCode.lowercased())) else {
            throw DownloadError(countryCode: countryCode, statusCode: nil)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw DownloadError(countryCode: countryCode, statusCode: httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw DownloadError(countryCode: countryCode, statusCode: nil)
        }
        try data.write(to: fileURL(for: countryCode), options: .atomic)
        rangesCache[countryCode] = nil
    }
}
