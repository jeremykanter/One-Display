//
//  AXWindowBridge.swift
//  One Display
//
//  The Accessibility half of the window-layout feature: reading window titles
//  and attributes, and actually moving windows. Everything here runs on a
//  private serial queue, because a single unresponsive app can stall an AX call
//  and we must never block the main thread for that.
//
//  Cost, measured on macOS 26.6: a cold sweep is 237-286 ms (roughly 30 ms per
//  app, spent establishing the connection) while a warm sweep over cached
//  per-pid elements is ~10 ms for 14 windows. Hence `warm(pids:)` — it moves
//  that one-time cost off the restore path.
//
//  DEVELOPMENT NOTE — the Accessibility grant is keyed on bundle ID *and* code
//  signature, and for Xcode builds it points at the DerivedData path. When
//  either changes you get a distinctive symptom: One Display appears in
//  System Settings > Privacy & Security > Accessibility with its toggle ON
//  while `AXIsProcessTrusted()` still returns false. The fix is to remove the
//  entry with "−" and re-add it, or:
//      tccutil reset Accessibility com.jeremykanter.One-Display
//  Expect two entries over time (the DerivedData build and /Applications).
//

import ApplicationServices
import CoreGraphics
import Foundation

/// Private SkyLight/HIServices SPI mapping an AX window to its CGWindowID.
///
/// Resolved with `dlsym` rather than declared in CGSDisplay.h on purpose. The
/// app already hard-links `CGSConfigureDisplayEnabled` for its *core* feature,
/// where a missing symbol failing at launch is an acceptable trade. This is an
/// *optional* feature, so a missing symbol must degrade it, not take the whole
/// app down with it.
private typealias GetWindowFn =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

