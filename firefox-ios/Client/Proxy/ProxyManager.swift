// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import WebEngine

/// Applies the browser wide HTTP proxy to the web content of every window.
///
/// Changing the proxy stack invalidates WebKit's connection pool, so web views have to be torn down
/// before the new stack is assigned and restored afterwards. This mirrors what the VPN feature does.
@MainActor
final class ProxyManager {
    static let shared = ProxyManager()

    private let logger: Logger

    init(logger: Logger = DefaultLogger.shared) {
        self.logger = logger
    }

    /// Applies the proxy that was persisted in a previous session, before any web view exists.
    static func applyPersistedSettings(profile: Profile) {
        guard #available(iOS 17.0, *) else { return }
        let settings = ProxySettings(prefs: profile.prefs)
        guard settings.isEnabled, let endpoint = settings.endpoint else { return }
        DefaultWKEngineConfigurationProvider.applyHTTPProxy(endpoint, forcingSessionReset: false)
    }

    nonisolated static var isSupported: Bool {
        if #available(iOS 17.0, *) {
            return true
        }
        return false
    }

    func setEnabled(_ isEnabled: Bool, profile: Profile) async {
        let settings = ProxySettings(prefs: profile.prefs)
        guard settings.isConfigured else {
            settings.isEnabled = false
            logger.log("Ignoring proxy toggle, no server is configured",
                       level: .warning,
                       category: .webview)
            return
        }
        settings.isEnabled = isEnabled
        await applyProxyConfiguration(settings: settings)
    }

    func toggle(profile: Profile) async {
        let settings = ProxySettings(prefs: profile.prefs)
        await setEnabled(!settings.isEnabled, profile: profile)
    }

    func updateEndpoint(host: String, port: Int, profile: Profile) async {
        let settings = ProxySettings(prefs: profile.prefs)
        settings.update(host: host, port: port)
        guard settings.isEnabled else { return }
        await applyProxyConfiguration(settings: settings)
    }

    private func applyProxyConfiguration(settings: ProxySettings) async {
        guard #available(iOS 17.0, *) else { return }

        let tabManagers = tabManagers()
        for tabManager in tabManagers {
            await tabManager.tearDownWebViewsForProxyChange()
        }

        if settings.isEnabled, let endpoint = settings.endpoint {
            DefaultWKEngineConfigurationProvider.applyHTTPProxy(endpoint)
            logger.log("HTTP proxy enabled: \(endpoint.displayName)", level: .info, category: .webview)
        } else {
            DefaultWKEngineConfigurationProvider.clearHTTPProxy()
            logger.log("HTTP proxy disabled", level: .info, category: .webview)
        }

        for tabManager in tabManagers {
            tabManager.restoreSelectedTabForProxyChange()
        }
    }

    private func tabManagers() -> [TabManager] {
        let windowManager: WindowManager = AppContainer.shared.resolve()
        return windowManager.allWindowTabManagers()
    }
}
