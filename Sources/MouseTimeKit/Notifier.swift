// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation

/// Posts a macOS notification.
///
/// Uses `osascript` rather than `UNUserNotificationCenter`, which needs a bundle
/// identifier — a bare command-line binary has none, and the framework fails
/// rather than falling back. The cost is that the notification is attributed to
/// Script Editor instead of to us; a proper `.app` bundle would fix that, and is
/// the natural moment to switch, since a menu bar app needs one anyway.
public enum Notifier {
    /// Posts a notification. Returns false if `osascript` refused.
    ///
    /// Never throws: a background daemon must not die because a notification
    /// could not be shown.
    @discardableResult
    public static func post(
        title: String, subtitle: String? = nil, body: String, sound: String? = nil
    ) -> Bool {
        var script = "display notification \(quote(body)) with title \(quote(title))"
        if let subtitle { script += " subtitle \(quote(subtitle))" }
        if let sound { script += " sound name \(quote(sound))" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// AppleScript string literal. Text reaches this from device replies, so it
    /// is escaped rather than trusted — an unescaped quote would turn a
    /// notification into a syntax error, or worse into extra script.
    private static func quote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
