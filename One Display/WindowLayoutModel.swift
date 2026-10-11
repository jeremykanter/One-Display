//
//  WindowLayoutModel.swift
//  One Display
//
//  Pure types and decision functions for the "remember window positions"
//  feature. Nothing here calls CoreGraphics, the Accessibility API, or touches
//  any global state, so every rule below is unit-testable in isolation —
//  matching the style of `desiredBuiltInState` in DisplayController.swift.
//
//  Coordinate space note: every CGRect in this file lives in the global Quartz
//  display space — origin at the top-left of the main display, y increasing
//  downward. `kCGWindowBounds`, the Accessibility position/size attributes, and
//  `CGDisplayBounds` all agree on that space. `NSScreen` does NOT (it is
//  bottom-left-origin) and must never be mixed in.
//

import CoreGraphics
import CryptoKit
import Foundation

// MARK: - Types

/// Identity of one display for the purpose of keying a window arrangement.
nonisolated struct DisplaySignature: Hashable, Codable {
    let uuid: String
    let bounds: CGRect
    let isBuiltIn: Bool
}

/// Identity of one window, stable enough to match it again after One Display
/// (or the window's own app) has been relaunched.
///
/// `titleHash` is a hash rather than the title itself: matching only ever tests
/// equality, so hashing costs nothing functionally and keeps document names and
/// browser page titles out of the file we write to disk.
nonisolated struct WindowIdentity: Hashable, Codable {
    let bundleID: String
    let titleHash: String
    /// Disambiguates same-title windows of the same app, assigned by ascending
    /// window ID (which is creation order).
    let ordinal: Int
}

/// One row of a `CGWindowListCopyWindowInfo` sweep. Runtime only — never persisted.
nonisolated struct WindowSnapshot {
    let windowID: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let layer: Int
    let alpha: CGFloat
    let isOnscreen: Bool
}

/// Accessibility facts about a window, read by the AX layer and handed to the
/// pure policy below. Keeping this a plain struct is what makes the skip rules —
/// the part most likely to have bugs — testable with literals.
nonisolated struct WindowAttributes {
    /// Whether this is a real, movable window rather than a sheet, drawer,
    /// palette, or the Finder desktop.
    ///
    /// Deliberately not "subrole == AXStandardWindow": on macOS 26 several apps
    /// (Reeder, Messages, Mimestream) report `AXDialog` for their *minimized*
    /// main windows, and an allowlist of one would skip exactly the windows this
    /// feature is meant to fix. The AX layer computes this from the role plus a
    /// denylist of subroles instead.
    let isMovableWindow: Bool
    let isFullScreen: Bool
    let isMinimized: Bool
    let positionSettable: Bool
    let sizeSettable: Bool

    init(isMovableWindow: Bool = true,
         isFullScreen: Bool = false,
         isMinimized: Bool = false,
         positionSettable: Bool = true,
         sizeSettable: Bool = true) {
        self.isMovableWindow = isMovableWindow
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
        self.positionSettable = positionSettable
        self.sizeSettable = sizeSettable
    }
}

/// A remembered window frame within one display arrangement.
nonisolated struct WindowRecord: Codable {
    var identity: WindowIdentity
    var frame: CGRect
    /// UUID of the display containing the frame's center when it was captured.
    /// Not needed to restore (the bucket already pins the geometry) but lets us
    /// reject a record whose display is no longer present.
    var displayUUID: String
    var lastSeen: Date
    /// The owning app refused the frame we asked for and we stored what we
    /// actually got. Stops us re-fighting the same window forever.
    var resistant: Bool

    init(identity: WindowIdentity,
         frame: CGRect,
         displayUUID: String,
         lastSeen: Date,
         resistant: Bool = false) {
        self.identity = identity
        self.frame = frame
        self.displayUUID = displayUUID
        self.lastSeen = lastSeen
        self.resistant = resistant
    }
}

/// All remembered windows for one display arrangement.
nonisolated struct ConfigBucket: Codable {
    var lastSeen: Date
    var windows: [WindowRecord]

    init(lastSeen: Date, windows: [WindowRecord] = []) {
        self.lastSeen = lastSeen
        self.windows = windows
    }
}

/// What the policy wants to do with one window during a restore pass.
nonisolated enum RestoreDecision: Equatable {
    case restore(CGRect)
    case skipAlreadyCorrect
    case skipOffAllDisplays
    case skipNotSettable
    case skipFullScreen
    case skipNotMovable
    case skipResistant
}

