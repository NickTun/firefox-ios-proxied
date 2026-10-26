// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Network
import WebKit

@MainActor
public struct WKWebViewParameters {
    /// A boolean value customizable with a user preference indicating whether JavaScript can
    /// open windows without user interaction.
    var blockPopups: Bool

    /// A boolean value indicating if we have a persitent webview data store.
    var isPrivate: Bool

    /// The type of pull refresh that is going to be instantiated and displayed by the webview.
    var pullRefreshType: EnginePullRefreshViewType

    /// A value indicating the user preference for audio visual media types
    var autoPlay: WKAudiovisualMediaTypes

    /// FXIOS-11986  - Allow Client to pass down it's own scheme handler for now, this will be internal later on
    var schemeHandler: SchemeHandler

    /// Route that decides which `WKWebsiteDataStore` the webview uses.
    var proxyRoute: ProxyRoute

    public init(blockPopups: Bool,
                isPrivate: Bool,
                autoPlay: WKAudiovisualMediaTypes,
                schemeHandler: SchemeHandler,
                pullRefreshType: EnginePullRefreshViewType = UIRefreshControl.self,
                proxyRoute: ProxyRoute = .direct) {
        self.blockPopups = blockPopups
        self.isPrivate = isPrivate
        self.autoPlay = autoPlay
        self.schemeHandler = schemeHandler
        self.pullRefreshType = pullRefreshType
        self.proxyRoute = proxyRoute
    }

    /// Default internal Webview parameters initializer for WebEngine reader mode purpose
    init() {
        self.blockPopups = false
        self.isPrivate = false
        self.autoPlay = .all
        self.schemeHandler = WKInternalSchemeHandler()
        self.pullRefreshType = UIRefreshControl.self
        self.proxyRoute = .direct
    }
}

/// Provider to get a configured `WKEngineConfiguration`
/// Only one configuration provider per application should exists.
@MainActor
public protocol WKEngineConfigurationProvider {
    func createConfiguration(parameters: WKWebViewParameters) -> WKEngineConfiguration
    func endPrivateBrowsingSession()
}

/// FXIOS-11986 - This will be internal when the WebEngine is fully integrated in Firefox iOS
public struct DefaultWKEngineConfigurationProvider: WKEngineConfigurationProvider {
    /// Tabs are split between these stores: WebKit supports a single proxy stack per data store,
    /// so the direct and the proxied route need their own cookie jars, caches and storage.
    private static let proxiedStoreIdentifier = UUID(uuidString: "A1B2C3D4-5E6F-4708-9A0B-C1D2E3F40516")!
    private static let directStore = WKWebsiteDataStore.default()
    private static var cachedProxiedStore: WKWebsiteDataStore?
    private static var nonPersistentDirectStore = WKWebsiteDataStore.nonPersistent()
    private static var nonPersistentProxiedStore = WKWebsiteDataStore.nonPersistent()

    /// Named persistent store that keeps the proxied route's cookies and caches separate from the
    /// direct route. Named stores need iOS 17, which is also the minimum for the proxy feature.
    private static var proxiedStore: WKWebsiteDataStore? {
        guard #available(iOS 17.0, *) else { return nil }
        if let cachedProxiedStore {
            return cachedProxiedStore
        }
        let store = WKWebsiteDataStore(forIdentifier: proxiedStoreIdentifier)
        cachedProxiedStore = store
        return store
    }
    private static let defaultDataDetectorTypes: WKDataDetectorTypes = [.phoneNumber]
    public private(set) static var isProxyEnabled = false
    private let configuration: WKWebViewConfiguration

    public init(configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.configuration = configuration
    }

    /// Inert OHTTP config appended to every stack, to make WebKit drop its existing sessions
    /// and connection pools on the change — see https://bugs.webkit.org/show_bug.cgi?id=316948.
    /// WebKit only recreates sessions when `nw_proxy_config_stack_requires_http_protocols` is
    /// true for some entry, and only `nw_proxy_config_create_oblivious_http` returns true.
    /// Routing is unaffected: relay host and match domain are both unresolvable `.invalid`.
    @available(iOS 17.0, *)
    private static var sessionRecreateTrigger: ProxyConfiguration {
        let relay = ProxyConfiguration.RelayHop(
            http2RelayEndpoint: .url(URL(string: "https://unused-relay.invalid/")!)
        )
        return ProxyConfiguration(
            obliviousHTTPRelay: relay,
            relayResourcePath: "/gateway",
            gatewayKeyConfig: Data(count: 8),
            matchDomains: ["unused-match.invalid"]
        )
    }

