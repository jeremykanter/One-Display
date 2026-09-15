//
//  WindowLayoutTests.swift
//  One DisplayTests
//
//  Covers the pure decision layer of the "remember window positions" feature.
//  Everything under test lives in WindowLayoutModel.swift and touches no
//  CoreGraphics or Accessibility state.
//

import CoreGraphics
import Foundation
import Testing
@testable import One_Display

// MARK: - Helpers

private func display(_ uuid: String,
                     _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     builtIn: Bool = false) -> DisplaySignature {
    DisplaySignature(uuid: uuid, bounds: CGRect(x: x, y: y, width: w, height: h), isBuiltIn: builtIn)
}

private func identity(_ bundle: String, _ title: String, _ ordinal: Int = 0) -> WindowIdentity {
    WindowIdentity(bundleID: bundle,
                   titleHash: hashedTitle(bundleID: bundle, normalizedTitle: title),
                   ordinal: ordinal)
}

private func record(_ id: WindowIdentity,
                    frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
                    lastSeen: Date = Date(),
                    resistant: Bool = false) -> WindowRecord {
    WindowRecord(identity: id, frame: frame, displayUUID: "D1", lastSeen: lastSeen, resistant: resistant)
}

// MARK: - Display configuration key

struct DisplayConfigurationKeyTests {

    private let builtIn = display("BUILTIN", 0, 0, 1800, 1169, builtIn: true)
    private let external = display("EXTERNAL", 1800, 0, 2560, 1440)

    @Test func enumerationOrderDoesNotMatter() {
        #expect(displayConfigurationKey([builtIn, external])
                == displayConfigurationKey([external, builtIn]))
    }

    /// The whole feature depends on this: One Display disabling the built-in
    /// panel must produce a different arrangement, not reuse the two-display one.
    @Test func disablingBuiltInProducesADifferentKey() {
        #expect(displayConfigurationKey([builtIn, external])
                != displayConfigurationKey([external]))
    }

    @Test func rearrangingTheSameDisplaysProducesADifferentKey() {
        let externalOnTheLeft = display("EXTERNAL", -2560, 0, 2560, 1440)
        #expect(displayConfigurationKey([builtIn, external])
                != displayConfigurationKey([builtIn, externalOnTheLeft]))
    }

    @Test func resolutionChangeProducesADifferentKey() {
        let scaled = display("EXTERNAL", 1800, 0, 1920, 1080)
        #expect(displayConfigurationKey([builtIn, external])
                != displayConfigurationKey([builtIn, scaled]))
    }

    @Test func noActiveDisplaysHasNoKey() {
        #expect(displayConfigurationKey([]) == nil)
    }

    @Test func keyIsStableAcrossCalls() {
        #expect(displayConfigurationKey([builtIn, external])
                == displayConfigurationKey([builtIn, external]))
    }
}

// MARK: - Window identity

struct WindowIdentityTests {

    @Test func normalizationStripsEditMarkers() {
        #expect(normalizedWindowTitle("\u{25CF} Report.pages") == "Report.pages")
        #expect(normalizedWindowTitle("  Report.pages  ") == "Report.pages")
        #expect(normalizedWindowTitle("Report.pages \u{2014} Edited") == "Report.pages")
    }

    /// An unsaved document must still match its saved self, or every edit would
    /// orphan the window's remembered position.
    @Test func hashIsStableAcrossAnEditMarker() {
        let saved = hashedTitle(bundleID: "com.apple.Pages",
                                normalizedTitle: normalizedWindowTitle("Report.pages"))
        let edited = hashedTitle(bundleID: "com.apple.Pages",
                                 normalizedTitle: normalizedWindowTitle("\u{25CF} Report.pages"))
        #expect(saved == edited)
    }

    @Test func hashIsDistinctPerAppAndTitle() {
        #expect(hashedTitle(bundleID: "com.a", normalizedTitle: "Doc")
                != hashedTitle(bundleID: "com.b", normalizedTitle: "Doc"))
        #expect(hashedTitle(bundleID: "com.a", normalizedTitle: "Doc")
                != hashedTitle(bundleID: "com.a", normalizedTitle: "Other"))
    }

    /// The persisted file must never contain a readable title.
    @Test func hashDoesNotContainThePlaintextTitle() {
        let hash = hashedTitle(bundleID: "com.apple.Safari", normalizedTitle: "Private Banking")
        #expect(!hash.lowercased().contains("banking"))
        #expect(hash.count == 32)
    }

    @Test func sameTitleWindowsGetOrdinalsByAscendingWindowID() {
        let titleHash = hashedTitle(bundleID: "com.apple.finder", normalizedTitle: "Documents")
        let assigned = assignOrdinals([
            (windowID: 900, bundleID: "com.apple.finder", titleHash: titleHash),
            (windowID: 100, bundleID: "com.apple.finder", titleHash: titleHash)
        ])
        #expect(assigned[100]?.ordinal == 0)
        #expect(assigned[900]?.ordinal == 1)
    }

    @Test func differentTitlesEachStartAtOrdinalZero() {
        let assigned = assignOrdinals([
            (windowID: 1, bundleID: "com.app", titleHash: "aaa"),
            (windowID: 2, bundleID: "com.app", titleHash: "bbb")
        ])
        #expect(assigned[1]?.ordinal == 0)
        #expect(assigned[2]?.ordinal == 0)
    }
}

