//
//  WindowLayoutManager.swift
//  One Display
//
//  Remembers where windows sit in each display arrangement and puts them back
//  when that arrangement returns.
//
//  The hard part is that One Display *causes* display reconfigurations. Plugging
//  in an external produces two window rearrangements: one when macOS notices the
//  new display, and another when we disable the built-in panel. Capturing or
//  restoring between those would record garbage and restore against a layout
//  that is about to vanish. Hence the phase machine below — DisplayController
//  reports both the start of a transition and the point where its own policy has
//  finished acting, and we only touch windows once everything has gone quiet.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WindowLayoutManager: ObservableObject {

    // MARK: Published state (drives the settings UI)

    @Published private(set) var axTrusted = AXWindowBridge.isTrusted
    @Published private(set) var stageManagerActive = false
    @Published private(set) var lastRestoreSummary: String?

    /// Routes into `DisplayController.appendLog` so window moves show up in the
    /// same activity log as everything else.
    var onLog: ((String) -> Void)?

    /// Asks DisplayController whether its own policy has finished acting. We
    /// cannot re-derive this locally: with automation off or a manual override
    /// held, policy deliberately takes no action even though the built-in state
    /// does not match what it would otherwise want.
    var policyIsStable: (() -> Bool)?

    private(set) var isEnabled = false

    // MARK: Collaborators

    private let snapshotter = WindowSnapshotter()
    private let store = WindowLayoutStore()
    private let bridge = AXWindowBridge()

    // MARK: Phase machine

    private enum Phase { case idle, transitioning, settling, restoring }
    private var phase: Phase = .idle

    private static let idleCaptureInterval: TimeInterval = 2.0
    private static let pendingCaptureInterval: TimeInterval = 0.5
    private static let restoreGrace: TimeInterval = 0.5
    private static let applyBudget: TimeInterval = 3.0
    private static let maxPlanSize = 60
    private static let maxPendingAttempts = 3
    private static let pendingExpiry: TimeInterval = 600
    private static let maxPending = 200
    /// Re-read titles periodically so a renamed window does not keep a stale
    /// identity for the rest of the session.
    private static let descriptionRefreshEvery = 10

    private struct Binding {
        let pid: pid_t
        let bundleID: String
        var titleHash: String
    }

    private struct Pending {
        let frame: CGRect
        var attempts: Int
        let createdAt: Date
    }

    private var currentConfigKey: String?
    private var configKeyStableSince: Date?
    private var bindings: [CGWindowID: Binding] = [:]
    private var pendingRestores: [WindowIdentity: Pending] = [:]
    private struct AppInfo {
        let bundleID: String
        let name: String
        let isRegular: Bool
    }
    private var appInfoCache: [pid_t: AppInfo] = [:]
    private var captureCount = 0
    /// Last frame observed for each window, used to require two agreeing
    /// observations before a frame is committed. Rebuilt every sweep so it
    /// cannot accumulate entries for windows that have closed.
    private var lastObservedFrames: [CGWindowID: CGRect] = [:]
    /// Frames Accessibility has confirmed. A sweep frame matching one of these is
    /// trustworthy; anything else is re-checked before being recorded.
    private var lastVerifiedFrames: [CGWindowID: CGRect] = [:]
    /// Per-arrangement, per-window-ID frames for this session. Window IDs do not
    /// change when a title does, which is what makes browsers and mail clients
    /// restorable at all.
    private var sessionFrames: [String: [CGWindowID: CGRect]] = [:]

    /// Screen power, from NSWorkspace's screen sleep/wake notifications. A
    /// DarkWake keeps the displays off, so no screensDidWake arrives during one —
    /// which is exactly what makes this the right signal.
    private var screensAsleep = false
    private var screensAwakeSince: Date? = Date()
    /// A restore came due while the displays were off; run it once they wake.
    private var restoreDeferredForWake = false
    /// Logs the capture pause once per sleep rather than every two seconds.
    private var loggedGeometryPause = false
    private var wakeWork: DispatchWorkItem?
    private static let wakeQuietPeriod: TimeInterval = 3.0

    private var captureTimer: Timer?
    private var settleWork: DispatchWorkItem?
    private var trustTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var describeInFlight = false

    // MARK: Lifecycle

    func start() {
        store.onLog = { [weak self] message in self?.log(message) }
        store.load()
        refreshTrust()
        refreshStageManager()
        registerWorkspaceObservers()
        warmAllApps()

        currentConfigKey = snapshotter.currentConfigurationKey()
        configKeyStableSince = Date()
        // Launching while the displays are off (e.g. a login item started during
        // a DarkWake) must not treat geometry as trustworthy.
        screensAsleep = snapshotter.anyActiveDisplayAsleep()
        screensAwakeSince = screensAsleep ? nil : Date().addingTimeInterval(-Self.wakeQuietPeriod)
        restartCaptureTimer()

        if !AXWindowBridge.hasWindowIDSPI {
            log("Window layouts: window-ID lookup unavailable on this macOS — matching may be less precise.")
        }
        if !axTrusted {
            log("Window layouts: Accessibility not granted — recording window positions but not restoring.")
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            log("Window layouts: enabled.")
            start()
        } else {
            log("Window layouts: disabled.")
            stop()
        }
    }

    private func stop() {
        captureTimer?.invalidate(); captureTimer = nil
        trustTimer?.invalidate(); trustTimer = nil
        settleWork?.cancel(); settleWork = nil
        wakeWork?.cancel(); wakeWork = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        pendingRestores.removeAll()
        bindings.removeAll()
        lastVerifiedFrames.removeAll()
        sessionFrames.removeAll()
        bridge.invalidateAll()
        store.save()
        phase = .idle
    }

    func flush() {
        store.save()
    }

    // MARK: Hooks called by DisplayController

    /// A display reconfiguration has begun. Idempotent — macOS fires several of
    /// these per change, and our own built-in disable fires more.
    func beginTransition() {
        guard isEnabled else { return }

        // The very first begin-flag of a transition is our last chance to record
        // where windows were before macOS moves them. Only worth keeping if the
        // arrangement had been stable; during a plug-in the intermediate
        // two-display state exists for ~300 ms and its windows are already
        // shuffled.
        //
        // Two more conditions. Geometry must be trustworthy (not a DarkWake). And
        // the live arrangement must still be the one we think we are in: this
        // is also reached on wake from sleep, and if a display was unplugged while
        // the Mac slept, windows have already moved — capturing them into the old
        // arrangement's bucket would poison it.
        if phase != .transitioning,
           let key = currentConfigKey,
           shouldCommitPreTransitionSnapshot(configKeyStableSince: configKeyStableSince, now: Date()),
           geometryIsTrustworthy,
           snapshotter.currentConfigurationKey() == key {
            capture(into: key)
        }

        phase = .transitioning
        // Frames observed before this transition say nothing about where windows
        // will land after it; keeping them would let the first sweep afterwards
        // look settled when macOS is still rearranging.
        lastObservedFrames.removeAll()
        settleWork?.cancel()
        settleWork = nil
        captureTimer?.invalidate()
        captureTimer = nil
    }

    /// DisplayController's own policy has finished acting for this change.
    /// `didMutate` is true when it actually enabled or disabled the built-in
    /// panel, which triggers a further round of reconfiguration callbacks.
    func policySettled(didMutate: Bool) {
        guard isEnabled, phase == .transitioning || phase == .settling else { return }
        phase = .settling
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.settleElapsed()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay(didMutatePolicy: didMutate),
                                      execute: work)
    }

    /// Manual trigger from the settings window.
    func restoreNow() {
        guard isEnabled else { return }
        guard let key = snapshotter.currentConfigurationKey() else { return }
        runRestorePass(for: key, reason: "manual")
    }

    // MARK: Settle and restore

    private func settleElapsed() {
        settleWork = nil
        let previousKey = currentConfigKey

        // Gate 1: no active displays means we are still mid-transition.
        guard !snapshotter.activeDisplayBounds().isEmpty,
              let key = snapshotter.currentConfigurationKey() else {
            log("Window layouts: no active display yet — waiting.")
            returnToIdle()
            return
        }

        // Gate 2: if DisplayController still wants to change the built-in state,
        // another reconfiguration is coming and this geometry is doomed.
        if let policyIsStable, !policyIsStable() {
            log("Window layouts: display policy still settling — waiting.")
            returnToIdle()
            return
        }

        // Gate 2b: a display unplugged while the Mac is asleep is processed during a
        // DarkWake with the screens off, when geometry cannot be trusted, so defer.
        // The arrangement key is deliberately NOT advanced, so the change is still
        // detected when the screens wake.
        guard geometryIsTrustworthy else {
            log("Window layouts: displays are off — deferring restore until they wake.")
            restoreDeferredForWake = true
            returnToIdle()
            return
        }

        currentConfigKey = key
        configKeyStableSince = Date()

        // Gate 3: same arrangement as before means nothing structural changed.
        guard key != previousKey else {
            returnToIdle()
            return
        }

        guard store.hasBucket(for: key) else {
            log("Window layouts: new display arrangement — recorded as baseline (no restore).")
            capture(into: key)
            store.scheduleSave()
            returnToIdle()
            return
        }

        runRestorePass(for: key, reason: "display change")
    }

    private func runRestorePass(for key: String, reason: String) {
        guard geometryIsTrustworthy else {
            log("Window layouts: displays are off — not restoring (\(reason)).")
            restoreDeferredForWake = true
            returnToIdle()
            return
        }
        guard axTrusted else {
            log("Window layouts: Accessibility not granted — cannot restore windows.")
            returnToIdle()
            return
        }
        refreshStageManager()
        guard !stageManagerActive else {
            log("Window layouts: Stage Manager is on — skipping restore.")
            returnToIdle()
            return
        }

        phase = .restoring
        let displays = snapshotter.activeDisplayBounds()
        let records = store.records(for: key)
        // The wide sweep also surfaces minimized windows and windows on other
        // Spaces; both accept an AX frame change directly.
        let snapshots = sweepTrackable(includeOffscreen: true)

        describe(snapshots, force: true) { [weak self] descriptions in
            guard let self else { return }
            let identities = self.identities(for: snapshots, descriptions: descriptions)

            var plan: [AXWindowBridge.PlanEntry] = []
            var targets: [CGWindowID: (identity: WindowIdentity, target: CGRect, name: String)] = [:]
            var skipCounts: [String: Int] = [:]
            let verbose = self.verboseLogging

            self.log("Window layouts: restoring (\(reason)) — \(records.count) remembered, "
                     + "\(snapshots.count) window(s) present, \(descriptions.count) described.")

            for snapshot in snapshots {
                let name = self.appName(for: snapshot.pid)
                guard let identity = identities[snapshot.windowID] else {
                    skipCounts["no identity", default: 0] += 1
                    continue
                }
                guard let description = descriptions[snapshot.windowID] else {
                    skipCounts["no AX description", default: 0] += 1
                    continue
                }
                // Prefer this session's own record for this exact window. Window
                // IDs survive title changes, so this is what makes browsers, mail
                // clients and anything else with a churning title restorable —
                // their title-based identity is different on every restore.
                // Title matching remains the fallback across relaunches.
                let target: CGRect
                let tier: String
                let resistant = store.existingRecord(config: key, identity: identity)?.resistant ?? false
                if let sessionFrame = self.sessionFrames[key]?[snapshot.windowID] {
                    target = sessionFrame
                    tier = "window"
                } else if let match = matchRecord(identity: identity, in: records) {
                    target = match.record.frame
                    tier = match.tier.rawValue
                } else {
                    skipCounts["nothing remembered", default: 0] += 1
                    continue
                }

                // Accessibility's frame is the real one; the sweep's may be a
                // Mission Control or Show Desktop transform.
                let current = description.frame ?? snapshot.frame
                let decision = restoreDecision(current: current,
                                               target: target,
                                               attributes: description.attributes,
                                               activeDisplays: displays,
                                               resistant: resistant)
                switch decision {
                case .restore(let wanted):
                    plan.append(.init(windowID: snapshot.windowID, pid: snapshot.pid, target: wanted))
                    targets[snapshot.windowID] = (identity, wanted, name)
                    self.log("Window layouts: plan \(name) [win \(snapshot.windowID)] "
                             + "\(Self.fmt(current)) → \(Self.fmt(wanted)) "
                             + "(match: \(tier)\(resistant ? ", resistant" : ""))")
                default:
                    let label = String(describing: decision)
                    skipCounts[label, default: 0] += 1
                    if verbose {
                        self.log("Window layouts: skip \(name) [win \(snapshot.windowID)] \(label)")
                    }
                }
            }

            if !skipCounts.isEmpty {
                let detail = skipCounts.sorted { $0.key < $1.key }
                    .map { "\($0.value)× \($0.key)" }.joined(separator: ", ")
                self.log("Window layouts: not moving — \(detail).")
            }

            guard !plan.isEmpty else {
                self.log("Window layouts: nothing to restore (\(reason)).")
                self.returnToIdle()
                return
            }
            guard plan.count <= Self.maxPlanSize else {
                self.log("Window layouts: refusing to move \(plan.count) windows at once — aborting restore.")
                self.returnToIdle()
                return
            }

            // Back-to-front, so the frontmost window settles last.
            self.bridge.apply(plan.reversed(), budget: Self.applyBudget) { achieved in
                MainActor.assumeIsolated {
                    self.finishRestore(key: key, targets: targets, achieved: achieved, reason: reason)
                }
            }
        }
    }

    private func finishRestore(key: String,
                               targets: [CGWindowID: (identity: WindowIdentity, target: CGRect, name: String)],
                               achieved: [CGWindowID: CGRect],
                               reason: String) {
        var moved = 0
        var resisted = 0

        for (windowID, wanted) in targets {
            guard let actual = achieved[windowID] else {
                // The window never took the change — try again when it resurfaces.
                log("Window layouts: \(wanted.name) [win \(windowID)] did not accept the move — queued.")
                addPending(wanted.identity, frame: wanted.target)
                continue
            }
            if framesDiffer(actual, wanted.target) {
                // The app refused. Remember what we actually got so we stop
                // fighting it on every future reconfiguration.
                log("Window layouts: \(wanted.name) [win \(windowID)] asked \(Self.fmt(wanted.target)) "
                    + "got \(Self.fmt(actual)) — marking resistant.")
                store.markResistant(config: key, identity: wanted.identity, achievedFrame: actual)
                // Remember what the app settled on for this window too, so the
                // next restore does not immediately re-fight it.
                sessionFrames[key, default: [:]][windowID] = actual
                lastVerifiedFrames[windowID] = actual
                resisted += 1
            } else {
                if verboseLogging {
                    log("Window layouts: \(wanted.name) [win \(windowID)] → \(Self.fmt(actual)) ✓")
                }
                sessionFrames[key, default: [:]][windowID] = actual
                lastVerifiedFrames[windowID] = actual
                moved += 1
            }
        }

        let summary = "Restored \(moved) window(s)"
            + (resisted > 0 ? ", \(resisted) adjusted by their app" : "")
            + (pendingRestores.isEmpty ? "" : ", \(pendingRestores.count) waiting")
        lastRestoreSummary = summary
        log("Window layouts: \(summary) (\(reason)).")
        store.scheduleSave()
        returnToIdle()
    }

    private func returnToIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreGrace) { [weak self] in
            guard let self else { return }
            self.phase = .idle
            self.restartCaptureTimer()
        }
    }

    // MARK: Capture

    private func restartCaptureTimer() {
        captureTimer?.invalidate()
        guard isEnabled else { return }
        let interval = pendingRestores.isEmpty
            ? Self.idleCaptureInterval
            : Self.pendingCaptureInterval
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.captureTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
    }

    private func captureTick() {
        guard isEnabled, phase == .idle else { return }
        guard geometryIsTrustworthy else {
            // Also forget prior observations, so a pre-sleep sample can never be
            // paired with a post-wake one to look "settled".
            lastObservedFrames.removeAll()
            if !loggedGeometryPause {
                log("Window layouts: displays are off — pausing capture.")
                loggedGeometryPause = true
            }
            return
        }
        if loggedGeometryPause {
            log("Window layouts: displays awake — resuming capture.")
            loggedGeometryPause = false
        }
        guard let key = snapshotter.currentConfigurationKey() else { return }

        if key != currentConfigKey {
            // The arrangement changed without us seeing the transition — most
            // often a display unplugged or replugged while the Mac slept. Silently
            // adopting the new key here would make the deferred restore conclude
            // nothing changed. Run it through the normal settle path instead.
            log("Window layouts: display arrangement changed unobserved — re-evaluating.")
            beginTransition()
            policySettled(didMutate: false)
            return
        }

        capture(into: key)
        store.scheduleSave()
        drainPendingIfNeeded(key: key)
    }

    /// Record every trackable on-screen window's frame into one arrangement.
    private func capture(into key: String) {
        let snapshots = sweepTrackable(includeOffscreen: false)
        guard !snapshots.isEmpty else { return }

        captureCount += 1
        let refreshAll = captureCount % Self.descriptionRefreshEvery == 0
        let unknown = snapshots.filter { refreshAll || bindings[$0.windowID] == nil }
        if !unknown.isEmpty {
            // Results fold in on a later tick; a brand new window is simply
            // recorded a couple of seconds after it appears.
            describe(unknown) { _ in }
        }
        if refreshAll { pruneClosedWindows() }

        let identities = identities(for: snapshots, descriptions: [:])
        let verbose = verboseLogging

        // The sweep is cheap but it is not always telling the truth: while
        // Mission Control, Show Desktop or a Space switch is on screen, it
        // reports the compositing transform rather than the window's real frame.
        // Accessibility reports the real frame throughout, so any frame that does
        // not match one Accessibility has already confirmed gets re-checked
        // before it is allowed anywhere near the store.
        var trusted: [CGWindowID: CGRect] = [:]
        var needsVerification: [CGWindowID: pid_t] = [:]
        for snapshot in snapshots {
            if let verified = lastVerifiedFrames[snapshot.windowID],
               !framesDiffer(verified, snapshot.frame) {
                trusted[snapshot.windowID] = snapshot.frame
            } else {
                needsVerification[snapshot.windowID] = snapshot.pid
            }
        }

        commit(trusted, into: key, snapshots: snapshots, identities: identities, verbose: verbose)

        guard !needsVerification.isEmpty, axTrusted else { return }
        bridge.frames(needsVerification) { [weak self] axFrames in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                for (windowID, frame) in axFrames { self.lastVerifiedFrames[windowID] = frame }
                if verbose {
                    for snapshot in snapshots {
                        guard let real = axFrames[snapshot.windowID],
                              framesDiffer(real, snapshot.frame) else { continue }
                        self.log("Window layouts: sweep reported "
                                 + "\(self.appName(for: snapshot.pid)) [win \(snapshot.windowID)] at "
                                 + "\(Self.fmt(snapshot.frame)) but it is really at \(Self.fmt(real)) "
                                 + "— using the real frame.")
                    }
                }
                self.commit(axFrames, into: key, snapshots: snapshots,
                            identities: identities, verbose: verbose)
            }
        }
    }

    /// Record frames that are known to be real, subject to the settling rule.
    private func commit(_ frames: [CGWindowID: CGRect],
                        into key: String,
                        snapshots: [WindowSnapshot],
                        identities: [CGWindowID: WindowIdentity],
                        verbose: Bool) {
        guard !frames.isEmpty else { return }

        for snapshot in snapshots {
            guard let frame = frames[snapshot.windowID] else { continue }
            let previous = lastObservedFrames[snapshot.windowID]
            lastObservedFrames[snapshot.windowID] = frame
            guard let identity = identities[snapshot.windowID] else { continue }

            // A frame is only worth remembering once the window has held it
            // across two sweeps, so a window still being dragged or resized is
            // not recorded mid-flight.
            guard frameIsSettled(previous: previous, current: frame) else {
                if verbose, previous != nil {
                    log("Window layouts: still moving, not recording "
                        + "\(appName(for: snapshot.pid)) [win \(snapshot.windowID)] "
                        + "\(Self.fmt(frame))")
                }
                continue
            }

            if let recorded = store.existingRecord(config: key, identity: identity)?.frame,
               framesDiffer(recorded, frame) {
                let name = appName(for: snapshot.pid)
                if isSuspiciousFrameChange(from: recorded, to: frame) {
                    log("Window layouts: SUSPECT capture — \(name) [win \(snapshot.windowID)] "
                        + "\(Self.fmt(recorded)) → \(Self.fmt(frame)); shrank sharply.")
                } else if verbose {
                    log("Window layouts: capture \(name) [win \(snapshot.windowID)] "
                        + "\(Self.fmt(recorded)) → \(Self.fmt(frame))")
                }
            }

            // Window IDs are stable for a window's whole life regardless of what
            // its title does, so this is the exact match a later restore prefers.
            sessionFrames[key, default: [:]][snapshot.windowID] = frame

            let center = CGPoint(x: frame.midX, y: frame.midY)
            store.record(config: key,
                         identity: identity,
                         frame: frame,
                         displayUUID: snapshotter.displayUUID(containing: center) ?? "")
        }
    }

    /// Windows worth tracking: owned by a regular (Dock-visible) app that we
    /// are not deliberately ignoring.
    ///
    /// The activation-policy filter matters more than it looks. A wide sweep on
    /// a normal desktop turns up dozens of windows belonging to XPC services and
    /// menu-bar agents — AutoFill, the open/save panel service, Siri, Raycast —
    /// none of which appear in any app's Accessibility window list. They would
    /// never be moved, but every restore pass would waste an AX round trip
    /// rediscovering that.
    /// Drop identity bindings for windows that no longer exist.
    ///
    /// Bindings were previously only cleared when an entire app quit, so a
    /// long-running session accumulated an entry for every window ever opened.
    /// The real hazard is not the memory: `identities(for:descriptions:)` falls
    /// back to the cached binding when a window has no fresh AX description, so
    /// if the WindowServer ever reuses a CGWindowID, a brand new window would
    /// silently inherit a closed window's identity — and the system is full of
    /// off-screen AppKit surfaces (one 500×500 and several title-bar-sized ones
    /// per process) that would then be recorded as if they were the real window.
    /// That is the shape of a window being restored far too small.
    ///
    /// Must sweep with off-screen windows included: minimized windows are absent
    /// from the on-screen list and their bindings have to survive.
    private func pruneClosedWindows() {
        let live = Set(snapshotter.sweep(includeOffscreen: true).map(\.windowID))
        let before = bindings.count
        bindings = bindings.filter { live.contains($0.key) }
        lastObservedFrames = lastObservedFrames.filter { live.contains($0.key) }
        lastVerifiedFrames = lastVerifiedFrames.filter { live.contains($0.key) }
        for (config, frames) in sessionFrames {
            sessionFrames[config] = frames.filter { live.contains($0.key) }
        }
        if verboseLogging, before != bindings.count {
            log("Window layouts: pruned \(before - bindings.count) binding(s) for closed windows.")
        }
    }

    private func sweepTrackable(includeOffscreen: Bool) -> [WindowSnapshot] {
        snapshotter.sweep(includeOffscreen: includeOffscreen).filter { snapshot in
            guard let info = appInfo(for: snapshot.pid), info.isRegular else { return false }
            return AXWindowBridge.shouldTrack(bundleID: info.bundleID)
        }
    }

    /// Resolve a stable identity for each window, preferring freshly read
    /// descriptions and falling back to the session's cached bindings.
    private func identities(for snapshots: [WindowSnapshot],
                            descriptions: [CGWindowID: AXWindowBridge.WindowDescription])
        -> [CGWindowID: WindowIdentity] {

        var rows: [(windowID: CGWindowID, bundleID: String, titleHash: String)] = []
        for snapshot in snapshots {
            guard let bundle = bundleID(for: snapshot.pid) else { continue }
            let hash: String
            if let description = descriptions[snapshot.windowID] {
                hash = hashedTitle(bundleID: bundle,
                                   normalizedTitle: normalizedWindowTitle(description.title))
                bindings[snapshot.windowID] = Binding(pid: snapshot.pid, bundleID: bundle, titleHash: hash)
            } else if let binding = bindings[snapshot.windowID] {
                hash = binding.titleHash
            } else {
                // Not described yet — it will be picked up on a later tick.
                continue
            }
            rows.append((snapshot.windowID, bundle, hash))
        }
        return assignOrdinals(rows)
    }

    private func describe(_ snapshots: [WindowSnapshot],
                          force: Bool = false,
                          completion: @escaping ([CGWindowID: AXWindowBridge.WindowDescription]) -> Void) {
        guard axTrusted, !snapshots.isEmpty else { completion([:]); return }
        // Capture is fire-and-forget and must not pile up, but a restore pass
        // depends on its result and always goes through.
        guard force || !describeInFlight else { completion([:]); return }

        describeInFlight = true
        var requests: [CGWindowID: pid_t] = [:]
        for snapshot in snapshots { requests[snapshot.windowID] = snapshot.pid }

        bridge.describe(requests) { [weak self] descriptions in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.describeInFlight = false
                // Fold titles into the session bindings so later ticks are cheap.
                for (windowID, description) in descriptions {
                    guard let pid = requests[windowID], let bundle = self.bundleID(for: pid) else { continue }
                    let hash = hashedTitle(bundleID: bundle,
                                           normalizedTitle: normalizedWindowTitle(description.title))
                    self.bindings[windowID] = Binding(pid: pid, bundleID: bundle, titleHash: hash)
                }
                completion(descriptions)
            }
        }
    }

    // MARK: Pending restores

    private func addPending(_ identity: WindowIdentity, frame: CGRect) {
        guard pendingRestores.count < Self.maxPending else { return }
        if var existing = pendingRestores[identity] {
            existing.attempts += 1
            pendingRestores[identity] = existing
        } else {
            pendingRestores[identity] = Pending(frame: frame, attempts: 1, createdAt: Date())
        }
        restartCaptureTimer()
    }

    private func drainPendingIfNeeded(key: String) {
        guard !pendingRestores.isEmpty else { return }

        let now = Date()
        pendingRestores = pendingRestores.filter {
            $0.value.attempts < Self.maxPendingAttempts
                && now.timeIntervalSince($0.value.createdAt) < Self.pendingExpiry
        }
        guard !pendingRestores.isEmpty else {
            restartCaptureTimer()
            return
        }
        runRestorePass(for: key, reason: "pending window reappeared")
    }

    // MARK: Workspace and permission

    private func registerWorkspaceObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            })
        }

        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.bridge.warm(pids: [app.processIdentifier])
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.bridge.warm(pids: [app.processIdentifier])
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            self.bridge.invalidate(pid: pid)
            self.appInfoCache.removeValue(forKey: pid)
            self.bindings = self.bindings.filter { $0.value.pid != pid }
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self, let key = self.currentConfigKey else { return }
            self.drainPendingIfNeeded(key: key)
        }
        observe(NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.beginTransition()
        }
        observe(NSWorkspace.didWakeNotification) { [weak self] _ in
            // Geometry gates keep this safe during a DarkWake; the screens-wake
            // handler below does the real re-evaluation.
            self?.beginTransition()
            self?.policySettled(didMutate: true)
        }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] _ in
            guard let self else { return }
            self.screensAsleep = true
            self.screensAwakeSince = nil
            self.lastObservedFrames.removeAll()
            self.wakeWork?.cancel()
            self.log("Window layouts: screens asleep — window geometry untrusted until they wake.")
        }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            guard let self else { return }
            self.screensAsleep = false
            self.screensAwakeSince = Date()
            self.log("Window layouts: screens awake — trusting window geometry again in "
                     + "\(Int(Self.wakeQuietPeriod))s.")
            // Once geometry has settled, re-evaluate the arrangement. If a display
            // was unplugged or replugged while asleep, this is where the deferred
            // restore finally runs — against real geometry.
            self.wakeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isEnabled else { return }
                if self.restoreDeferredForWake {
                    self.log("Window layouts: running restore deferred during sleep.")
                }
                self.restoreDeferredForWake = false
                self.beginTransition()
                self.policySettled(didMutate: false)
            }
            self.wakeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeQuietPeriod + 0.25, execute: work)
        }
    }

    private func warmAllApps() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { AXWindowBridge.shouldTrack(bundleID: $0.bundleIdentifier) }
            .map(\.processIdentifier)
        bridge.warm(pids: pids)
    }

    private func appInfo(for pid: pid_t) -> AppInfo? {
        if let cached = appInfoCache[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier else { return nil }
        let info = AppInfo(bundleID: bundle,
                           name: app.localizedName ?? bundle,
                           isRegular: app.activationPolicy == .regular)
        appInfoCache[pid] = info
        return info
    }

    private func bundleID(for pid: pid_t) -> String? {
        appInfo(for: pid)?.bundleID
    }

    private func refreshStageManager() {
        stageManagerActive = UserDefaults(suiteName: "com.apple.WindowManager")?
            .bool(forKey: "GloballyEnabled") ?? false
    }

    /// Prompt for Accessibility, and open the settings pane too. The prompting
    /// API only shows its alert once per app identity, so on a second press the
    /// button would otherwise appear to do nothing.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startTrustPolling()
    }

    private func refreshTrust() {
        let trusted = AXWindowBridge.isTrusted
        if trusted != axTrusted { axTrusted = trusted }
        if !trusted { startTrustPolling() }
    }

    /// The grant usually takes effect live on modern macOS, so poll rather than
    /// demanding a relaunch.
    private func startTrustPolling() {
        guard trustTimer == nil, !axTrusted else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AXWindowBridge.isTrusted else { return }
                self.axTrusted = true
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                self.log("Window layouts: Accessibility granted — restoring is now active.")
                self.warmAllApps()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    /// See `windowGeometryIsTrustworthy`. Every capture, snapshot and restore
    /// goes through this.
    private var geometryIsTrustworthy: Bool {
        windowGeometryIsTrustworthy(screensAsleep: screensAsleep,
                                    anyActiveDisplayAsleep: snapshotter.anyActiveDisplayAsleep(),
                                    screensAwakeSince: screensAwakeSince,
                                    now: Date(),
                                    quietPeriod: Self.wakeQuietPeriod)
    }

    /// Extra per-window detail. Off by default because capture runs every two
    /// seconds; enable from Help → "Verbose Window Logging" when diagnosing.
    private var verboseLogging: Bool {
        UserDefaults.standard.bool(forKey: "verboseWindowLogging")
    }

    private func appName(for pid: pid_t) -> String {
        appInfo(for: pid)?.name ?? "pid \(pid)"
    }

    private nonisolated static func fmt(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }
}
