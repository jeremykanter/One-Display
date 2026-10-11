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
import KeyboardShortcuts

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

/// How to put the machine to sleep when the lid closes with an external present.
enum LidCloseSleepAction: Equatable {
    case fullSleep
    case displaySleepOnly
}

/// Pure decision function — no side effects, so it can be unit-tested.
///
/// When the active power profile is set to never auto-sleep the system while the
/// display is off (System Sleep Timer == 0 — the "Prevent automatic sleeping …
/// when the display is off" option), mirror that: sleep only the displays and
/// leave the system awake. `nil` (unreadable) falls back to a full system sleep
/// so behavior never regresses.
func lidCloseSleepAction(systemSleepTimerMinutes: Int?) -> LidCloseSleepAction {
    systemSleepTimerMinutes == 0 ? .displaySleepOnly : .fullSleep
}

/// What to do for the built-in panel once the screens come back on.
enum WakeRecoveryAction: Equatable {
    case retryEnable
    case reevaluate
}

/// Pure decision function — no side effects, so it can be unit-tested.
///
/// An enable attempted while the panels were asleep is refused by the
/// WindowServer, and the placeholder display macOS spins up in that state makes
/// the normal policy read "an external is still here". So the only trustworthy
/// signal on wake is our own recorded intent: if we wanted the built-in on and
/// it still isn't, try again.
func wakeRecoveryAction(pendingEnable: Bool, builtInActive: Bool) -> WakeRecoveryAction {
    pendingEnable && !builtInActive ? .retryEnable : .reevaluate
}

