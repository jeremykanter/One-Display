//
//  WindowSnapshotter.swift
//  One Display
//
//  The cheap half of the window-layout feature: reading where every window
//  currently is, and describing the current display arrangement.
//
//  A full sweep measures ~0.85 ms on an M-series Mac, needs no permission, and
//  never blocks on another process — which is why capture polls through here
//  and the Accessibility API is reserved for actually moving windows.
//
//  Deliberately does NOT read `kCGWindowName`: that key requires the Screen
//  Recording permission. Titles come from the Accessibility layer instead, so
//  this feature never asks for Screen Recording.
//

import ColorSync
import CoreGraphics
import Foundation

@MainActor
final class WindowSnapshotter {

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    // MARK: Windows

    /// Every window currently known to the WindowServer, filtered to the ones
    /// worth tracking.
    ///
    /// - Parameter includeOffscreen: when true, uses `.optionAll` so minimized
    ///   windows and windows on other Spaces are included. The on-screen-only
    ///   sweep is the steady-state capture path; the wider sweep is used when
    ///   hunting for windows we still owe a restore.
    func sweep(includeOffscreen: Bool = false) -> [WindowSnapshot] {
        let options: CGWindowListOption = includeOffscreen
            ? [.optionAll, .excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]

        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return raw.compactMap { entry -> WindowSnapshot? in
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else { return nil }

            let snapshot = WindowSnapshot(
                windowID: windowID,
                pid: pid,
                frame: frame,
                layer: layer,
                // Alpha is absent on some windows; treat that as fully opaque.
                alpha: (entry[kCGWindowAlpha as String] as? CGFloat) ?? 1,
                isOnscreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            )

            return isEligibleForTracking(snapshot, ownPID: ownPID) ? snapshot : nil
        }
    }

    // MARK: Displays

    /// The active display list — the one that reflects a disabled built-in
    /// panel, which is what makes "built-in off" a distinct arrangement.
    func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    func activeDisplaySignatures() -> [DisplaySignature] {
        activeDisplayIDs().map { id in
            DisplaySignature(uuid: stableUUID(for: id),
                             bounds: CGDisplayBounds(id),
                             isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// True when any active display is asleep. A second, polled signal alongside
    /// the screen sleep/wake notifications, so a missed notification (or launching
    /// while the displays are already off) cannot leave capture trusting geometry.
    func anyActiveDisplayAsleep() -> Bool {
        let ids = activeDisplayIDs()
        return ids.isEmpty || ids.contains { CGDisplayIsAsleep($0) != 0 }
    }

    func activeDisplayBounds() -> [CGRect] {
        activeDisplayIDs().map(CGDisplayBounds)
    }

    /// Key for the current arrangement, or nil mid-reconfiguration when no
    /// display is active yet.
    func currentConfigurationKey() -> String? {
        displayConfigurationKey(activeDisplaySignatures())
    }

    /// UUID of the display a frame's center falls on, used to detect records
    /// left over from a display that is no longer attached.
    func displayUUID(containing point: CGPoint) -> String? {
        for id in activeDisplayIDs() where CGDisplayBounds(id).contains(point) {
            return stableUUID(for: id)
        }
        return nil
    }

    /// A display identifier that survives reboots and reconnection.
    ///
    /// `CGDisplayCreateUUIDFromDisplayID` can return NULL — notably in the
    /// moments right after a display is disabled — so fall back to the
    /// vendor/model/serial triple and finally to the (session-scoped) display
    /// ID rather than collapsing every display onto one key.
    private func stableUUID(for id: CGDirectDisplayID) -> String {
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id) {
            let uuid = uuidRef.takeRetainedValue()
            if let string = CFUUIDCreateString(nil, uuid) as String? {
                return string
            }
        }
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        if vendor != 0 || model != 0 {
            return "\(vendor)-\(model)-\(serial)"
        }
        return "id-\(id)"
    }
}
