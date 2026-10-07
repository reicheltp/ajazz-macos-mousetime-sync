// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import AppKit
import Foundation
import MouseTimeKit
import ServiceManagement
import UserNotifications

/// What the menu shows, and the settings behind it.
@MainActor
final class MouseModel: ObservableObject {
    @Published private(set) var dockPresent = false
    @Published private(set) var mouseAwake: Bool?
    @Published private(set) var battery: Int?
    @Published private(set) var batteryReadAt: Date?
    @Published private(set) var rate: Int?
    @Published private(set) var clockSyncedAt: Date?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var legacyDaemonRunning = false
    @Published private(set) var problem: String?
    /// Battery warnings are on, but macOS will not show them.
    @Published private(set) var notificationsBlocked = false

    @Published var holdRate: Int? {
        didSet {
            defaults.set(holdRate ?? 0, forKey: Keys.holdRate)
            engine?.holdRate(holdRate)
        }
    }
    @Published var suppress: Bool {
        didSet {
            defaults.set(suppress, forKey: Keys.suppress)
            engine?.setSuppression(suppress)
        }
    }
    @Published var batteryWarnings: Bool {
        didSet {
            defaults.set(batteryWarnings, forKey: Keys.batteryWarnings)
            if batteryWarnings { requestNotificationPermission() } else { notificationsBlocked = false }
        }
    }

    private enum Keys {
        static let holdRate = "holdRate"
        static let suppress = "suppress"
        static let batteryWarnings = "batteryWarnings"
        static let configuredLogin = "configuredLaunchAtLogin"
        static let loginItemPath = "loginItemPath"
    }

    private let defaults = UserDefaults.standard
    private let log = AppLog()
    private var engine: Engine?

    init() {
        // A second copy would be a second owner of the receiver. That happens
        // more easily than it sounds: a stale login item for an older copy
        // and the installed one both launching at login.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if !others.isEmpty {
            log.note("app        another copy is already running; quitting this one")
            others.first?.activate()
            exit(0)
        }

        let held = defaults.integer(forKey: Keys.holdRate)
        holdRate = held == 0 ? nil : held
        suppress = defaults.bool(forKey: Keys.suppress)
        // Warnings are the point of showing the battery at all, so on by default.
        batteryWarnings = defaults.object(forKey: Keys.batteryWarnings) as? Bool ?? true

        configureLaunchAtLogin()
        if batteryWarnings { requestNotificationPermission() }

        legacyDaemonRunning = LegacyDaemon.isLoaded
        if legacyDaemonRunning {
            // Two processes driving the receiver at once could interleave their
            // command sequences. Stay hands-off until the daemon is gone.
            log.note("app        launchd daemon is running; not touching the receiver")
        } else {
            startEngine()
        }
    }

    // MARK: - Actions

    func refresh() {
        engine?.refresh()
        checkNotificationPermission()
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// Stops the launchd daemon and takes over from it.
    func replaceLegacyDaemon() {
        do {
            try LegacyDaemon.remove()
            legacyDaemonRunning = false
            log.note("app        stopped the launchd daemon; taking over")
            startEngine()
        } catch {
            problem = "Could not stop the background service: \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                defaults.set(Bundle.main.bundlePath, forKey: Keys.loginItemPath)
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            problem = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openLog() {
        NSWorkspace.shared.open(AppLog.url)
    }

    // MARK: - Engine

    private func startEngine() {
        let engine = Engine { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        engine.start(with: .init(holdRate: holdRate, suppress: suppress))
        self.engine = engine
        log.note("app        started: rate \(holdRate.map { "held at \($0) Hz" } ?? "not managed"), "
            + "suppression \(suppress ? "on" : "off"), warnings \(batteryWarnings ? "on" : "off")")
    }

    private func apply(_ update: Engine.Update) {
        switch update {
        case .dockPresent(let present):
            dockPresent = present
            if !present { mouseAwake = nil }
        case .clockSynced(let time):
            clockSyncedAt = time
        case .battery(let status):
            mouseAwake = true
            battery = status.mouseBattery
            batteryReadAt = Date()
            checkNotificationPermission()
        case .mouseAsleep:
            mouseAwake = false
        case .batteryLow(let threshold, let percent):
            log.note("battery    LOW: \(percent)% (crossed \(threshold)%)")
            if batteryWarnings { notifyLowBattery(percent) }
        case .rate(let hz):
            rate = hz
        case .log(let line):
            log.note(line)
        }
    }

    // MARK: - System integration

    /// The launchd daemon used to start at login; the app takes that over, so
    /// it registers itself once on first run. Turning it off afterwards sticks.
    ///
    /// Only an installed copy registers itself — a build being tried out from
    /// `dist/` should not become what launches at login. And the registration
    /// records the bundle's location, so if the app has moved since, it is
    /// renewed here rather than left pointing at the old copy.
    private func configureLaunchAtLogin() {
        let path = Bundle.main.bundlePath
        let installed = path.contains("/Applications/")
        if installed && !defaults.bool(forKey: Keys.configuredLogin) {
            defaults.set(true, forKey: Keys.configuredLogin)
            registerLoginItem()
        } else if installed, SMAppService.mainApp.status == .enabled,
            defaults.string(forKey: Keys.loginItemPath) != path
        {
            try? SMAppService.mainApp.unregister()
            registerLoginItem()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func registerLoginItem() {
        do {
            try SMAppService.mainApp.register()
            defaults.set(Bundle.main.bundlePath, forKey: Keys.loginItemPath)
        } catch {
            problem = "Launch at login: \(error.localizedDescription)"
        }
    }

    /// Asks once; after a refusal macOS answers with an error instead of
    /// asking again, and only System Settings can change it.
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.notificationsBlocked = !granted
                if !granted {
                    self.log.note("app        notifications not permitted"
                        + (error.map { ": \($0.localizedDescription)" } ?? ""))
                }
            }
        }
    }

    /// Picks up a change made in System Settings since the last request. Cheap,
    /// so it rides along with refreshes and battery readings.
    private func checkNotificationPermission() {
        guard batteryWarnings else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
            Task { @MainActor in self?.notificationsBlocked = !allowed }
        }
    }

    private func notifyLowBattery(_ percent: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Mouse battery low"
        content.subtitle = "AJAZZ AJ159 APEX"
        content.body = "\(percent)% remaining. Time to dock it."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "battery-low", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// The launchd agent `launchd/install.sh` sets up, which the app replaces.
enum LegacyDaemon {
    static let label = "de.huskycare.mousetime"

    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isLoaded: Bool {
        (try? launchctl(["print", "gui/\(getuid())/\(label)"])) == 0
    }

    /// Unloads the agent and removes its plist, so it does not come back at
    /// the next login. The CLI binary itself stays; it is still useful by hand.
    static func remove() throws {
        _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"])
        // bootout returns before the process is gone. Taking over while it is
        // still running is exactly the overlap this exists to prevent.
        for _ in 0..<30 where isLoaded {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !isLoaded else { throw StillRunning() }
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.removeItem(at: plist)
        }
    }

    struct StillRunning: LocalizedError {
        var errorDescription: String? { "it is still running after launchctl bootout" }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Appends to the same log file the daemon used, in the same format, so
/// `tail -f ~/Library/Logs/mousetime.log` keeps working.
struct AppLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/mousetime.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func note(_ message: String) {
        let line = "\(Self.formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.url)
        }
    }
}
