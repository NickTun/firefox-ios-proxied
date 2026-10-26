// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import WebEngine
import WebKit

/// Loads an IP echo page through the proxied data store to verify that web content really leaves
/// through the configured proxy. Runs in a throwaway web view, so it is independent of tab routing.
@MainActor
final class ProxyEgressProbe {
    static func run() async -> String {
        guard #available(iOS 17.0, *), let proxiedStore = DefaultWKEngineConfigurationProvider.proxiedDataStore else {
            return "proxied store is unavailable on this system"
        }

        let direct = await egress(store: DefaultWKEngineConfigurationProvider.directDataStore)
        let proxied = await egress(store: proxiedStore)
        let verdict = direct == proxied ? "SAME ADDRESS: proxy is not effective" : "different addresses: proxy works"
        return "direct egress: \(direct)\nproxied egress: \(proxied)\n\(verdict)"
    }

    private static func egress(store: WKWebsiteDataStore) async -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "https://api.ipify.org?format=json")!))

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let value = try? await webView.evaluateJavaScript("document.body.innerText"),
               let text = value as? String,
               !text.isEmpty {
                return text
            }
        }
        return "no answer (unreachable or blocked)"
    }
}