struct MatchRecordTests {

    @Test func prefersAnExactMatch() {
        let wanted = identity("com.app", "Doc", 1)
        let records = [record(identity("com.app", "Doc", 0)), record(wanted)]
        let match = matchRecord(identity: wanted, in: records)
        #expect(match?.record.identity == wanted)
        #expect(match?.tier == .exact)
    }

    /// A window was opened or closed, shifting the ordinals — the title still wins.
    @Test func fallsBackToTitleWhenOrdinalMoved() {
        let stored = identity("com.app", "Doc", 0)
        let wanted = identity("com.app", "Doc", 3)
        let match = matchRecord(identity: wanted, in: [record(stored)])
        #expect(match?.record.identity == stored)
        #expect(match?.tier == .title)
    }

    /// A renamed window must NOT inherit another window's geometry.
    ///
    /// Ordinals are assigned within a (bundle, title) group, so in practice
    /// almost every window is ordinal 0 — measured across 11 windows and 7 apps,
    /// all were. A "same app, same ordinal, any title" fallback therefore means
    /// "any window of this app", and it was handing large windows the geometry
    /// of small ones: restored far too small, sometimes half off-screen.
    @Test func aRenamedWindowMatchesNothingRatherThanGuessing() {
        let stored = identity("com.app", "Old Doc", 0)
        let wanted = identity("com.app", "New Doc", 0)
        #expect(matchRecord(identity: wanted, in: [record(stored)]) == nil)
    }

    /// The realistic shape of the bug: two windows of one app, both ordinal 0,
    /// very different sizes. Renaming the big one must not shrink it.
    @Test func aRenamedWindowNeverInheritsASiblingsSize() {
        let palette = record(identity("com.app", "Inspector", 0),
                             frame: CGRect(x: 2300, y: 1200, width: 240, height: 180))
        let renamedMainWindow = identity("com.app", "Untitled 2", 0)
        #expect(matchRecord(identity: renamedMainWindow, in: [palette]) == nil)
    }

    @Test func neverMatchesAcrossApps() {
        let stored = identity("com.other", "Doc", 0)
        let wanted = identity("com.app", "Doc", 0)
        #expect(matchRecord(identity: wanted, in: [record(stored)]) == nil)
    }

    @Test func noRecordsMatchesNothing() {
        #expect(matchRecord(identity: identity("com.app", "Doc"), in: []) == nil)
    }
}

struct SuspiciousFrameChangeTests {

    private let settled = CGRect(x: 100, y: 100, width: 1200, height: 800)

    /// The signature of a capture landing inside a minimize or close animation:
    /// the window has shrunk dramatically on its way to the Dock.
    @Test func aSharpShrinkIsSuspicious() {
        #expect(isSuspiciousFrameChange(from: settled,
                                        to: CGRect(x: 1800, y: 1300, width: 160, height: 100)))
    }

    @Test func anOrdinaryResizeIsNotSuspicious() {
        #expect(!isSuspiciousFrameChange(from: settled,
                                         to: CGRect(x: 100, y: 100, width: 1000, height: 700)))
    }

    @Test func movingWithoutResizingIsNotSuspicious() {
        #expect(!isSuspiciousFrameChange(from: settled, to: settled.offsetBy(dx: 900, dy: 0)))
    }

    @Test func growingIsNotSuspicious() {
        #expect(!isSuspiciousFrameChange(from: settled,
                                         to: CGRect(x: 0, y: 0, width: 2560, height: 1400)))
    }

    @Test func aDegenerateOldFrameIsNotSuspicious() {
        #expect(!isSuspiciousFrameChange(from: .zero, to: settled))
    }
}

struct FrameSettledTests {

    private let frame = CGRect(x: 100, y: 100, width: 1200, height: 800)

