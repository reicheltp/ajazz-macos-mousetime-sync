// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation

/// Posts a macOS notification.
///
/// Uses `osascript` rather than `UNUserNotificationCenter`, which needs a bundle
/// identifier — a bare command-line binary has none, and the framework fails
/// rather than falling back.
///
/// **This does not reliably deliver.** Because the notification is attributed to
/// Script Editor, delivery depends on Script Editor's own notification
/// permission, and on macOS 27 nothing appeared on screen even though
/// `osascript` exited 0. So a `true` return means "osascript accepted it", not
/// "the user saw it" — there is no way to tell the difference from here.
///
/// The real fix is shipping inside an `.app` bundle so
/// `UNUserNotificationCenter` can be used directly, which is what the menu bar
/// app brings. Until then this is kept as a best-effort path.
public enum Notifier {
    /// Posts a notification.
    ///
    /// - Returns: whether `osascript` accepted the request — **not** whether
    ///   anything was displayed. See the type's note.
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
