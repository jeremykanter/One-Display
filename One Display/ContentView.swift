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

    var body: some View {
        VStack(alignment: .center, spacing: 32) {
            VStack(alignment: .center, spacing: 16) {
                HStack(spacing: 8) {
                    Circle()
                        .frame(width: 8, height: 8)
                        .foregroundStyle(controller.automationEnabled ? .green : .red)
                    Text(controller.automationEnabled ? "Active" :   "Inactive")
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
            }
        }
        .padding(32)
        .onAppear { loginItem.refresh() }
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
