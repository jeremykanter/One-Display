//
//  One_DisplayApp.swift
//  One Display
//

import SwiftUI

@main
struct One_DisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Controls whether the activity log is mirrored to a file on the Desktop.
    /// Defaults off (a missing UserDefaults bool reads as `false`).
    @AppStorage("saveActivityLogs") private var saveActivityLogs = false

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .help) {
                Toggle("Save Activity Logs", isOn: $saveActivityLogs)
            }
        }
    }
}

/// Owns the display-watching lifecycle so it survives the status window being
/// closed. The actual work lives in `DisplayController`.
///
/// Runs "headless": the app is a regular foreground app (Dock icon + menu bar)
/// only while its settings window is open, and drops to `.accessory` once the
/// window closes so it keeps watching displays in the background with no Dock
/// presence. Relaunching from Spotlight/Finder reopens the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Flip to background (accessory) once the user closes the settings
        // window, so the app runs headless without a Dock icon.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil)

        // Never manipulate displays while running under XCTest — the unit-test
        // target hosts this app, and UI tests launch it, so acting here would
        // disable the developer's screen during a test run.
        guard !Self.isRunningUnderTests else { return }
        DisplayController.shared.start()
    }

    /// Keep the app alive (headless) when the settings window is closed — the
    /// display watcher, lid monitor, and hotkey all live on past the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Relaunching from Spotlight/Finder while already running: bring the app
    /// back to the foreground and reopen the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// When the last visible window closes, go headless (no Dock icon).
    @objc private func windowWillClose(_ notification: Notification) {
        // The closing window is still in `NSApp.windows` during this
        // notification, so defer the check to the next runloop tick.
        DispatchQueue.main.async {
            let hasVisibleWindow = NSApp.windows.contains {
                $0.isVisible && !($0 is NSPanel)
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: never quit leaving the built-in panel disabled with no
        // watcher running to bring it back.
        DisplayController.shared.restoreBuiltInOnQuit()
    }

    static var isRunningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return CommandLine.arguments.contains("-uiTestingDisableAutomation")
    }
}
