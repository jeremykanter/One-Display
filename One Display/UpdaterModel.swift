//
//  UpdaterModel.swift
//  One Display
//

import AppKit
import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle's updater and exposes its state to SwiftUI. Sparkle itself is
/// the source of truth for the "check automatically" preference — the toggle
/// reads and writes `automaticallyChecksForUpdates` straight through.
///
/// Feed URL, public EdDSA key, and the default check interval live in the
/// project's `Info.plist`.
final class UpdaterModel: NSObject, ObservableObject {
    static let shared = UpdaterModel()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    /// Starts scheduled checks. Called once at launch (never under tests).
    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}

// The app usually runs headless (`.accessory`: no Dock icon, no menu bar), so
// an update alert from a background check could open behind other apps' windows.
// Become a regular app and come forward before Sparkle shows it; once the alert
// closes, `AppDelegate.windowWillClose` drops back to `.accessory` if no other
// window is open.
extension UpdaterModel: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

/// "Check for Updates…" menu item. A separate view so it observes the updater
/// itself — `Commands` bodies don't reliably refresh from the App's state.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = UpdaterModel.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
