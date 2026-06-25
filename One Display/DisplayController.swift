//
//  DisplayController.swift
//  One Display
//
//  Watches for display connect/disconnect and, when any external display is
//  present, truly disables the built-in panel so the external becomes the only
//  usable screen. Re-enables the built-in when the last external is removed.
//

import AppKit
import CoreGraphics
import Combine

/// The action the policy wants us to take on the built-in display.
enum BuiltInAction: Equatable {
    case disableBuiltIn
    case enableBuiltIn
    case noChange
}

/// Pure decision function — no side effects, so it can be unit-tested.
///
/// - Parameters:
///   - externalCount: number of *active* external displays.
///   - builtInActive: whether the built-in panel is currently active (drawable).
func desiredBuiltInState(externalCount: Int, builtInActive: Bool) -> BuiltInAction {
    if externalCount > 0 {
        // An external is present: the built-in should be off.
        return builtInActive ? .disableBuiltIn : .noChange
    } else {
        // No external: the built-in must be on (never leave zero displays).
        return builtInActive ? .noChange : .enableBuiltIn
    }
}

/// Lightweight description of a display for the status UI.
struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let isBuiltIn: Bool
    let isActive: Bool

    var name: String { isBuiltIn ? "Built-in display" : "External display" }
}

/// Free function so it converts cleanly to a C function pointer (captures nothing;
/// the controller is passed through `userInfo`). Invoked by the WindowServer for
/// every display reconfiguration, even when the app has no on-screen window.
private nonisolated func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let controller = Unmanaged<DisplayController>.fromOpaque(userInfo).takeUnretainedValue()
    // The first callback of every change is just a "begin" pre-notification with
    // no useful flags — wait for the settled "after" callback.
    if flags.contains(.beginConfigurationFlag) { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            controller.handleReconfiguration(display: display, flags: flags)
        }
    }
}

@MainActor
final class DisplayController: ObservableObject {

    static let shared = DisplayController()

    // MARK: Published state (drives the status UI)

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var builtInDisabled: Bool = false
    @Published private(set) var log: [String] = []
    /// When off, screen changes are observed but no automatic action is taken.
    /// Useful for testing the manual override buttons.
    @Published var automationEnabled: Bool = true
    /// When on, closing the lid while an external is connected sleeps the Mac
    /// instead of entering macOS clamshell mode.
    @Published var sleepOnLidClose: Bool = true

    // MARK: Private state

    /// The built-in display ID can change across reconfigurations, so we always
    /// re-resolve it from the live display list and only fall back to this cache
    /// when the panel is currently disabled and absent from every list.
    private var cachedBuiltInID: CGDirectDisplayID?
    /// Guards against re-entrancy while a reconfiguration is in flight.
    private var isApplying = false
    /// Coalesces the burst of callbacks macOS posts for a single change.
    private var pendingApply: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    /// Keeps the app from being App-Napped (which would throttle the timers and
    /// callbacks we rely on once the app loses its on-screen window).
    private var activityToken: NSObjectProtocol?
    private var didRegisterReconfig = false
    /// Set to the built-in display ID while *we* are holding it disabled; nil
    /// otherwise. Lets us re-enable on the external's removal event without being
    /// fooled by the placeholder display macOS spins up to avoid zero displays.
    private var disabledBuiltInID: CGDirectDisplayID?
    private let lidMonitor = LidMonitor()
    private let hotKey = HotKeyManager()

    /// Activity log is mirrored to this file for easy sharing while testing.
    private let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/One Display Log.txt")

