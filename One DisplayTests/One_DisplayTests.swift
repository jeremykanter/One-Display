//
//  One_DisplayTests.swift
//  One DisplayTests
//

import Foundation
import Testing
@testable import One_Display

struct DesiredBuiltInStateTests {

    @Test func externalConnectedWithBuiltInOnDisablesBuiltIn() {
        #expect(desiredBuiltInState(externalCount: 1, builtInActive: true) == .disableBuiltIn)
    }

    @Test func externalConnectedWithBuiltInAlreadyOffDoesNothing() {
        #expect(desiredBuiltInState(externalCount: 1, builtInActive: false) == .noChange)
    }

    @Test func noExternalWithBuiltInOffEnablesBuiltIn() {
        #expect(desiredBuiltInState(externalCount: 0, builtInActive: false) == .enableBuiltIn)
    }

    @Test func noExternalWithBuiltInOnDoesNothing() {
        #expect(desiredBuiltInState(externalCount: 0, builtInActive: true) == .noChange)
    }

    @Test func multipleExternalsStillDisableBuiltIn() {
        #expect(desiredBuiltInState(externalCount: 2, builtInActive: true) == .disableBuiltIn)
    }

    /// Safety: with no displays at all we must never ask to disable the built-in.
    @Test func zeroDisplaysNeverDisablesBuiltIn() {
        let action = desiredBuiltInState(externalCount: 0, builtInActive: false)
        #expect(action != .disableBuiltIn)
    }
}

struct LidCloseSleepActionTests {

    /// System Sleep Timer 0 = "prevent automatic sleeping when display off" is on
    /// → sleep the displays only and keep the system awake.
    @Test func zeroTimerSleepsDisplayOnly() {
        #expect(lidCloseSleepAction(systemSleepTimerMinutes: 0) == .displaySleepOnly)
    }

    @Test func nonZeroTimerFullySleeps() {
        #expect(lidCloseSleepAction(systemSleepTimerMinutes: 1) == .fullSleep)
        #expect(lidCloseSleepAction(systemSleepTimerMinutes: 20) == .fullSleep)
    }

    /// Unreadable setting falls back to the previous full-sleep behavior.
    @Test func unknownTimerFullySleeps() {
        #expect(lidCloseSleepAction(systemSleepTimerMinutes: nil) == .fullSleep)
    }
}

struct WakeRecoveryActionTests {

    /// The incident this exists for: we asked for the built-in back while the
    /// screens were asleep, the WindowServer refused, and nothing retried.
    @Test func pendingEnableWithBuiltInStillOffRetries() {
        #expect(wakeRecoveryAction(pendingEnable: true, builtInActive: false) == .retryEnable)
    }

    /// The enable did take effect before/while we slept — nothing to redo.
    @Test func pendingEnableAlreadySatisfiedJustReevaluates() {
        #expect(wakeRecoveryAction(pendingEnable: true, builtInActive: true) == .reevaluate)
    }

    /// Steady state docked: built-in deliberately off, no enable pending. Must
    /// not turn the panel back on just because we woke up.
    @Test func noPendingEnableNeverRetries() {
        #expect(wakeRecoveryAction(pendingEnable: false, builtInActive: false) == .reevaluate)
        #expect(wakeRecoveryAction(pendingEnable: false, builtInActive: true) == .reevaluate)
    }
}

struct EnableRetryDelayTests {

    @Test func retriesBackOff() {
        #expect(enableRetryDelay(attempt: 0) == 1)
        #expect(enableRetryDelay(attempt: 1) == 3)
        #expect(enableRetryDelay(attempt: 2) == 8)
    }

    /// Bounded: we stop hammering the WindowServer and wait for the next
    /// display change or wake instead.
    @Test func givesUpAfterThreeAttempts() {
        #expect(enableRetryDelay(attempt: 3) == nil)
        #expect(enableRetryDelay(attempt: 99) == nil)
    }

    @Test func delaysAreStrictlyIncreasing() {
        let delays = (0..<3).compactMap { enableRetryDelay(attempt: $0) }
        #expect(delays.count == 3)
        #expect(delays == delays.sorted())
    }
}
