//
//  KeyboardShortcutNames.swift
//  One Display
//
//  Global keyboard shortcut definitions backed by the KeyboardShortcuts package.
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global shortcut that toggles the built-in display. Defaults to ⌃⌘B,
    /// matching the app's previous hardcoded hotkey.
    static let toggleBuiltInDisplay = Self(
        "toggleBuiltInDisplay",
        default: .init(.b, modifiers: [.command, .control])
    )
}