/// Pure decision function — no side effects, so it can be unit-tested.
///
/// Backoff between repeated enable attempts, or `nil` once we have tried enough
/// times and should wait for the next display change or wake instead of
/// hammering the WindowServer.
func enableRetryDelay(attempt: Int) -> TimeInterval? {
    switch attempt {
    case 0: return 1
    case 1: return 3
    case 2: return 8
    default: return nil
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
    // no useful flags — wait for the settled "after" callback before acting on
    // the display policy. It is still worth forwarding: it arrives before macOS
    // rearranges windows, which is the only moment the window-layout feature can
    // record where they actually were.
    if flags.contains(.beginConfigurationFlag) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                controller.windowLayout.beginTransition()
            }
        }
        return
    }
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
    /// True while a shortcut toggle is holding the built-in against what automation
    /// would do. Suppresses the auto-policy until the next external connect/disconnect,
    /// then clears so automation resumes. Distinct from `automationEnabled`, which is
    /// the global on/off master switch.
    @Published private(set) var manualOverrideActive = false
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
    /// True between a screens-asleep and a screens-awake notification. The
    /// WindowServer refuses `.forSession` display configurations while the
    /// panels are off — it blocks for ~10 s and then fails — so everything the
    /// policy wants to do is recorded and settled on wake instead.
    private var screensAsleep = false
    /// A policy evaluation was skipped because the screens were asleep.
    private var needsApplyOnWake = false
    /// True while we want the built-in panel on but have not confirmed that it
    /// is. Survives sleep, which is what lets the wake handler finish the job
    /// after an unplug the WindowServer refused to act on.
    private var pendingBuiltInEnable = false
    /// Pending verify/retry pass for an enable that has not taken effect yet.
    private var enableRetryWork: DispatchWorkItem?
    private var enableAttempt = 0
    /// Settle pass scheduled after the screens come back.
    private var wakeWork: DispatchWorkItem?
    /// Slow re-check while work is deferred. The wake notification is the
    /// primary trigger; this makes sure a missed notification — or panels that
    /// read as asleep outside a real sleep cycle — can never leave the built-in
    /// dark with nothing coming to fix it.
    private var deferredRecheckWork: DispatchWorkItem?
    private static let deferredRecheckInterval: TimeInterval = 5
    private var sleepObservers: [NSObjectProtocol] = []
    /// How long to let the WindowServer settle after a wake before acting. It is
    /// still shuffling displays for a moment after the panels light up.
    private static let wakeSettleDelay: TimeInterval = 1.0
    private let lidMonitor = LidMonitor()
    /// Remembers window positions per display arrangement. Opt-in and inert
    /// until enabled from Settings.
    let windowLayout = WindowLayoutManager()

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

        // Sleep/wake. Nothing else re-evaluates the policy when the screens come
        // back: the AppKit notification above fires on some wakes but not
        // others, and the reconfiguration callback never fires for a change that
        // happened while the Mac was asleep.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            sleepObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleScreensAsleep()
                }
            })
        }
        sleepObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreensDidWake()
            }
        })
        // A system wake with the panels still off is a DarkWake — acting then
        // would hit the same refusal that started this. Check the hardware
        // rather than our own flag, which the screens-wake notification clears.
        sleepObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panelsAreAsleep() else { return }
                self.handleScreensDidWake()
            }
        })

        // Sleep on lid close (override clamshell) when an external is connected.
        lidMonitor.onLidClosed = { [weak self] in
            self?.handleLidClosed()
        }
        lidMonitor.start()

        // Global shortcut (default ⌃⌘B) toggles the built-in display. The combo
        // is user-customizable and can be turned off entirely from Settings.
        KeyboardShortcuts.onKeyUp(for: .toggleBuiltInDisplay) { [weak self] in
            self?.toggleBuiltIn()
        }
        applyShortcutEnabledState()

        windowLayout.onLog = { [weak self] message in self?.appendLog(message) }
        windowLayout.policyIsStable = { [weak self] in self?.isPolicyStable ?? true }
        applyWindowLayoutEnabledState()

        startLogFile()
        appendLog("Started — watching for display changes.")
        refreshDisplays()
        apply()
    }

    /// Toggle the built-in panel by hand via the keyboard shortcut. When the
    /// chosen state differs from what automation would do, it's held as a
    /// temporary override (automation stays on but takes no action until the
    /// next external connect/disconnect). When the chosen state already matches
    /// policy — e.g. turning the built-in back off while an external is present —
    /// no override is held and automation is effectively back in control.
    func toggleBuiltIn() {
        let externalCount = externalDisplayIDs().count
        let intendedBuiltInActive: Bool
        if isBuiltInActive() {
            guard externalCount > 0, let id = builtInDisplayID() else {
                appendLog("Shortcut: refused to disable built-in (no external display).")
                return
            }
            appendLog("Shortcut: built-in OFF.")
            performDisable(id)
            intendedBuiltInActive = false
        } else {
            appendLog("Shortcut: built-in ON.")
            performEnable()
            intendedBuiltInActive = true
        }

        let action = desiredBuiltInState(externalCount: externalCount,
                                         builtInActive: intendedBuiltInActive)
        manualOverrideActive = action != .noChange
        appendLog(manualOverrideActive
                  ? "Override held until next display change."
                  : "Built-in matches automation — override cleared.")
    }

    /// Persisted on/off state of the toggle-display shortcut. Defaults on so
    /// existing users keep the previously hardcoded ⌃⌘B behavior.
    private var shortcutEnabledSetting: Bool {
        UserDefaults.standard.object(forKey: "toggleShortcutEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "toggleShortcutEnabled")
    }

    /// Enable or disable the global shortcut to match the persisted setting.
    /// Called on launch and whenever the Settings checkbox changes.
    func applyShortcutEnabledState() {
        if shortcutEnabledSetting {
            KeyboardShortcuts.enable(.toggleBuiltInDisplay)
        } else {
            KeyboardShortcuts.disable(.toggleBuiltInDisplay)
        }
    }

    /// Persisted on/off state of the window-position feature. Defaults off: it
    /// needs the Accessibility permission and moves other apps' windows, so it
    /// must never turn itself on.
    private var rememberWindowPositionsSetting: Bool {
        UserDefaults.standard.bool(forKey: "rememberWindowPositions")
    }

    /// Enable or disable window-position tracking to match the persisted
    /// setting. Called on launch and whenever the Settings checkbox changes.
    func applyWindowLayoutEnabledState() {
        windowLayout.setEnabled(rememberWindowPositionsSetting)
    }

    private func handleLidClosed() {
        guard sleepOnLidClose else { return }
        guard !externalDisplayIDs().isEmpty else { return }   // OS already sleeps otherwise

        switch lidCloseSleepAction(systemSleepTimerMinutes: activeSystemSleepTimerMinutes()) {
        case .displaySleepOnly:
            appendLog("Lid closed with external → display sleep only (system stays awake per power setting).")
            runPmset(["displaysleepnow"])
        case .fullSleep:
            appendLog("Lid closed with external → sleeping system.")
            runPmset(["sleepnow"])
        }
    }

    /// Launch `pmset` with the given arguments, logging any failure.
    private func runPmset(_ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = arguments
        do {
            try task.run()
        } catch {
            appendLog("pmset \(arguments.joined(separator: " ")) failed: \(error.localizedDescription)")
        }
    }

    /// The configured "System Sleep Timer" (minutes) for the active power source,
    /// parsed from `pmset -g`, or `nil` if it can't be determined. A value of 0
    /// means the system is set to never auto-sleep while the display is off (the
    /// "Prevent automatic sleeping … when the display is off" option). `pmset -g`
    /// already reports the currently active power source, so no AC/battery check
    /// is needed here.
    private func activeSystemSleepTimerMinutes() -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            appendLog("pmset -g failed: \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Find the standalone `sleep` line (not `displaysleep`/`disksleep`). Its
        // value may be followed by a "(sleep prevented by …)" note we ignore.
        for line in output.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.count >= 2, tokens[0] == "sleep" {
                return Int(tokens[1])
            }
        }
        return nil
    }

    // MARK: Sleep and wake

    private func handleScreensAsleep() {
        guard !screensAsleep else { return }
        screensAsleep = true
        wakeWork?.cancel()
        wakeWork = nil
        enableRetryWork?.cancel()
        enableRetryWork = nil
        appendLog("Screens asleep — deferring display changes until wake.")
    }

    private func handleScreensDidWake() {
        screensAsleep = false
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleScreensAwake()
        }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettleDelay, execute: work)
    }

    /// Keep checking for as long as something is deferred, in case the wake
    /// notification never arrives.
    private func scheduleDeferredRecheck() {
        guard needsApplyOnWake || pendingBuiltInEnable else { return }
        guard deferredRecheckWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.deferredRecheckFired()
        }
        deferredRecheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deferredRecheckInterval, execute: work)
    }

    private func deferredRecheckFired() {
        deferredRecheckWork = nil
        guard needsApplyOnWake || pendingBuiltInEnable else { return }
        guard !displaysAreAsleep() else {
            scheduleDeferredRecheck()
            return
        }
        handleScreensAwake()
    }

    /// The screens are back and settled: finish whatever we deferred.
    private func handleScreensAwake() {
        wakeWork = nil
        deferredRecheckWork?.cancel()
        deferredRecheckWork = nil
        refreshDisplays()

        switch wakeRecoveryAction(pendingEnable: pendingBuiltInEnable,
                                  builtInActive: isBuiltInActive()) {
        case .retryEnable:
            appendLog("Wake: built-in should be on but isn't — re-enabling.")
            enableAttempt = 0
            performEnable()
        case .reevaluate:
            if needsApplyOnWake {
                appendLog("Wake: re-evaluating display change deferred during sleep.")
            }
        }
        needsApplyOnWake = false
        scheduleDeferredRecheck()

        // Always re-evaluate. It is idempotent, it catches a dock or undock that
        // happened while the Mac slept, and it is what corrects the re-enable
        // above if an external turns out to be attached after all.
        scheduleApply()
    }

    /// Whether the panels themselves report as off, independent of whether we
    /// saw the notification. A second, polled signal so a missed notification —
    /// or launching while the displays are already asleep — cannot leave us
    /// pushing configurations the WindowServer will refuse.
    private func panelsAreAsleep() -> Bool {
        let ids = activeDisplayIDs()
        return ids.isEmpty || ids.contains { CGDisplayIsAsleep($0) != 0 }
    }

    private func displaysAreAsleep() -> Bool {
        screensAsleep || panelsAreAsleep()
    }

    /// Called from the CoreGraphics reconfiguration callback (on the main actor).
    func handleReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        windowLayout.beginTransition()
        appendLog("Reconfig: display \(display) [\(describe(flags))]")
        if flags.contains(.addFlag) || flags.contains(.removeFlag) {
            appendLog("  display \(display): \(describeIdentity(display))")
        }

        // A real external connect/disconnect ends any temporary override and lets
        // automation take over again. Built-in enable/disable events (our own toggle
        // actions) are ignored — they are not external hotplugs.
        if manualOverrideActive,
           flags.contains(.addFlag) || flags.contains(.removeFlag),
           CGDisplayIsBuiltin(display) == 0 {
            appendLog("External hotplug — override cleared, automation resumes.")
            manualOverrideActive = false
        }

        // While the panels are asleep the WindowServer refuses display
        // configuration changes (it blocks for ~10 s, then fails) and adds a
        // placeholder display that makes the policy read "an external is still
        // here". Record what we want and settle it on wake instead.
        if displaysAreAsleep() {
            if flags.contains(.removeFlag),
               automationEnabled,
               let disabledID = disabledBuiltInID,
               display != disabledID {
                pendingBuiltInEnable = true
                appendLog("External \(display) removed while screens asleep → re-enabling on wake.")
            }
            needsApplyOnWake = true
            scheduleDeferredRecheck()
            windowLayout.policySettled(didMutate: false)
            return
        }

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
            windowLayout.policySettled(didMutate: false)
            return
        }
        guard !manualOverrideActive else {
            appendLog("Change detected (manual override held — no action).")
            windowLayout.policySettled(didMutate: false)
            return
        }
        guard !displaysAreAsleep() else {
            appendLog("Change detected (screens asleep — deferring to wake).")
            needsApplyOnWake = true
            scheduleDeferredRecheck()
            windowLayout.policySettled(didMutate: false)
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
            windowLayout.policySettled(didMutate: false)
        case .disableBuiltIn:
            // Safety: only ever disable the built-in while an external is active.
            guard !externals.isEmpty, let id = builtInID else {
                windowLayout.policySettled(didMutate: false)
                return
            }
            performDisable(id)
            windowLayout.policySettled(didMutate: true)
        case .enableBuiltIn:
            performEnable()
            windowLayout.policySettled(didMutate: true)
        }
    }

    /// Whether the built-in display policy has nothing left to do right now.
    ///
    /// The window-layout feature checks this before moving anything: if a
    /// disable or enable is still pending, another reconfiguration is coming and
    /// restoring against the current geometry would be wasted work. Automation
    /// being off (or an override being held) counts as stable — policy has
    /// deliberately decided to do nothing.
    var isPolicyStable: Bool {
        guard automationEnabled, !manualOverrideActive else { return true }
        guard !displaysAreAsleep() else { return true }
        return desiredBuiltInState(externalCount: externalDisplayIDs().count,
                                   builtInActive: isBuiltInActive()) == .noChange
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
        // Policy deliberately wants the panel off; any enable we were still
        // chasing is superseded.
        clearPendingEnable()
        refreshDisplays()
        appendLog("Applied: built-in DISABLED.")
    }

    /// Re-enable the built-in panel. The explicit SkyLight enable is the reliable
    /// path on macOS 26 (the log showed `CGRestorePermanentDisplayConfiguration`
    /// leaving the panel dark); permanent-config restore is the fallback.
    private func performEnable(verify: Bool = true) {
        // `verify: false` is the quit path — it must run regardless, so the
        // panel is never left disabled with no watcher running.
        if verify, displaysAreAsleep() {
            pendingBuiltInEnable = true
            appendLog("Enable deferred — screens are asleep; re-enabling on wake.")
            scheduleDeferredRecheck()
            return
        }

        pendingBuiltInEnable = true
        if let id = builtInDisplayID() {
            explicitEnable(id)
        } else {
            appendLog("Enable: built-in display ID unknown — restoring permanent config.")
            applyRestore()
        }

        guard verify, pendingBuiltInEnable else { return }
        enableRetryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.verifyEnable()
        }
        enableRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Confirm the panel really came back; fall back to the permanent-config
    /// restore, then retry on a bounded backoff. The WindowServer refuses the
    /// occasional attempt right after a display change, and a refused enable
    /// used to leave the machine with a dark built-in and nothing retrying.
    private func verifyEnable() {
        enableRetryWork = nil
        guard pendingBuiltInEnable else { return }
        if isBuiltInActive() {
            clearPendingEnable()
            return
        }

        appendLog("Built-in still off after explicit enable — restoring permanent config.")
        applyRestore()
        guard pendingBuiltInEnable else { return }

        guard !displaysAreAsleep() else {
            appendLog("Built-in still off and screens are asleep — retrying on wake.")
            scheduleDeferredRecheck()
            return
        }
        guard let delay = enableRetryDelay(attempt: enableAttempt) else {
            appendLog("Error: built-in still off after \(enableAttempt) retries — "
                      + "waiting for the next display change or wake.")
            enableAttempt = 0
            return
        }
        enableAttempt += 1
        appendLog("Built-in still off — retrying enable in \(Int(delay))s.")
        let work = DispatchWorkItem { [weak self] in
            self?.performEnable()
        }
        enableRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// We are no longer waiting for an enable to take effect.
    private func clearPendingEnable() {
        pendingBuiltInEnable = false
        enableAttempt = 0
        enableRetryWork?.cancel()
        enableRetryWork = nil
    }

    /// The built-in came back: we are neither holding it off nor still chasing
    /// an enable.
    private func clearHoldIfBuiltInActive() {
        guard isBuiltInActive() else { return }
        disabledBuiltInID = nil
        clearPendingEnable()
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
        clearHoldIfBuiltInActive()
        refreshDisplays()
        if completeErr == .success {
            appendLog("Applied: explicit enable.")
        } else {
            // Seen as 1014 when the panels are asleep — undocumented, and the
            // call blocks for ~10 s before returning it.
            appendLog("Error: CGCompleteDisplayConfiguration(enable) returned \(completeErr.rawValue).")
        }
    }

    /// Public fallback that clears any temporary (`.forSession`) display changes.
    private func applyRestore() {
        isApplying = true
        CGRestorePermanentDisplayConfiguration()
        isApplying = false
        clearHoldIfBuiltInActive()
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

    /// Identity attributes for a display, logged on every hotplug. macOS spins
    /// up a placeholder display when the last real one goes away while the
    /// built-in is held off; the log is how we learn to recognize it.
    private func describeIdentity(_ id: CGDirectDisplayID) -> String {
        let size = CGDisplayScreenSize(id)
        let name = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == id
        }?.localizedName ?? "—"
        return "vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id)) "
            + "serial=\(CGDisplaySerialNumber(id)) unit=\(CGDisplayUnitNumber(id)) "
            + "size=\(Int(size.width))×\(Int(size.height))mm "
            + "builtIn=\(CGDisplayIsBuiltin(id) != 0) online=\(CGDisplayIsOnline(id) != 0) "
            + "active=\(CGDisplayIsActive(id) != 0) asleep=\(CGDisplayIsAsleep(id) != 0) "
            + "name=\"\(name)\""
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