nonisolated final class AXWindowBridge: @unchecked Sendable {

    struct WindowDescription {
        let title: String
        let attributes: WindowAttributes
        /// The window's true frame.
        ///
        /// Accessibility reports real geometry even while Mission Control, Show
        /// Desktop or a Space switch is on screen; `CGWindowList` reports the
        /// compositing transform instead (measured: a window really at
        /// 857,402 853×705 is reported as 1145,485 548×452 in Mission Control and
        /// -903,402 853×705 under Show Desktop). Anything that records or
        /// compares a frame must use this, not the sweep's.
        let frame: CGRect?
    }

    struct PlanEntry {
        let windowID: CGWindowID
        let pid: pid_t
        let target: CGRect
    }

    private static let axGetWindow: GetWindowFn? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2 /* RTLD_DEFAULT */), "_AXUIElementGetWindow")
            .map { unsafeBitCast($0, to: GetWindowFn.self) }

    /// `kAXFullScreenAttribute` is not exposed to Swift; the raw string is.
    private static let fullScreenAttribute = "AXFullScreen"

    /// Apps whose windows we never touch — they own their own placement and
    /// only add noise (and cold-connection cost) to every sweep.
    /// Subroles that are never a window the user arranged. `AXDialog` is
    /// deliberately absent: on macOS 26 several apps report it for their
    /// minimized main windows.
    private static let nonMovableSubroles: Set<String> = [
        "AXSheet", "AXDrawer", "AXSystemDialog",
        "AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown"
    ]

    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.Spotlight"
    ]

    /// How long to wait on an unresponsive app before giving up. The default is
    /// 6 s, which would stall a restore pass badly.
    private static let messagingTimeout: Float = 0.75
    /// Two timeouts and we stop talking to that app for the rest of the session.
    private static let maxStrikes = 2
    private static let tolerance: CGFloat = 2

    private let queue = DispatchQueue(label: "com.jeremykanter.OneDisplay.ax", qos: .userInitiated)

    // All of the following are touched only on `queue`.
    private var appElements: [pid_t: AXUIElement] = [:]
    private var windowElements: [pid_t: [CGWindowID: AXUIElement]] = [:]
    private var strikes: [pid_t: Int] = [:]

    /// Whether the private window-ID SPI resolved. When false we fall back to
    /// geometry matching, which is imperfect for exactly-overlapping windows.
    static var hasWindowIDSPI: Bool { Self.axGetWindow != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Cache lifecycle

    /// Establish AX connections ahead of time so a restore pass runs warm.
    func warm(pids: [pid_t]) {
        queue.async { [self] in
            for pid in pids { _ = appElement(for: pid) }
        }
    }

    func invalidate(pid: pid_t) {
        queue.async { [self] in
            appElements.removeValue(forKey: pid)
            windowElements.removeValue(forKey: pid)
            strikes.removeValue(forKey: pid)
        }
    }

    func invalidateAll() {
        queue.async { [self] in
            appElements.removeAll()
            windowElements.removeAll()
            strikes.removeAll()
        }
    }

    // MARK: Describing windows

    /// Read title and attributes for the given windows. Called only for windows
    /// we have not identified yet, which is what keeps the cold per-app cost off
    /// the hot path.
    func describe(_ requests: [CGWindowID: pid_t],
                  completion: @escaping @Sendable ([CGWindowID: WindowDescription]) -> Void) {
        queue.async { [self] in
            var result: [CGWindowID: WindowDescription] = [:]

            // Group by pid so each app's window list is fetched once.
            var byPID: [pid_t: Set<CGWindowID>] = [:]
            for (windowID, pid) in requests { byPID[pid, default: []].insert(windowID) }

            for (pid, wanted) in byPID {
                guard !isBlacklisted(pid) else { continue }
                let elements = windowElements(for: pid, refreshing: true)
                for windowID in wanted {
                    guard let element = elements[windowID] else { continue }
                    result[windowID] = WindowDescription(title: title(of: element),
                                                         attributes: attributes(of: element),
                                                         frame: frame(of: element))
                }
            }

            DispatchQueue.main.async { completion(result) }
        }
    }

    /// True frames for specific windows, without the cost of reading titles and
    /// attributes. Used by capture to verify frames that appear to have changed.
    func frames(_ requests: [CGWindowID: pid_t],
                completion: @escaping @Sendable ([CGWindowID: CGRect]) -> Void) {
        queue.async { [self] in
            var result: [CGWindowID: CGRect] = [:]
            var byPID: [pid_t: Set<CGWindowID>] = [:]
            for (windowID, pid) in requests { byPID[pid, default: []].insert(windowID) }

            for (pid, wanted) in byPID {
                guard !isBlacklisted(pid) else { continue }
                let elements = windowElements(for: pid, refreshing: false)
                for windowID in wanted {
                    guard let element = elements[windowID], let rect = frame(of: element) else { continue }
                    result[windowID] = rect
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Moving windows

    /// Apply a restore plan and report the frame each window actually ended up
    /// with — which is not always the one we asked for.
    ///
    /// Entries are processed in the order given; the caller passes them
    /// back-to-front so the frontmost window settles last.
    func apply(_ plan: [PlanEntry],
               budget: TimeInterval,
               completion: @escaping @Sendable ([CGWindowID: CGRect]) -> Void) {
        queue.async { [self] in
            let deadline = Date().addingTimeInterval(budget)
            var achieved: [CGWindowID: CGRect] = [:]

            for entry in plan {
                guard Date() < deadline else { break }
                guard !isBlacklisted(entry.pid) else { continue }
                guard let element = windowElement(entry.windowID, pid: entry.pid) else { continue }
                if let frame = setFrame(element, target: entry.target) {
                    achieved[entry.windowID] = frame
                }
            }

            DispatchQueue.main.async { completion(achieved) }
        }
    }

    /// Move and resize one window, then report where it actually landed.
    ///
    /// Position is set, then size, then position again. Apps clamp size to the
    /// screen the window is currently on, so moving first avoids a spurious
    /// clamp; and min/max size constraints can nudge the origin, so position is
    /// re-asserted afterwards.
    private func setFrame(_ element: AXUIElement, target: CGRect) -> CGRect? {
        setPosition(element, target.origin)
        setSize(element, target.size)
        setPosition(element, target.origin)

        guard let firstAttempt = frame(of: element) else { return nil }
        guard framesDiffer(firstAttempt, target, tolerance: Self.tolerance) else { return firstAttempt }

        // One retry in the other order — it helps windows whose size constraint
        // was applied against the screen they were on before the move.
        setSize(element, target.size)
        setPosition(element, target.origin)

        return frame(of: element) ?? firstAttempt
    }

    // MARK: AX primitives

    private func appElement(for pid: pid_t) -> AXUIElement? {
        if let cached = appElements[pid] { return cached }
        guard !isBlacklisted(pid) else { return nil }
        let element = AXUIElementCreateApplication(pid)
        // Propagates to elements derived from this one.
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        appElements[pid] = element
        return element
    }

    private func windowElements(for pid: pid_t, refreshing: Bool) -> [CGWindowID: AXUIElement] {
        if !refreshing, let cached = windowElements[pid] { return cached }
        guard let app = appElement(for: pid) else { return [:] }

        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if error == .cannotComplete {
            recordStrike(pid)
            return windowElements[pid] ?? [:]
        }
        guard error == .success, let windows = value as? [AXUIElement] else { return [:] }

        var mapped: [CGWindowID: AXUIElement] = [:]
        for window in windows {
            if let id = windowID(of: window) { mapped[id] = window }
        }
        windowElements[pid] = mapped
        return mapped
    }

    private func windowElement(_ windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        if let cached = windowElements[pid]?[windowID] { return cached }
        return windowElements(for: pid, refreshing: true)[windowID]
    }

    private func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow = Self.axGetWindow else { return nil }
        var id: CGWindowID = 0
        guard axGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    private func title(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String else { return "" }
        return title
    }

    private func attributes(of element: AXUIElement) -> WindowAttributes {
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        var subroleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)

        // Role alone rejects the Finder desktop, which reports AXScrollArea.
        let isWindow = (roleValue as? String) == (kAXWindowRole as String)
        let subroleIsUsable = (subroleValue as? String).map { !Self.nonMovableSubroles.contains($0) } ?? false

        // Absent on plenty of windows — absent means "not fullscreen".
        var fullScreenValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, Self.fullScreenAttribute as CFString, &fullScreenValue)

        var minimizedValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimizedValue)

        var positionSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        var sizeSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)

        return WindowAttributes(
            isMovableWindow: isWindow && subroleIsUsable,
            isFullScreen: (fullScreenValue as? Bool) ?? false,
            isMinimized: (minimizedValue as? Bool) ?? false,
            positionSettable: positionSettable.boolValue,
            sizeSettable: sizeSettable.boolValue
        )
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    private func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
    }

    private func setSize(_ element: AXUIElement, _ size: CGSize) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
    }

    // MARK: Unresponsive apps

    private func isBlacklisted(_ pid: pid_t) -> Bool {
        (strikes[pid] ?? 0) >= Self.maxStrikes
    }

    private func recordStrike(_ pid: pid_t) {
        strikes[pid, default: 0] += 1
    }

    /// Whether this app should be talked to at all.
    static func shouldTrack(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return !Self.excludedBundleIDs.contains(bundleID)
    }
}