    /// A window seen for the very first time has nothing to agree with, so it is
    /// never committed on that sighting.
    @Test func aFirstSightingIsNeverSettled() {
        #expect(!frameIsSettled(previous: nil, current: frame))
    }

    @Test func twoAgreeingObservationsAreSettled() {
        #expect(frameIsSettled(previous: frame, current: frame))
    }

    @Test func subPixelDriftStillCountsAsSettled() {
        #expect(frameIsSettled(previous: frame,
                               current: CGRect(x: 101, y: 101, width: 1201, height: 801)))
    }

    /// Mid-minimize: shrinking toward the Dock between two sweeps.
    @Test func aWindowStillAnimatingIsNotSettled() {
        #expect(!frameIsSettled(previous: frame,
                                current: CGRect(x: 1800, y: 1300, width: 160, height: 100)))
    }

    @Test func aWindowBeingDraggedIsNotSettled() {
        #expect(!frameIsSettled(previous: frame, current: frame.offsetBy(dx: 400, dy: 0)))
    }
}

// MARK: - Frame safety

struct FrameSafetyTests {

    private let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test func frameFullyOnADisplayIsVisible() {
        #expect(isFrameSafelyVisible(CGRect(x: 100, y: 100, width: 800, height: 600),
                                     activeDisplays: [screen]))
    }

    @Test func frameFarAboveEveryDisplayIsNotVisible() {
        #expect(!isFrameSafelyVisible(CGRect(x: 100, y: -3000, width: 800, height: 600),
                                      activeDisplays: [screen]))
    }

    @Test func frameStraddlingTwoDisplaysIsVisible() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        #expect(isFrameSafelyVisible(CGRect(x: 800, y: 100, width: 400, height: 300),
                                     activeDisplays: [left, right]))
    }

    /// Only a corner overlaps, so the title bar is unreachable — the window
    /// would be stranded and undraggable.
    @Test func frameWithOnlyACornerOverlappingIsNotVisible() {
        let small = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(!isFrameSafelyVisible(CGRect(x: 995, y: 995, width: 800, height: 600),
                                      activeDisplays: [small]))
    }

    @Test func nothingIsVisibleWithNoActiveDisplays() {
        #expect(!isFrameSafelyVisible(CGRect(x: 0, y: 0, width: 800, height: 600),
                                      activeDisplays: []))
    }

    @Test func zeroSizedFrameIsNotVisible() {
        #expect(!isFrameSafelyVisible(.zero, activeDisplays: [screen]))
    }

    @Test func oversizedOffscreenFrameBecomesVisibleAfterFitting() {
        let frame = CGRect(x: 3000, y: 100, width: 5000, height: 3000)
        #expect(!isFrameSafelyVisible(frame, activeDisplays: [screen]))

        let fitted = fitSizeToDisplay(frame, display: screen)
        #expect(fitted.width <= screen.width)
        #expect(fitted.height <= screen.height)
        #expect(isFrameSafelyVisible(fitted, activeDisplays: [screen]))
    }

    @Test func fittingLeavesAnAlreadyFittingFrameAlone() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(fitSizeToDisplay(frame, display: screen) == frame)
    }
}

struct FramesDifferTests {

    private let base = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func identicalFramesDoNotDiffer() {
        #expect(!framesDiffer(base, base))
    }

    @Test func subPixelDriftIsWithinTolerance() {
        #expect(!framesDiffer(base, CGRect(x: 101, y: 101, width: 801, height: 601)))
    }

    @Test func aRealMoveDiffers() {
        #expect(framesDiffer(base, CGRect(x: 400, y: 100, width: 800, height: 600)))
    }

    @Test func aResizeDiffers() {
        #expect(framesDiffer(base, CGRect(x: 100, y: 100, width: 1200, height: 600)))
    }
}

// MARK: - Restore policy

struct RestoreDecisionTests {

    private let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let current = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let target = CGRect(x: 900, y: 200, width: 1000, height: 700)

    private func decide(current: CGRect? = nil,
                        target: CGRect? = nil,
                        attributes: WindowAttributes = WindowAttributes(),
                        displays: [CGRect]? = nil,
                        resistant: Bool = false) -> RestoreDecision {
        restoreDecision(current: current ?? self.current,
                        target: target ?? self.target,
                        attributes: attributes,
                        activeDisplays: displays ?? [screen],
                        resistant: resistant)
    }

    @Test func aMovedWindowIsRestored() {
        #expect(decide() == .restore(target))
    }

    @Test func aWindowAlreadyInPlaceIsLeftAlone() {
        #expect(decide(current: target) == .skipAlreadyCorrect)
    }