// MARK: - Display configuration identity

/// Stable key for a display arrangement.
///
/// Built from the *active* display list (not the online list), which is what
/// makes "built-in disabled" its own bucket rather than colliding with
/// "built-in enabled". Each display's bounds are part of the key, so a
/// rearrangement, a resolution change, or a mirroring change all produce a
/// distinct arrangement rather than silently reusing stale frames.
///
/// Returns nil when there are no active displays — that only happens mid
/// reconfiguration, and every caller must abort rather than guess.
nonisolated func displayConfigurationKey(_ displays: [DisplaySignature]) -> String? {
    guard !displays.isEmpty else { return nil }
    let parts = displays.map { display -> String in
        let b = display.bounds
        return "\(display.uuid)@\(Int(b.origin.x.rounded())),\(Int(b.origin.y.rounded()))"
            + ",\(Int(b.width.rounded())),\(Int(b.height.rounded()))"
    }
    return parts.sorted().joined(separator: "/")
}

// MARK: - Window identity

/// Strip the decoration macOS and apps add to window titles so a document's
/// title stays stable as it is edited. Runs *before* hashing, so the hash of an
/// edited document still matches the hash of its saved self.
nonisolated func normalizedWindowTitle(_ raw: String) -> String {
    var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Leading edit markers used by various apps.
    while let first = title.first, first == "\u{25CF}" || first == "\u{2022}" || first == "*" {
        title.removeFirst()
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Trailing " — Edited" / " - Edited" that macOS document apps append.
    for suffix in [" \u{2014} Edited", " - Edited", " \u{2014} Bearbeitet"] {
        if title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
    }

    return title
}

/// Hash a window title together with its bundle ID. Truncated to 16 bytes,
/// which is far more than enough to avoid collisions across ~1000 records and
/// keeps the persisted file compact.
nonisolated func hashedTitle(bundleID: String, normalizedTitle: String) -> String {
    let input = Data("\(bundleID)\u{0}\(normalizedTitle)".utf8)
    let digest = SHA256.hash(data: input)
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
}

/// Assign ordinals within each (bundleID, titleHash) group by ascending window
/// ID. Window IDs increase monotonically, so this is creation order and stays
/// stable for as long as the windows live.
nonisolated func assignOrdinals(
    _ windows: [(windowID: CGWindowID, bundleID: String, titleHash: String)]
) -> [CGWindowID: WindowIdentity] {
    var groups: [String: [(windowID: CGWindowID, bundleID: String, titleHash: String)]] = [:]
    for window in windows {
        groups["\(window.bundleID)\u{0}\(window.titleHash)", default: []].append(window)
    }

    var result: [CGWindowID: WindowIdentity] = [:]
    for (_, group) in groups {
        for (ordinal, window) in group.sorted(by: { $0.windowID < $1.windowID }).enumerated() {
            result[window.windowID] = WindowIdentity(bundleID: window.bundleID,
                                                     titleHash: window.titleHash,
                                                     ordinal: ordinal)
        }
    }
    return result
}

/// How confidently a window was matched to a remembered frame. Surfaced in the
/// activity log, because a bad restore is almost always a bad match.
nonisolated enum MatchTier: String {
    /// Same app, same title, same position within the title group.
    case exact
    /// Same app and title, different ordinal — a sibling window opened or closed.
    case title
}

/// Find the best remembered record for a window. Matching requires the title to
/// agree; only the ordinal is allowed to drift.
///
/// There is deliberately no "same app, same ordinal, any title" fallback.
/// Ordinals are assigned *within* a (bundleID, title) group, so on a real
/// desktop almost every window is ordinal 0 — measured across 11 windows and 7
/// apps, every single one was. Such a tier therefore means "any window of this
/// app", and it will happily hand a large window a small palette's geometry.
/// That misfires as a window restored far too small, sometimes half off-screen.
///
/// A renamed window now simply finds nothing and is left alone, which is the
/// right failure mode: capture re-records it under its new title within a
/// couple of seconds anyway.
nonisolated func matchRecord(identity: WindowIdentity,
                             in records: [WindowRecord]) -> (record: WindowRecord, tier: MatchTier)? {
    if let exact = records.first(where: { $0.identity == identity }) {
        return (exact, .exact)
    }
    if let byTitle = records.first(where: {
        $0.identity.bundleID == identity.bundleID && $0.identity.titleHash == identity.titleHash
    }) {
        return (byTitle, .title)
    }
    return nil
}

/// Whether a window has held still long enough for its frame to be worth
/// remembering.
///
/// Capture samples on a timer, so without this it can land inside a minimize or
/// close animation, or inside the window shuffle macOS performs right after a
/// display change, and record a transient frame as though it were the real one.
/// Requiring two consecutive agreeing observations costs one capture interval
/// and removes that whole class of bad data. A window seen for the first time
/// (`previous == nil`) is never committed on that first sighting.
nonisolated func frameIsSettled(previous: CGRect?,
                                current: CGRect,
                                tolerance: CGFloat = 2) -> Bool {
    guard let previous else { return false }
    return !framesDiffer(previous, current, tolerance: tolerance)
}

// MARK: - Frame safety

/// The part of a window the user can grab to drag it: the top 40 pt, inset from
/// each side so a sliver of shadow doesn't count.
nonisolated func windowGrabStrip(_ frame: CGRect) -> CGRect {
    let inset = min(60, frame.width / 4)
    return CGRect(x: frame.minX + inset,
                  y: frame.minY,
                  width: max(1, frame.width - inset * 2),
                  height: min(40, max(1, frame.height)))
}

/// Whether a frame leaves the window reachable.
///
/// This deliberately *rejects* rather than clamps. Silently relocating a window
/// to somewhere the user never chose is worse than leaving it where macOS put
/// it. The invariant we enforce is that enough of the title bar lands on a real
/// display that the window can always be dragged.
nonisolated func isFrameSafelyVisible(_ frame: CGRect, activeDisplays: [CGRect]) -> Bool {
    guard !activeDisplays.isEmpty, frame.width > 0, frame.height > 0 else { return false }

    let strip = windowGrabStrip(frame)
    let requiredWidth = min(60, strip.width)
    let requiredHeight = min(20, strip.height)

    for display in activeDisplays {
        let overlap = strip.intersection(display)
        guard !overlap.isNull else { continue }
        if overlap.width >= requiredWidth && overlap.height >= requiredHeight { return true }
    }
    return false
}

/// Shrink an oversized frame to fit a display, nudging the origin back inside
/// if that is what it takes. Used only as a repair step before re-testing
/// `isFrameSafelyVisible`.
nonisolated func fitSizeToDisplay(_ frame: CGRect, display: CGRect) -> CGRect {
    let width = min(frame.width, display.width)
    let height = min(frame.height, display.height)
    var x = frame.minX
    var y = frame.minY
    if x + width > display.maxX { x = display.maxX - width }
    if y + height > display.maxY { y = display.maxY - height }
    x = max(x, display.minX)
    y = max(y, display.minY)
    return CGRect(x: x, y: y, width: width, height: height)
}

/// True when two frames differ by more than `tolerance` in any component.
nonisolated func framesDiffer(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) > tolerance
        || abs(a.minY - b.minY) > tolerance
        || abs(a.width - b.width) > tolerance
        || abs(a.height - b.height) > tolerance
}

