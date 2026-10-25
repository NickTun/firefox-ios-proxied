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
            domainsSection(profile: profile, settings: settings)
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
        case .allTraffic: modeTitle = "All traffic"
        case .rules: modeTitle = "Rules (domains + GeoIP)"
        }
        let mode = ClosureSetting(
            title: "Routing",
            statusText: modeTitle,
            handler: { [weak self] _ in self?.presentRoutingModePicker() }
        )
        mode.enabled = ProxyManager.isSupported

        return SettingSection(
            footerTitle: NSAttributedString(
                string: "Rules send a tab through the proxy when its site matches the lists below or " +
                        "the selected countries. Everything else is loaded directly."
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

        let updatedText: String
        if isUpdatingGeoIP {
            updatedText = "Updating…"
        } else if let date = settings.geoIPUpdatedAt {
            updatedText = "Updated \(Self.dateFormatter.string(from: date))"
        } else {
            updatedText = "Not downloaded"
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
                string: "Countries are matched with public per-country IPv4 ranges. IPv6 is not matched " +
                        "and falls back to the direct route."
            ),
            children: [countriesSetting, update]
        )
    }

    private func domainsSection(profile: Profile, settings: ProxySettings) -> SettingSection {
        let proxyEntries = settings.proxyDomainsText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let excludedEntries = settings.excludedDomainsText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let proxyDomains = ClosureSetting(
            title: "Proxy domains",
            statusText: Self.entryCount(proxyEntries.count),
            handler: { [weak self] navigationController in
                self?.presentDomainEditor(
                    title: "Proxy domains",
                    footer: "One domain per line. Subdomains are included.",
                    text: settings.proxyDomainsText,
                    onSave: { [weak self] text in
                        guard let self, let profile = self.profile else { return }
                        ProxySettings(prefs: profile.prefs).update(proxyDomainsText: text)
                        Task { @MainActor in
                            await ProxyManager.shared.reconfigureRouting()
                            self.refreshSettings()
                        }
                    },
                    navigationController: navigationController
                )
            }
        )
        proxyDomains.enabled = ProxyManager.isSupported

        let excludedDomains = ClosureSetting(
            title: "Direct domains",
            statusText: Self.entryCount(excludedEntries.count),
            handler: { [weak self] navigationController in
                self?.presentDomainEditor(
                    title: "Direct domains",
                    footer: "Always loaded directly, even when a country or the proxy list matches.",
                    text: settings.excludedDomainsText,
                    onSave: { [weak self] text in
                        guard let self, let profile = self.profile else { return }
                        ProxySettings(prefs: profile.prefs).update(excludedDomainsText: text)
                        Task { @MainActor in
                            await ProxyManager.shared.reconfigureRouting()
                            self.refreshSettings()
                        }
                    },
                    navigationController: navigationController
                )
            }
        )
        excludedDomains.enabled = ProxyManager.isSupported

        return SettingSection(
            footerTitle: NSAttributedString(
                string: "Exceptions win over the proxy domains, proxy domains win over the countries."
            ),
            children: [proxyDomains, excludedDomains]
        )
    }

    // MARK: - Actions

    private func presentRoutingModePicker() {
        guard profile != nil else { return }
        let alert = UIAlertController(title: "Routing", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "All traffic", style: .default) { [weak self] _ in
            self?.setRoutingMode(.allTraffic)
        })
        alert.addAction(UIAlertAction(title: "Rules (domains + GeoIP)", style: .default) { [weak self] _ in
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
