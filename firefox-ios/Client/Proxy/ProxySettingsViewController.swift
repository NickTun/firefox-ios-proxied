// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import UIKit
import WebEngine

/// Configures the browser wide HTTP proxy used for all web content.
final class ProxySettingsViewController: SettingsTableViewController {
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

        let toggleFooter = ProxyManager.isSupported
            ? "All web content is loaded through this HTTP proxy, including HTTPS which is tunnelled through it. " +
              "Firefox's own background requests are not affected."
            : "Browser wide proxying requires iOS 17 or later."
        let serverFooter = "HTTP proxy host and port, for example 192.168.1.10:8080."

        return [
            SettingSection(footerTitle: NSAttributedString(string: toggleFooter), children: [toggle]),
            SettingSection(footerTitle: NSAttributedString(string: serverFooter), children: [server])
        ]
    }

    private func refreshSettings() {
        settings = generateSettings()
        tableView.reloadData()
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

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Invalid proxy", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Setting that forwards taps to a closure, used for rows that open an editor.
final class ClosureSetting: Setting {
    private let statusText: String?
    private let handler: (UINavigationController?) -> Void

    override var status: NSAttributedString? {
        guard let statusText else { return nil }
        return NSAttributedString(string: statusText)
    }

    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    init(title: String,
         statusText: String?,
         handler: @escaping (UINavigationController?) -> Void) {
        self.statusText = statusText
        self.handler = handler
        super.init(title: NSAttributedString(string: title))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        handler(navigationController)
    }
}