    /// Whether to mirror the activity log to the Desktop file. Toggled from the
    /// Help → "Save Activity Logs" menu item; defaults off.
    private var saveLogsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "saveActivityLogs")
    }

    private init() {}

    // MARK: Lifecycle

    /// Begin observing display changes and apply the policy once for the
    /// current configuration.
    func start() {
        guard !didRegisterReconfig else { return }
        didRegisterReconfig = true

        // Prevent App Nap so our display callbacks/timers stay prompt even when
        // the app has no visible window (e.g. right after an unplug, and later
        // when running headless).
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled],
            reason: "Monitoring external displays")

        // Primary, low-level trigger: fires for every display reconfiguration.
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, ptr)

        // Secondary, belt-and-suspenders trigger.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleApply()
            }
        }

        // Sleep on lid close (override clamshell) when an external is connected.
        lidMonitor.onLidClosed = { [weak self] in
            self?.handleLidClosed()
        }
        lidMonitor.start()

        // Global ⌃⌘B toggles the built-in display (manual override for testing).
        hotKey.onTrigger = { [weak self] in
            self?.toggleBuiltIn()
        }
        hotKey.register()

        startLogFile()
        appendLog("Started — watching for display changes.")
        refreshDisplays()
        apply()
    }

    /// Toggle the built-in panel by hand (⌃⌘B). Pauses automation so the chosen
    /// state sticks instead of being immediately re-applied by policy.
    func toggleBuiltIn() {
        automationEnabled = false
        if isBuiltInActive() {
            guard !externalDisplayIDs().isEmpty, let id = builtInDisplayID() else {
                appendLog("Hotkey ⌃⌘B: refused to disable built-in (no external display).")
                return
            }
            appendLog("Hotkey ⌃⌘B: built-in OFF (automation paused).")
            performDisable(id)
        } else {
            appendLog("Hotkey ⌃⌘B: built-in ON (automation paused).")
            performEnable()
        }
    }

    private func handleLidClosed() {
        guard sleepOnLidClose else { return }
        guard !externalDisplayIDs().isEmpty else { return }   // OS already sleeps otherwise
        appendLog("Lid closed with external connected → sleeping system.")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["sleepnow"]
        do {
            try task.run()
        } catch {
            appendLog("Sleep failed: \(error.localizedDescription)")
        }
    }

    /// Called from the CoreGraphics reconfiguration callback (on the main actor).
    func handleReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        appendLog("Reconfig: display \(display) [\(describe(flags))]")

        // If a display other than the one we disabled is removed while we hold
        // the built-in disabled, the external is gone — restore the built-in
        // immediately. We trigger on the removal event (not the display count)
        // because macOS adds a non-built-in placeholder display on the last
        // unplug, which would otherwise look like "an external is still here".
        if flags.contains(.removeFlag),
           automationEnabled,
           let disabledID = disabledBuiltInID,
           display != disabledID {
            appendLog("External \(display) removed while built-in held off → re-enabling.")
            performEnable()
            return
        }

        scheduleApply()
    }

    // MARK: Policy

    private func scheduleApply() {
        refreshDisplays()
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.apply()
        }
        pendingApply = work
        // Coalesce rapid bursts; idempotency also prevents loops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Evaluate the current configuration and disable/enable the built-in panel
    /// to match the policy. Safe to call repeatedly (idempotent).
    func apply() {
        guard !isApplying else { return }
        guard automationEnabled else {
            appendLog("Change detected (automation off — no action).")
            return
        }

        let externals = externalDisplayIDs()
        let builtInActive = isBuiltInActive()
        let builtInID = builtInDisplayID()
        let action = desiredBuiltInState(externalCount: externals.count,
                                         builtInActive: builtInActive)
        appendLog("Evaluate: externals=\(externals.count) builtInActive=\(builtInActive) "
                  + "builtInID=\(builtInID.map(String.init) ?? "nil") action=\(action)")

        switch action {
        case .noChange:
            return
        case .disableBuiltIn:
            // Safety: only ever disable the built-in while an external is active.
            guard !externals.isEmpty, let id = builtInID else { return }
            performDisable(id)
        case .enableBuiltIn:
            performEnable()
        }
    }

    /// Re-enable the built-in panel synchronously on quit so the display is
    /// never left disabled with no watcher running.
    func restoreBuiltInOnQuit() {
        guard !isBuiltInActive() else { return }
        appendLog("Quitting — restoring built-in display.")
        performEnable(verify: false)
    }

    // MARK: Manual override (used for the spike / manual control)

    /// Disable the built-in panel by hand. Still refuses to act unless an
    /// external display is active, to avoid leaving zero usable screens.
    func manualDisableBuiltIn() {
        guard !externalDisplayIDs().isEmpty else {
            appendLog("Refused: cannot disable built-in with no external display.")
            return
        }
        guard let id = builtInDisplayID() else {
            appendLog("Refused: could not resolve built-in display ID.")
            return
        }
        appendLog("Manual: disabling built-in display.")
        performDisable(id)
    }

    /// Re-enable the built-in panel by hand.
    func manualEnableBuiltIn() {
        appendLog("Manual: enabling built-in display.")
        performEnable()
    }

    // MARK: Reconfiguration

    /// Disable the built-in panel for this session via the private SkyLight API.
    private func performDisable(_ id: CGDirectDisplayID) {
        isApplying = true
        defer { isApplying = false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            appendLog("Error: CGBeginDisplayConfiguration failed.")
            return
        }
        let err = CGSConfigureDisplayEnabled(config, id, false)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            appendLog("Error: CGSConfigureDisplayEnabled(false) returned \(err.rawValue).")
            return
        }
        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        guard completeErr == .success else {
            appendLog("Error: CGCompleteDisplayConfiguration returned \(completeErr.rawValue).")
            return
        }
        disabledBuiltInID = id
        refreshDisplays()
        appendLog("Applied: built-in DISABLED.")
    }

    /// Re-enable the built-in panel. The explicit SkyLight enable is the reliable
    /// path on macOS 26 (the log showed `CGRestorePermanentDisplayConfiguration`
    /// leaving the panel dark); permanent-config restore is the fallback.
    private func performEnable(verify: Bool = true) {
        if let id = builtInDisplayID() {
            explicitEnable(id)
        } else {
            appendLog("Enable: built-in display ID unknown — restoring permanent config.")
            applyRestore()
        }

        guard verify else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if !self.isBuiltInActive() {
                self.appendLog("Built-in still off after explicit enable — restoring permanent config.")
                self.applyRestore()
            }
        }
    }

    /// Enable a specific display via the private SkyLight API.
    private func explicitEnable(_ id: CGDirectDisplayID) {
        isApplying = true
        defer { isApplying = false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            appendLog("Error: CGBeginDisplayConfiguration failed.")
            return
        }
        let err = CGSConfigureDisplayEnabled(config, id, true)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            appendLog("Error: CGSConfigureDisplayEnabled(true) returned \(err.rawValue).")
            return
        }
        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        if isBuiltInActive() { disabledBuiltInID = nil }
        refreshDisplays()
        appendLog("Applied: explicit enable (complete=\(completeErr.rawValue)).")
    }

    /// Public fallback that clears any temporary (`.forSession`) display changes.
    private func applyRestore() {
        isApplying = true
        CGRestorePermanentDisplayConfiguration()
        isApplying = false
        if isBuiltInActive() { disabledBuiltInID = nil }
        refreshDisplays()
        appendLog("Applied: restored permanent display configuration.")
    }

    // MARK: Display enumeration

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func externalDisplayIDs() -> [CGDirectDisplayID] {
        activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private func isBuiltInActive() -> Bool {
        activeDisplayIDs().contains { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Resolve the built-in display ID fresh each time (IDs can change across
    /// reconfigurations), updating the cache. Falls back to the cache only when
    /// the panel is disabled and absent from the live lists.
    private func builtInDisplayID() -> CGDirectDisplayID? {
        for id in onlineDisplayIDs() where CGDisplayIsBuiltin(id) != 0 {
            cachedBuiltInID = id
            return id
        }
        for id in activeDisplayIDs() where CGDisplayIsBuiltin(id) != 0 {
            cachedBuiltInID = id
            return id
        }
        return cachedBuiltInID
    }

    private func refreshDisplays() {
        let active = Set(activeDisplayIDs())
        var infos: [DisplayInfo] = onlineDisplayIDs().map { id in
            DisplayInfo(id: id,
                        isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                        isActive: active.contains(id))
        }
        // A disabled built-in may drop off the online list; show it anyway.
        if let id = cachedBuiltInID, !infos.contains(where: { $0.id == id }) {
            infos.append(DisplayInfo(id: id, isBuiltIn: true, isActive: false))
        }
        displays = infos.sorted { $0.isBuiltIn && !$1.isBuiltIn }
        builtInDisabled = !active.contains { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: Logging

    private func describe(_ flags: CGDisplayChangeSummaryFlags) -> String {
        var parts: [String] = []
        if flags.contains(.addFlag) { parts.append("added") }
        if flags.contains(.removeFlag) { parts.append("removed") }
        if flags.contains(.enabledFlag) { parts.append("enabled") }
        if flags.contains(.disabledFlag) { parts.append("disabled") }
        if flags.contains(.movedFlag) { parts.append("moved") }
        if flags.contains(.setMainFlag) { parts.append("setMain") }
        if flags.contains(.setModeFlag) { parts.append("setMode") }
        return parts.isEmpty ? "—" : parts.joined(separator: ",")
    }

    private func appendLog(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        let line = "[\(stamp)] \(message)"
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        print("One Display:", message)
        writeLogLine(line)
    }

    /// Start a fresh log file on the Desktop for this session.
    private func startLogFile() {
        guard saveLogsEnabled else { return }
        let header = "One Display log — session started \(Date().formatted())\n"
        try? header.write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    /// Append a single line to the Desktop log file. No-op while log saving is
    /// disabled; lazily (re)creates the file when enabled mid-session.
    private func writeLogLine(_ line: String) {
        guard saveLogsEnabled else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            // File missing (e.g. first write failed) — recreate it.
            try? data.write(to: logFileURL)
        }
    }
}
