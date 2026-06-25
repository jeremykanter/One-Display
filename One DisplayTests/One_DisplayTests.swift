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
