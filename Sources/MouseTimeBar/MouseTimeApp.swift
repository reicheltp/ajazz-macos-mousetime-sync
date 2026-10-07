// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import MouseTimeKit
import SwiftUI

/// Menu bar front end: battery, report rate and dock clock at a glance, and the
/// settings the CLI daemon took as flags.
///
/// Replaces the launchd daemon rather than running beside it — see
/// ``LegacyDaemon`` and ``Engine`` for why there must be one owner of the
/// receiver.
@main
struct MouseTimeApp: App {
    @StateObject private var model = MouseModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        if let battery = model.battery, model.dockPresent {
            Image(systemName: battery <= 20 ? "computermouse.fill" : "computermouse")
            Text("\(battery)%")
        } else {
            Image(systemName: "computermouse")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        Text("AJAZZ AJ159 APEX")

        if model.legacyDaemonRunning {
            Divider()
            Text("The mousetime background service is running.")
            Text("MouseTime stays idle so the two do not collide.")
            Button("Stop the Service and Take Over") { model.replaceLegacyDaemon() }
        } else {
            status
            Divider()
            settings
        }

        if let problem = model.problem {
            Divider()
            Text(problem)
        }

        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button("Open Log") { model.openLog() }
        Button("Quit MouseTime") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var status: some View {
        if !model.dockPresent {
            Text("Receiver not connected")
        } else {
            Text(batteryLine)
            Text("Report rate: \(model.rate.map { "\($0) Hz" } ?? "unknown")")
            if let synced = model.clockSyncedAt {
                Text("Dock clock synced at \(synced, style: .time)")
            } else {
                Text("Dock clock not synced yet")
            }
            Button("Refresh Now") { model.refresh() }
                .keyboardShortcut("r")
        }
    }

    private var batteryLine: String {
        switch (model.battery, model.mouseAwake) {
        case (let percent?, true?):
            return "Battery: \(percent)%"
        case (let percent?, _):
            // The receiver only answers for an awake mouse; show the last value.
            return "Battery: \(percent)% (mouse asleep)"
        case (nil, false?):
            return "Battery: mouse asleep — move it to read"
        case (nil, _):
            return "Battery: reading…"
        }
    }

    @ViewBuilder private var settings: some View {
        Picker("Hold Report Rate", selection: $model.holdRate) {
            Text("Don't Manage").tag(Int?.none)
            Divider()
            ForEach(ReportRate.supported, id: \.self) { hz in
                Text("\(hz) Hz").tag(Int?.some(hz))
            }
        }
        Toggle("Warn When Battery Is Low", isOn: $model.batteryWarnings)
        if model.batteryWarnings && model.notificationsBlocked {
            Text("⚠︎ macOS is not allowing MouseTime's notifications")
            Button("Open Notification Settings…") { model.openNotificationSettings() }
        }
        Toggle("Suppress Phantom Input", isOn: $model.suppress)
    }
}