// MARK: - Restore policy

/// Decide what to do with a single window during a restore pass.
///
/// Checks are ordered cheapest-decisive first, and the ordering is part of the
/// contract: a sheet or a fullscreen window is skipped for *that* reason even
/// when its remembered frame is also off-screen, so the activity log names the
/// real cause.
nonisolated func restoreDecision(current: CGRect,
                     target: CGRect,
                     attributes: WindowAttributes,
                     activeDisplays: [CGRect],
                     resistant: Bool,
                     tolerance: CGFloat = 2) -> RestoreDecision {
    guard attributes.isMovableWindow else { return .skipNotMovable }
    guard !attributes.isFullScreen else { return .skipFullScreen }
    guard attributes.positionSettable else { return .skipNotSettable }
    guard isFrameSafelyVisible(target, activeDisplays: activeDisplays) else {
        return .skipOffAllDisplays
    }
    guard framesDiffer(current, target, tolerance: tolerance) else { return .skipAlreadyCorrect }
    // A window whose app fought us last time and is already roughly right is
    // left alone; only a real arrangement change is worth another attempt.
    if resistant, !framesDiffer(current, target, tolerance: tolerance * 8) {
        return .skipResistant
    }
    return .restore(target)
}

// MARK: - Display power

/// Whether window geometry reported by the WindowServer can be trusted right now.
///
/// Defensive: this is not the confirmed cause of any observed bad restore. While
/// the displays are off — display sleep, or the brief DarkWakes a sleeping Mac
/// performs with its lid closed — apps keep running and CGWindowList keeps
/// answering, but nothing about the geometry it reports can be seen or checked,
/// and a frame captured then is replayed by a later restore as if it were real.
/// Restoring then is equally blind, and its read-backs feed the "resistant"
/// bookkeeping. Nothing is lost by waiting: the last capture before the
/// displays slept still stands, and restores are deferred until they wake.
///
/// Even after the displays wake, geometry keeps settling for a moment, so a
/// short quiet period is required before trusting it again.
nonisolated func windowGeometryIsTrustworthy(screensAsleep: Bool,
                                             anyActiveDisplayAsleep: Bool,
                                             screensAwakeSince: Date?,
                                             now: Date,
                                             quietPeriod: TimeInterval = 3.0) -> Bool {
    guard !screensAsleep, !anyActiveDisplayAsleep else { return false }
    guard let since = screensAwakeSince else { return false }
    return now.timeIntervalSince(since) >= quietPeriod
}

