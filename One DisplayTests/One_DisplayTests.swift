//
//  One_DisplayTests.swift
//  One DisplayTests
//

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
