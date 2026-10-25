// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Address of the HTTP proxy that web content is routed through.
public struct HTTPProxyEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }

    public var isValid: Bool {
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }) else { return false }
        return (1...65535).contains(port)
    }

    public var displayName: String {
        return "\(host):\(port)"
    }
}