    @Test func sheetsAndPalettesAreSkipped() {
        #expect(decide(attributes: WindowAttributes(isMovableWindow: false)) == .skipNotMovable)
    }

    @Test func fullscreenWindowsAreSkipped() {
        #expect(decide(attributes: WindowAttributes(isFullScreen: true)) == .skipFullScreen)
    }

    /// Split View tiles and the Finder desktop window report position as
    /// non-settable; both must be left alone.
    @Test func windowsWithUnsettablePositionAreSkipped() {
        #expect(decide(attributes: WindowAttributes(positionSettable: false)) == .skipNotSettable)
    }

    @Test func aTargetOffEveryDisplayIsSkipped() {
        #expect(decide(target: CGRect(x: 100, y: -4000, width: 800, height: 600))
                == .skipOffAllDisplays)
    }

    /// Minimized windows accept position and size directly, so they are ordinary
    /// restore candidates rather than a special case. Several apps report an
    /// AXDialog subrole while minimized, which is why movability is not a
    /// straight AXStandardWindow check.
    @Test func minimizedWindowsAreStillRestored() {
        #expect(decide(attributes: WindowAttributes(isMinimized: true)) == .restore(target))
    }

    @Test func aResistantWindowRoughlyInPlaceIsLeftAlone() {
        let nudged = CGRect(x: target.minX + 6, y: target.minY + 6,
                            width: target.width, height: target.height)
        #expect(decide(current: nudged, resistant: true) == .skipResistant)
    }

    /// A resistant window still gets one more chance when the arrangement
    /// genuinely changed and it is nowhere near its remembered frame.
    @Test func aResistantWindowFarOutOfPlaceIsStillRestored() {
        #expect(decide(resistant: true) == .restore(target))
    }

    /// Ordering is part of the contract: the log should blame the window kind,
    /// not the off-screen target.
    @Test func movabilityCheckWinsOverAnOffscreenTarget() {
        #expect(decide(target: CGRect(x: 100, y: -4000, width: 800, height: 600),
                       attributes: WindowAttributes(isMovableWindow: false))
                == .skipNotMovable)
    }
}

// MARK: - Display power

struct GeometryTrustTests {

    private let now = Date()

    @Test func awakeAndSettledIsTrustworthy() {
        #expect(windowGeometryIsTrustworthy(screensAsleep: false,
                                            anyActiveDisplayAsleep: false,
                                            screensAwakeSince: now.addingTimeInterval(-60),
                                            now: now))
    }

    /// Display sleep and DarkWake both keep the screens off; geometry reported
    /// then cannot be verified, so it must never be captured or restored against.
    @Test func screensAsleepIsNeverTrustworthy() {
        #expect(!windowGeometryIsTrustworthy(screensAsleep: true,
                                             anyActiveDisplayAsleep: false,
                                             screensAwakeSince: now.addingTimeInterval(-60),
                                             now: now))
    }

    /// The polled display probe wins even if a sleep notification was missed.
    @Test func aSleepingActiveDisplayIsNeverTrustworthy() {
        #expect(!windowGeometryIsTrustworthy(screensAsleep: false,
                                             anyActiveDisplayAsleep: true,
                                             screensAwakeSince: now.addingTimeInterval(-60),
                                             now: now))
    }

    /// Geometry keeps settling for a moment after the screens come on.
    @Test func justWokenIsNotYetTrustworthy() {
        #expect(!windowGeometryIsTrustworthy(screensAsleep: false,
                                             anyActiveDisplayAsleep: false,
                                             screensAwakeSince: now.addingTimeInterval(-1),
                                             now: now))
    }

    @Test func unknownWakeTimeIsNotTrustworthy() {
        #expect(!windowGeometryIsTrustworthy(screensAsleep: false,
                                             anyActiveDisplayAsleep: false,
                                             screensAwakeSince: nil,
                                             now: now))
    }
}

// MARK: - Timing

struct SettleTimingTests {

    /// Must outlast the 0.6 s delayed verification inside `performEnable`.
    @Test func mutatingSettleBeatsTheEnableVerification() {
        #expect(settleDelay(didMutatePolicy: true) > 0.6)
    }

    /// Must outlast the 0.3 s `scheduleApply` debounce.
    @Test func nonMutatingSettleBeatsTheApplyDebounce() {
        #expect(settleDelay(didMutatePolicy: false) > 0.3)
    }

    @Test func mutatingWaitsLongerThanNonMutating() {
        #expect(settleDelay(didMutatePolicy: true) > settleDelay(didMutatePolicy: false))
    }
}

struct PreTransitionSnapshotTests {

    private let now = Date()