// MARK: - Timing

/// How long the display configuration must stay quiet before we trust it.
///
/// Both values are chosen to dominate the timers already in DisplayController,
/// and the relationships are asserted by unit tests rather than left in a
/// comment: 0.3 s for the `scheduleApply` debounce, and 0.6 s for the delayed
/// verification inside `performEnable`.
nonisolated func settleDelay(didMutatePolicy: Bool) -> TimeInterval {
    didMutatePolicy ? 1.2 : 0.7
}

/// Whether the arrangement has been stable long enough that a snapshot taken
/// now is worth keeping.
///
/// Guards against the transient two-display state that exists for roughly
/// 300 ms while One Display is disabling the built-in panel: capturing then
/// would write already-shuffled frames into that arrangement's own bucket.
nonisolated func shouldCommitPreTransitionSnapshot(configKeyStableSince: Date?,
                                       now: Date,
                                       minStableAge: TimeInterval = 3.0) -> Bool {
    guard let since = configKeyStableSince else { return false }
    return now.timeIntervalSince(since) >= minStableAge
}

// MARK: - Eligibility and eviction

/// Whether a window from a CGWindowList sweep is one we should track.
///
/// Layer 0 is the strongest and cheapest filter available: it eliminates the
/// Dock, the menu bar, notification banners, Control Center, the Stage Manager
/// strip, and the wallpaper before the Accessibility API is ever touched.
nonisolated func isEligibleForTracking(_ snapshot: WindowSnapshot,
                           minSize: CGSize = CGSize(width: 80, height: 60),
                           ownPID: pid_t) -> Bool {
    guard snapshot.layer == 0 else { return false }
    guard snapshot.pid != ownPID else { return false }
    guard snapshot.alpha > 0 else { return false }
    guard snapshot.frame.width >= minSize.width, snapshot.frame.height >= minSize.height else {
        return false
    }
    return true
}

/// Enforce the storage caps: at most `maxRecords` window records overall
/// (oldest `lastSeen` evicted first), then at most `maxConfigs` arrangements
/// (least recently seen evicted first). Buckets emptied by the first pass are
/// dropped.
nonisolated func evict(_ configs: [String: ConfigBucket],
           maxRecords: Int,
           maxConfigs: Int) -> [String: ConfigBucket] {
    var result = configs

    let total = result.values.reduce(0) { $0 + $1.windows.count }
    if total > maxRecords {
        // Rank every record globally by age, then keep only the newest.
        var ranked: [(config: String, index: Int, lastSeen: Date)] = []
        for (key, bucket) in result {
            for (index, record) in bucket.windows.enumerated() {
                ranked.append((key, index, record.lastSeen))
            }
        }
        ranked.sort { $0.lastSeen > $1.lastSeen }

        var keep: [String: Set<Int>] = [:]
        for entry in ranked.prefix(maxRecords) {
            keep[entry.config, default: []].insert(entry.index)
        }
        for (key, bucket) in result {
            let kept = keep[key] ?? []
            result[key]?.windows = bucket.windows.enumerated()
                .filter { kept.contains($0.offset) }
                .map(\.element)
        }
    }

    // Drop arrangements that no longer hold anything.
    for (key, bucket) in result where bucket.windows.isEmpty {
        result.removeValue(forKey: key)
    }

    if result.count > maxConfigs {
        let survivors = result.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(maxConfigs)
        result = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    return result
}
