//
//  ContentView.swift
//  One Display
//

import SwiftUI

struct ContentView: View {
    @StateObject private var controller = DisplayController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            displayList
            Divider()
            controls
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 320)
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
                     ? "Built-in display is OFF"
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
            Toggle("Sleep when the lid is closed",
                   isOn: $controller.sleepOnLidClose)
        }
    }

}

#Preview {
    ContentView()
}