    @Test func aLongStableArrangementIsWorthCapturing() {
        #expect(shouldCommitPreTransitionSnapshot(configKeyStableSince: now.addingTimeInterval(-10),
                                                  now: now))
    }

    /// The transient two-display state during a plug-in lasts ~300 ms; capturing
    /// it would write already-shuffled frames into its own bucket.
    @Test func aTransientArrangementIsNotCaptured() {
        #expect(!shouldCommitPreTransitionSnapshot(configKeyStableSince: now.addingTimeInterval(-0.3),
                                                   now: now))
    }

    @Test func anUnknownArrangementIsNotCaptured() {
        #expect(!shouldCommitPreTransitionSnapshot(configKeyStableSince: nil, now: now))
    }
}

// MARK: - Eligibility

struct EligibilityTests {

    private func snapshot(layer: Int = 0,
                          pid: pid_t = 500,
                          alpha: CGFloat = 1,
                          size: CGSize = CGSize(width: 800, height: 600)) -> WindowSnapshot {
        WindowSnapshot(windowID: 1,
                       pid: pid,
                       frame: CGRect(origin: .zero, size: size),
                       layer: layer,
                       alpha: alpha,
                       isOnscreen: true)
    }

    @Test func anOrdinaryWindowIsTracked() {
        #expect(isEligibleForTracking(snapshot(), ownPID: 999))
    }

    /// Layer 0 is the filter that removes the Dock, menu bar, Control Center,
    /// notification banners and the wallpaper before AX is ever touched.
    @Test func nonZeroLayersAreExcluded() {
        #expect(!isEligibleForTracking(snapshot(layer: 25), ownPID: 999))
        #expect(!isEligibleForTracking(snapshot(layer: -1), ownPID: 999))
    }

    @Test func ourOwnWindowsAreExcluded() {
        #expect(!isEligibleForTracking(snapshot(pid: 999), ownPID: 999))
    }

    @Test func invisibleWindowsAreExcluded() {
        #expect(!isEligibleForTracking(snapshot(alpha: 0), ownPID: 999))
    }

    @Test func tinyHelperWindowsAreExcluded() {
        #expect(!isEligibleForTracking(snapshot(size: CGSize(width: 40, height: 20)), ownPID: 999))
    }
}

// MARK: - Eviction

struct EvictionTests {

    private func bucket(_ count: Int, startingAt offset: TimeInterval) -> ConfigBucket {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let windows = (0..<count).map { index in
            record(identity("com.app", "Doc \(index)", index),
                   lastSeen: base.addingTimeInterval(offset + Double(index)))
        }
        return ConfigBucket(lastSeen: base.addingTimeInterval(offset + Double(count)),
                            windows: windows)
    }

    @Test func recordsAreCappedAtTheLimit() {
        let configs = ["a": bucket(400, startingAt: 0),
                       "b": bucket(400, startingAt: 1000),
                       "c": bucket(400, startingAt: 2000)]
        let result = evict(configs, maxRecords: 1000, maxConfigs: 32)
        #expect(result.values.reduce(0) { $0 + $1.windows.count } == 1000)
    }

    @Test func theOldestRecordsAreTheOnesDropped() {
        let configs = ["old": bucket(10, startingAt: 0),
                       "new": bucket(10, startingAt: 5000)]
        let result = evict(configs, maxRecords: 10, maxConfigs: 32)
        #expect(result["new"]?.windows.count == 10)
        #expect(result["old"] == nil)
    }

    @Test func emptiedArrangementsAreRemoved() {
        var configs = ["kept": bucket(5, startingAt: 1000)]
        configs["empty"] = ConfigBucket(lastSeen: Date(), windows: [])
        let result = evict(configs, maxRecords: 1000, maxConfigs: 32)
        #expect(result["empty"] == nil)
        #expect(result["kept"] != nil)
    }

    @Test func arrangementsAreCappedByRecency() {
        var configs: [String: ConfigBucket] = [:]
        for index in 0..<40 {
            configs["config-\(index)"] = bucket(1, startingAt: Double(index) * 100)
        }
        let result = evict(configs, maxRecords: 1000, maxConfigs: 32)
        #expect(result.count == 32)
        // The newest arrangement survives; the oldest does not.
        #expect(result["config-39"] != nil)
        #expect(result["config-0"] == nil)
    }

    @Test func nothingIsDroppedBelowTheCaps() {
        let configs = ["a": bucket(5, startingAt: 0), "b": bucket(5, startingAt: 100)]
        let result = evict(configs, maxRecords: 1000, maxConfigs: 32)
        #expect(result.count == 2)
        #expect(result.values.reduce(0) { $0 + $1.windows.count } == 10)
    }
}
