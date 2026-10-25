// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Route a tab's web content takes.
///
/// Each route maps to its own `WKWebsiteDataStore`, because WebKit only supports one proxy
/// stack per data store. Tabs therefore keep separate cookies, local storage and caches per route.
public enum ProxyRoute: String, Sendable, Hashable, CaseIterable {
    case direct
    case proxied
}

/// How the route for a tab is decided.
public enum ProxyRoutingMode: String, Sendable, CaseIterable {
    /// Every tab is routed through the proxy, the lists below are ignored.
    case allTraffic

    /// Tabs are proxied by default and loaded directly when their site matches the bypass domains
    /// or a selected country, unless the domain is listed as a proxy exception.
    case rules
}
