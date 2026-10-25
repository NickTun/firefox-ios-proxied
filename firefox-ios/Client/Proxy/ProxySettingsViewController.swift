// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import UIKit
import WebEngine

/// Configures the browser wide HTTP proxy and the per tab routing rules.
final class ProxySettingsViewController: SettingsTableViewController {
    private var isUpdatingGeoIP = false

    init(profile: Profile, windowUUID: WindowUUID) {
        super.init(style: .grouped, windowUUID: windowUUID)
        self.profile = profile
        self.title = "Proxy"
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func generateSettings() -> [SettingSection] {
        guard let profile else { return [] }

        let settings = ProxySettings(prefs: profile.prefs)
        return [
            connectionSection(profile: profile, settings: settings),
            routingSection(settings: settings),
            geoIPSection(profile: profile, settings: settings),
            domainsSection(profile: profile, settings: settings),
            diagnosticsSection()
        ]
    }

    // MARK: - Sections

    private func connectionSection(profile: Profile, settings: ProxySettings) -> SettingSection {
        let toggle = BoolSetting(
            prefs: profile.prefs,
            theme: currentTheme(),
            prefKey: ProxySettings.Key.enabled,
            defaultValue: false,
            titleText: "Enable HTTP proxy",
            statusText: settings.endpoint?.displayName,
            settingDidChange: { [weak self] isEnabled in
                Task { @MainActor in
                    guard let self, let profile = self.profile else { return }
                    await ProxyManager.shared.setEnabled(isEnabled, profile: profile)
                    self.refreshSettings()
                }
            }
        )
        toggle.enabled = ProxyManager.isSupported

        let server = ClosureSetting(
            title: "Server",
            statusText: settings.endpoint?.displayName ?? "Not configured",
            handler: { [weak self] _ in self?.presentServerEditor() }
        )
        server.enabled = ProxyManager.isSupported

        let footer = ProxyManager.isSupported
            ? "All proxied web content goes through this HTTP proxy, including HTTPS which is tunnelled " +
              "through it with CONNECT. Firefox's own background requests are not affected."
            : "Browser wide proxying requires iOS 17 or later."

        return SettingSection(footerTitle: NSAttributedString(string: footer), children: [toggle, server])
    }

    private func routingSection(settings: ProxySettings) -> SettingSection {
        let modeTitle: String
        switch settings.routingMode {
        case .allTraffic: modeTitle = "Proxy everything"
        case .rules: modeTitle = "Bypass domains + GeoIP"
        }
        let mode = ClosureSetting(
            title: "Routing",
            statusText: modeTitle,
            handler: { [weak self] _ in self?.presentRoutingModePicker() }
        )
        mode.enabled = ProxyManager.isSupported

        return SettingSection(
            footerTitle: NSAttributedString(
                string: "Every tab goes through the proxy by default. With bypass rules a tab is loaded " +
                        "directly when its site resolves to a local or fake-IP address, belongs to a " +
                        "selected country, or matches the bypass domains, unless the domain is listed " +
                        "as a proxy exception."
            ),
            children: [mode]
        )
    }

    private func geoIPSection(profile: Profile, settings: ProxySettings) -> SettingSection {
        let countries = settings.countries
        let countriesSetting = ClosureSetting(
            title: "Countries",
            statusText: countries.isEmpty ? "None" : countries.joined(separator: ", "),
            handler: { [weak self] navigationController in
                guard let self, let profile = self.profile else { return }
                let controller = ProxyCountrySelectionViewController(profile: profile, windowUUID: self.windowUUID)
                navigationController?.pushViewController(controller, animated: true)
            }
        )
        countriesSetting.enabled = ProxyManager.isSupported

        let missingCountries = countries.filter { !GeoIPDataStore.localDataExists(for: $0) }
        var updatedText: String
        if isUpdatingGeoIP {
            updatedText = "Updating…"
        } else if let date = settings.geoIPUpdatedAt {
            updatedText = "Updated \(Self.dateFormatter.string(from: date))"
        } else {
            updatedText = "Not downloaded"
        }
        if !missingCountries.isEmpty {
            updatedText += " · no data for \(missingCountries.joined(separator: ", "))"
        }
        let update = ClosureSetting(
            title: "Update GeoIP data",
            statusText: updatedText,
            showsDisclosure: false,
            handler: { [weak self] _ in self?.updateGeoIPData() }
        )
        update.enabled = ProxyManager.isSupported && !countries.isEmpty && !isUpdatingGeoIP

        return SettingSection(
            footerTitle: NSAttributedString(
                string: "Sites in a selected country are loaded directly. The country is matched by " +
                        "IPv4/IPv6 address or by the country domain (.ru, .de and so on). When the " +
                        "system DNS returns fake-IP answers, real addresses are looked up over " +
                        "DNS-over-HTTPS (Cloudflare). Data is downloaded when a country is selected."
            ),
            children: [countriesSetting, update]
        )
    }

    private func domainsSection(profile: Profile, settings: ProxySettings) -> SettingSection {
        let bypassEntries = Self.entries(in: settings.bypassDomainsText)
        let exceptionEntries = Self.entries(in: settings.proxyExceptionsText)

        let bypassDomains = ClosureSetting(
            title: "Bypass domains",
            statusText: Self.entryCount(bypassEntries.count),
            handler: { [weak self] navigationController in
                self?.presentDomainEditor(
                    title: "Bypass domains",
                    footer: "One domain per line. These are loaded directly, subdomains included.",
                    text: settings.bypassDomainsText,
                    onSave: { [weak self] text in
                        guard let self, let profile = self.profile else { return }
                        ProxySettings(prefs: profile.prefs).update(bypassDomainsText: text)
                        Task { @MainActor in
                            await ProxyManager.shared.reconfigureRouting()
                            self.refreshSettings()
                        }
                    },
                    navigationController: navigationController
                )
            }
        )
        bypassDomains.enabled = ProxyManager.isSupported

        let proxyExceptions = ClosureSetting(
            title: "Proxy exceptions",
            statusText: Self.entryCount(exceptionEntries.count),
            handler: { [weak self] navigationController in
                self?.presentDomainEditor(
                    title: "Proxy exceptions",
                    footer: "Always loaded through the proxy, even when a bypass domain or country matches.",
                    text: settings.proxyExceptionsText,
                    onSave: { [weak self] text in
                        guard let self, let profile = self.profile else { return }
                        ProxySettings(prefs: profile.prefs).update(proxyExceptionsText: text)
                        Task { @MainActor in
                            await ProxyManager.shared.reconfigureRouting()
                            self.refreshSettings()
                        }
                    },
                    navigationController: navigationController
                )
            }
        )
        proxyExceptions.enabled = ProxyManager.isSupported

        return SettingSection(
            footerTitle: NSAttributedString(
                string: "Exceptions win over bypass domains, bypass domains win over the countries."
            ),
            children: [bypassDomains, proxyExceptions]
        )
    }

    private func diagnosticsSection() -> SettingSection {
        let diagnose = ClosureSetting(
            title: "Diagnose current tab",
            statusText: "Rules, DNS and the computed route",
            showsDisclosure: false,
            handler: { [weak self] _ in self?.presentDiagnostics() }
        )
        diagnose.enabled = ProxyManager.isSupported

        return SettingSection(
            footerTitle: NSAttributedString(
                string: "Shows what the router decides for the page in the current tab."
            ),
            children: [diagnose]
        )
    }

    // MARK: - Actions

    private func presentDiagnostics() {
        guard profile != nil else { return }
        let windowManager: WindowManager = AppContainer.shared.resolve()
        let tab = windowManager.tabManager(for: windowUUID)?.selectedTab
        let url = tab?.url
        let tabRoute = tab?.proxyRoute
        Task { @MainActor in
            let text = await ProxyRoutingService.shared.diagnostics(for: url, tabRoute: tabRoute)
            self.presentDiagnosticsAlert(text)
        }
    }

    private func presentDiagnosticsAlert(_ text: String) {
        let alert = UIAlertController(title: "Proxy diagnostics", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = text
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    private func presentRoutingModePicker() {
        guard profile != nil else { return }
        let alert = UIAlertController(title: "Routing", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Proxy everything", style: .default) { [weak self] _ in
            self?.setRoutingMode(.allTraffic)
        })
        alert.addAction(UIAlertAction(title: "Bypass domains + GeoIP", style: .default) { [weak self] _ in
            self?.setRoutingMode(.rules)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func setRoutingMode(_ mode: ProxyRoutingMode) {
        guard let profile else { return }
        ProxySettings(prefs: profile.prefs).routingMode = mode
        Task { @MainActor in
            await ProxyManager.shared.reconfigureRouting()
            self.refreshSettings()
        }
    }

    private func updateGeoIPData() {
        guard let profile, !isUpdatingGeoIP else { return }
        let settings = ProxySettings(prefs: profile.prefs)
        let countries = settings.countries
        guard !countries.isEmpty else { return }

        isUpdatingGeoIP = true
        refreshSettings()
        Task { @MainActor in
            do {
                let date = try await GeoIPDataStore.shared.update(countries: countries)
                settings.update(geoIPUpdatedAt: date)
            } catch {
                presentError("Could not update GeoIP data: \(error)")
            }
            self.isUpdatingGeoIP = false
            await ProxyManager.shared.reconfigureRouting()
            self.refreshSettings()
        }
    }

    private func presentServerEditor() {
        guard let profile else { return }
        let settings = ProxySettings(prefs: profile.prefs)

        let alert = UIAlertController(
            title: "Proxy server",
            message: "Enter the host and port of an HTTP proxy.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Host"
            field.text = settings.host
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
            field.clearButtonMode = .whileEditing
            field.accessibilityIdentifier = "ProxySettings.host"
        }
        alert.addTextField { field in
            field.placeholder = "Port"
            field.text = settings.port.map { String($0) }
            field.keyboardType = .numberPad
            field.accessibilityIdentifier = "ProxySettings.port"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            let host = alert?.textFields?.first?.text ?? ""
            let port = alert?.textFields?.last?.text.flatMap { Int($0) }
            self?.saveServer(host: host, port: port)
        })
        present(alert, animated: true)
    }

    private func saveServer(host: String, port: Int?) {
        guard let profile else { return }
        let endpoint = HTTPProxyEndpoint(host: host, port: port ?? 0)
        guard endpoint.isValid else {
            presentError("Enter a valid host and a port between 1 and 65535.")
            return
        }
        Task { @MainActor in
            await ProxyManager.shared.updateEndpoint(host: endpoint.host, port: endpoint.port, profile: profile)
            self.refreshSettings()
        }
    }

    private func presentDomainEditor(title: String,
                                     footer: String,
                                     text: String,
                                     onSave: @escaping (String) -> Void,
                                     navigationController: UINavigationController?) {
        let controller = ProxyDomainListEditorViewController(title: title, footerText: footer, initialText: text)
        controller.onSave = onSave
        navigationController?.pushViewController(controller, animated: true)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Proxy", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func refreshSettings() {
        settings = generateSettings()
        tableView.reloadData()
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func entries(in text: String) -> [String] {
        return text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func entryCount(_ count: Int) -> String {
        switch count {
        case 0: return "None"
        case 1: return "1 entry"
        default: return "\(count) entries"
        }
    }
}

/// Setting that forwards taps to a closure, optionally showing a disclosure indicator or a checkmark.
final class ClosureSetting: Setting {
    private let statusText: String?
    private let showsDisclosure: Bool
    private let isSelected: Bool
    private let handler: (UINavigationController?) -> Void

    override var status: NSAttributedString? {
        guard let statusText else { return nil }
        return NSAttributedString(string: statusText)
    }

    override var accessoryType: UITableViewCell.AccessoryType {
        return isSelected ? .checkmark : .none
    }

    override var accessoryView: UIImageView? {
        guard showsDisclosure, !isSelected, let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    init(title: String,
         statusText: String? = nil,
         showsDisclosure: Bool = true,
         isSelected: Bool = false,
         handler: @escaping (UINavigationController?) -> Void) {
        self.statusText = statusText
        self.showsDisclosure = showsDisclosure
        self.isSelected = isSelected
        self.handler = handler
        super.init(title: NSAttributedString(string: title))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        handler(navigationController)
    }
}
