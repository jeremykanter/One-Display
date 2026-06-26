//
//  LoginItem.swift
//  One Display
//
//  Wraps the modern ServiceManagement login-item API (`SMAppService.mainApp`,
//  macOS 13+) so the main window can offer a "Start at login" checkbox. No
//  helper bundle or privileged registration is required — the main app
//  registers itself.
//

import Combine
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {

    /// Mirrors whether the app is registered to launch at login. Drives the
    /// checkbox; kept in sync after every register/unregister.
    @Published private(set) var isEnabled: Bool = (SMAppService.mainApp.status == .enabled)

    /// Re-read the live status (e.g. the user changed it in System Settings).
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item. Registering may surface a
    /// one-time approval prompt in System Settings → General → Login Items.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("One Display: failed to %@ login item: %@",
                  enabled ? "enable" : "disable", error.localizedDescription)
        }
        refresh()
    }
}
