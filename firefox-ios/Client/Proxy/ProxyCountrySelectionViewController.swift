// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import UIKit
import WebEngine

/// Selects the countries whose IPv4 ranges are routed through the proxy.
final class ProxyCountrySelectionViewController: SettingsTableViewController {
    init(profile: Profile, windowUUID: WindowUUID) {
        super.init(style: .grouped, windowUUID: windowUUID)
        self.profile = profile
        self.title = "Countries"
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func generateSettings() -> [SettingSection] {
        guard let profile else { return [] }
        let selected = Set(ProxySettings(prefs: profile.prefs).countries)

        let rows: [Setting] = Self.allCountries.map { country in
            let row = ClosureSetting(
                title: country.name,
                statusText: country.code,
                showsDisclosure: false,
                isSelected: selected.contains(country.code),
                handler: { [weak self] _ in self?.toggle(country.code) }
            )
            row.enabled = ProxyManager.isSupported
            return row
        }

        return [
            SettingSection(
                footerTitle: NSAttributedString(
                    string: "Sites in a selected country are loaded directly, matched by address or by " +
                            "the country domain. Data is downloaded when a country is selected."
                ),
                children: rows
            )
        ]
    }

    // MARK: - Actions

    private func toggle(_ countryCode: String) {
        guard let profile else { return }
        let settings = ProxySettings(prefs: profile.prefs)
        var selected = Set(settings.countries)
        if selected.contains(countryCode) {
            selected.remove(countryCode)
        } else {
            selected.insert(countryCode)
        }
        settings.update(countries: Array(selected).sorted())
        reload()

        Task { @MainActor in
            let hasData = await GeoIPDataStore.shared.hasData(for: countryCode)
            if selected.contains(countryCode), !hasData {
                do {
                    let date = try await GeoIPDataStore.shared.update(countries: [countryCode])
                    settings.update(geoIPUpdatedAt: date)
                } catch {
                    // Failing to download keeps the country selected; the explicit update row retries it.
                }
            }
            await ProxyManager.shared.reconfigureRouting()
            self.reload()
        }
    }

    private func reload() {
        settings = generateSettings()
        tableView.reloadData()
    }

    // MARK: - Countries

    private static let allCountries: [(code: String, name: String)] = {
        let countries = Locale.isoRegionCodes.map { code -> (code: String, name: String) in
            let name = Locale.current.localizedString(forRegionCode: code) ?? code
            return (code: code, name: name)
        }
        return countries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()
}
