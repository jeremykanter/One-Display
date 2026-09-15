//
//  ContentView.swift
//  One Display
//

import SwiftUI
import KeyboardShortcuts

struct ContentView: View {
    @StateObject private var controller = DisplayController.shared
    @StateObject private var loginItem = LoginItemManager()
    @AppStorage("toggleShortcutEnabled") private var shortcutEnabled = true
    @AppStorage("rememberWindowPositions") private var rememberWindowPositions = false
    @ObservedObject private var windowLayout = DisplayController.shared.windowLayout

    var body: some View {
        VStack(alignment: .center, spacing: 32) {
            VStack(alignment: .center, spacing: 16) {
                HStack(spacing: 8) {
                    Circle()
                        .frame(width: 8, height: 8)
                        .foregroundStyle(status.color)
                    Text(status.label)
                        .font(.subheadline.bold())
                }
                .padding(.vertical, 4)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .background(.ultraThinMaterial)
                .clipShape(.capsule)
                VStack(alignment: .center, spacing: 4) {
                    Text("One Display")
                        .font(.title.bold())
                    Text("Automatically disables your built-in display while an external display is connected")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(spacing: 16) {
                Toggle("Start at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                VStack(spacing: 16) {
                    Toggle("Toggle built-in display using keyboard shortcut",
                           isOn: $shortcutEnabled)
                    .onChange(of: shortcutEnabled) {
                        controller.applyShortcutEnabledState()
                    }
                    KeyboardShortcuts.Recorder("", name: .toggleBuiltInDisplay)
                        .disabled(!shortcutEnabled)
                        .opacity(shortcutEnabled ? 1 : 0.5)
                        .pointerStyle(.default)
                }
                windowPositions
            }
        }
        .padding(32)
        .onAppear { loginItem.refresh() }
    }

    /// Opt-in window-position memory. Off by default: it needs Accessibility
    /// access and moves other apps' windows, so it must never enable itself.
    private var windowPositions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Remember window positions for each display arrangement",
                   isOn: $rememberWindowPositions)
            .onChange(of: rememberWindowPositions) {
                controller.applyWindowLayoutEnabledState()
            }

            if rememberWindowPositions {
                if !windowLayout.axTrusted {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("One Display needs Accessibility access to move windows.")
                            Button("Grant Access…") {
                                windowLayout.requestAccessibilityPermission()
                            }
                            .controlSize(.small)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if windowLayout.stageManagerActive {
                    Text("Paused while Stage Manager is on — it places windows itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(windowLayout.lastRestoreSummary
                             ?? "Learns each arrangement the first time you use it.")
                        Spacer(minLength: 8)
                        Button("Restore Now") { windowLayout.restoreNow() }
                            .controlSize(.small)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The status pill's color and label. Blue "Paused" while a temporary
    /// override is held; red "Inactive" when automation is off entirely;
    /// green "Active" during normal automation.
    private var status: (color: Color, label: String) {
        if !controller.automationEnabled {
            return (.red, "Inactive")
        } else if controller.manualOverrideActive {
            return (.blue, "Paused")
        } else {
            return (.green, "Active")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.builtInDisabled
                  ? "laptopcomputer.slash" : "laptopcomputer")
                .font(.title)
                .foregroundStyle(controller.builtInDisabled ? .orange : .secondary)
            VStack(alignment: .leading) {
                Text("One Display").font(.headline)
                Text(controller.builtInDisabled
                     ? "Built-in display is off"
                     : "Built-in display is on")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Displays").font(.headline)
            if controller.displays.isEmpty {
                Text("No displays reported.").foregroundStyle(.secondary)
            }
            ForEach(controller.displays) { display in
                HStack {
                    Image(systemName: display.isBuiltIn
                          ? "laptopcomputer" : "display")
                    Text(display.name)
                    Spacer()
                    Text(display.isActive ? "active" : "off")
                        .font(.caption)
                        .foregroundStyle(display.isActive ? .green : .secondary)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Disable the built-in display when an external display is connected",
                   isOn: $controller.automationEnabled)
            Toggle("Sleep when the lid is closed",
                   isOn: $controller.sleepOnLidClose)
            HStack {
                Button("Disable built-in") { controller.manualDisableBuiltIn() }
                Button("Enable built-in") { controller.manualEnableBuiltIn() }
            }
            .disabled(controller.automationEnabled)
            if controller.automationEnabled {
                Text("Turn automation off to use manual controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

}

#Preview {
    ContentView()
}
