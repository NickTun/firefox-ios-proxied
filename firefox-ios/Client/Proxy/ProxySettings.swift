// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Shared
import WebEngine

/// Persisted user configuration of the browser wide HTTP proxy.
struct ProxySettings {
    struct Key {
        static let enabled = "proxy.enabled"
        static let host = "proxy.host"
        static let port = "proxy.port"
    }

    private let prefs: Prefs

    init(prefs: Prefs) {
        self.prefs = prefs
    }

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
}
