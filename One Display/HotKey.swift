//
//  HotKey.swift
//  One Display
//
//  Registers a system-wide ⌃⌘B hotkey via Carbon's RegisterEventHotKey. This is
//  global (fires regardless of which app is frontmost) and, unlike NSEvent global
//  monitors, needs no Accessibility / Input-Monitoring permission.
//

import Carbon.HIToolbox
import Foundation

/// C-compatible handler (captures nothing; the manager is passed via `userData`).
private nonisolated func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { manager.handleHotKey() }
    }
    return noErr
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + (scalar.value & 0xFF)
    }
    return result
}

@MainActor
final class HotKeyManager {

    /// Invoked each time the hotkey is pressed.
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Register ⌃⌘B globally.
    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler,
                            1, &spec, ctx, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: fourCharCode("ODsp"), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_B),
                            UInt32(cmdKey | controlKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func handleHotKey() {
        onTrigger?()
    }
}
