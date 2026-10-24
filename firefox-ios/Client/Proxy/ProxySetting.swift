// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared

/// Settings row that opens the browser wide HTTP proxy screen.
final class ProxySetting: Setting {
    private let profile: Profile
    private weak var settingsDelegate: GeneralSettingsDelegate?

    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    override var status: NSAttributedString? {
        return NSAttributedString(string: ProxySetting.statusText(for: profile))
    }

    init(profile: Profile,
         settingsDelegate: GeneralSettingsDelegate?,
         theme: Theme) {
        self.profile = profile
        self.settingsDelegate = settingsDelegate
        super.init(
            title: NSAttributedString(
                string: "Proxy",
                attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textPrimary]
            )
        )
    }

    override func onClick(_ navigationController: UINavigationController?) {
        settingsDelegate?.pressedProxy()
    }

    private static func statusText(for profile: Profile) -> String {
        guard ProxyManager.isSupported else { return "Requires iOS 17 or later" }
        let settings = ProxySettings(prefs: profile.prefs)
        guard settings.isEnabled else { return "Off" }
        return settings.endpoint?.displayName ?? "Not configured"
    }
}