    /// Assigns `proxyConfigurations` on the active stores.
    ///
    /// With `forcingSessionReset`, `sessionRecreateTrigger` is appended so WebKit drops its
    /// sessions and connection pools. That is required whenever the proxy endpoint changes,
    /// since pooled connections otherwise keep bypassing the new proxy, but every webview
    /// must already be torn down, because a load cancelled after the reset is processed
    /// against a session that no longer exists and crashes the network process.
    ///
    /// Without it the stack is assigned as-is and the connection pool survives, so in-flight
    /// requests get their grace period while new requests pick up the new stack. Use that for
    /// token rotation, where the endpoint is unchanged and only the auth header differs.
    @available(iOS 17.0, *)
    public static func applyProxyConfigurations(
        _ configs: [ProxyConfiguration],
        forcingSessionReset: Bool = true
    ) {
        let stack = forcingSessionReset ? configs + [sessionRecreateTrigger] : configs
        proxiedStore?.proxyConfigurations = stack
        nonPersistentProxiedStore.proxyConfigurations = stack
        isProxyEnabled = !configs.isEmpty
    }

    /// Routes every request made by web content through an HTTP proxy.
    ///
    /// The configuration is stored on `WKWebsiteDataStore`, so only the web content networking stack is
    /// affected: requests made by the app itself (telemetry, sync, its own HTTP clients) keep going direct.
    /// HTTPS is tunnelled through the same proxy using HTTP CONNECT.
    @available(iOS 17.0, *)
    public static func applyHTTPProxy(_ endpoint: HTTPProxyEndpoint, forcingSessionReset: Bool = true) {
        guard endpoint.isValid, let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return }
        let configuration = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(endpoint.host), port: port),
            tlsOptions: nil
        )
        applyProxyConfigurations([configuration], forcingSessionReset: forcingSessionReset)
    }

    @available(iOS 17.0, *)
    public static func clearHTTPProxy(forcingSessionReset: Bool = true) {
        applyProxyConfigurations([], forcingSessionReset: forcingSessionReset)
    }

    /// Store used for the direct route, exposed for the in-app proxy self test.
    public static var directDataStore: WKWebsiteDataStore {
        return directStore
    }

    /// Store used for the proxied route, exposed for the in-app proxy self test.
    public static var proxiedDataStore: WKWebsiteDataStore? {
        return proxiedStore
    }

    /// Number of network configurations currently applied to the proxied store.
    @available(iOS 17.0, *)
    public static func appliedProxyConfigurationCount() -> Int {
        return proxiedStore?.proxyConfigurations.count ?? 0
    }

    /// Every store that may hold browsing data, including private stores when a private session is open.
    public static func allDataStores() -> [WKWebsiteDataStore] {
        return [directStore, proxiedStore, nonPersistentDirectStore, nonPersistentProxiedStore]
            .compactMap { $0 }
    }

    public static func dataStore(isPrivate: Bool, route: ProxyRoute) -> WKWebsiteDataStore {
        switch (isPrivate, route) {
        case (false, .direct):
            return directStore
        case (false, .proxied):
            return proxiedStore ?? directStore
        case (true, .direct):
            return nonPersistentDirectStore
        case (true, .proxied):
            return nonPersistentProxiedStore
        }
    }

    public func endPrivateBrowsingSession() {
        if #available(iOS 17.0, *) {
            let currentProxyConfigs = Self.nonPersistentProxiedStore.proxyConfigurations
            Self.nonPersistentDirectStore = .nonPersistent()
            Self.nonPersistentProxiedStore = .nonPersistent()
            Self.nonPersistentProxiedStore.proxyConfigurations = currentProxyConfigs
        } else {
            // If iOS 17 is not available they will never had turned on the proxy
            Self.nonPersistentDirectStore = .nonPersistent()
            Self.nonPersistentProxiedStore = .nonPersistent()
        }
    }

    public func createConfiguration(parameters: WKWebViewParameters) -> WKEngineConfiguration {
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !parameters.blockPopups
        configuration.mediaTypesRequiringUserActionForPlayback = parameters.autoPlay
        configuration.userContentController = WKUserContentController()
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = DefaultWKEngineConfigurationProvider.defaultDataDetectorTypes

        // TODO: FXIOS-8086 - Evaluate if ignoresViewportScaleLimits is still needed
        // We do this to go against the configuration of the <meta name="viewport">
        // tag to behave the same way as Safari :-(
        configuration.ignoresViewportScaleLimits = true

        // Since our app creates multiple web views, we assign the same WKWebsiteDataStore object to web views that
        // may safely share cookies.
        // The cookie store should only be created once, otherwise we can loose them. See FXIOS-11833
        configuration.websiteDataStore = Self.dataStore(isPrivate: parameters.isPrivate,
                                                         route: parameters.proxyRoute)

        // Popup WKWebViewConfiguration can have the scheme already registered thus registering again
        // leads to crash
        if configuration.urlSchemeHandler(forURLScheme: parameters.schemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(parameters.schemeHandler,
                                              forURLScheme: parameters.schemeHandler.scheme)
        }

        return DefaultEngineConfiguration(webViewConfiguration: configuration)
    }
}
