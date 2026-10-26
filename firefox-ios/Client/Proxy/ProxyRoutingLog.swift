// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// In-memory ring buffer with the recent proxy routing decisions.
///
/// Shown in the proxy settings diagnostics so navigation problems can be reported without attaching
/// a debugger or reading device logs.
@MainActor
final class ProxyRoutingLog {
    static let shared = ProxyRoutingLog()

    private struct Entry {
        let date: Date
        let message: String
    }

    private var entries: [Entry] = []
    private let limit = 40

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func add(_ message: String) {
        entries.append(Entry(date: Date(), message: message))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    var text: String {
        guard !entries.isEmpty else { return "no routing events yet" }
        return entries
            .map { "\(Self.formatter.string(from: $0.date)) \($0.message)" }
            .joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
    }
}
