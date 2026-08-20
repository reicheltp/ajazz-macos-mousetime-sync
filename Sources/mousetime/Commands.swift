// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import MouseTimeKit

// MARK: - Interface selection

/// Which interfaces a command should look at.
enum Scope {
    /// AJAZZ interfaces that are not standard input devices. The control
    /// channel lives here, and nothing in this set is TCC-protected.
    case control
    /// Every AJAZZ interface, input devices included. The documented fallback
    /// for when the firmware puts the control channel behind a standard usage.
    case allAjazz
    /// Every HID interface on the machine.
    case everything

    var predicate: (DeviceInfo) -> Bool {
        switch self {
        case .control: return { $0.isControlInterface }
        case .allAjazz: return { $0.isAjazz }
        case .everything: return { _ in true }
        }
    }
}

// MARK: - list

func runList(_ args: Arguments) -> Int32 {
    if let bad = reportUnknown(args, known: ["all", "dock"]) { return bad }

    let scope: Scope = args.has("all") ? .everything : .allAjazz
    var interfaces = DockDiscovery.interfaces(where: scope.predicate)
    if args.has("dock") {
        interfaces = interfaces.filter(\.isDock)
    }

    guard !interfaces.isEmpty else {
        if args.has("all") {
            print("no HID interfaces at all — that would be surprising")
        } else {
            print("no AJAZZ interfaces found.")
            print("is the dock plugged in, and is its switch set to this machine?")
            print("run with --all to list every HID interface.")
        }
        return 1
    }

    for interface in interfaces {
        let marker = interface.isControlInterface ? "*" : " "
        print("\(marker) \(interface)")
        var detail = "    usagePage=0x\(hex(interface.primaryUsagePage, 4))"
        detail += " usage=0x\(hex(interface.primaryUsage, 4))"
        if !interface.manufacturer.isEmpty { detail += " mfr=\"\(interface.manufacturer)\"" }
        if interface.locationID != 0 { detail += " location=0x\(hex(interface.locationID, 8))" }
        print(detail)
    }

    let candidates = interfaces.filter(\.isControlInterface).count
    print("")
    print("\(interfaces.count) interface(s); \(candidates) marked * as a control-channel candidate")
    if candidates == 0 && !args.has("all") {
        print("no candidate found — try: mousetime sync --all")
    }
    return 0
}

// MARK: - sync

func runSync(_ args: Arguments) -> Int32 {
    if let bad = reportUnknown(args, known: ["all", "v", "verbose"]) { return bad }

    let verbose = args.has("v", "verbose")
    let scope: Scope = args.has("all") ? .allAjazz : .control
    let now = Date()
    let outcome = ClockSync.send(now, to: scope.predicate)

    if outcome.attempts.isEmpty {
        print("no matching interface found.")
        if !args.has("all") {
            print("try: mousetime list        (see what is actually attached)")
            print("     mousetime sync --all  (also try the input interfaces)")
        }
        return 1
    }

    if verbose {
        for attempt in outcome.attempts {
            let verdict = attempt.failure.map(\.description) ?? "accepted"
            print("  \(attempt.device) → \(verdict)")
        }
    }

    guard let device = outcome.accepted else {
        print("tried \(outcome.attempts.count) interface(s); none accepted the clock report.")
        if !verbose { print("run again with -v to see why each one refused.") }
        if !args.has("all") { print("then try: mousetime sync --all") }
        return 1
    }

    print("set dock clock to \(stamp(now)) via \(device)")
    return 0
}

// MARK: - suppress

func runSuppress(_ args: Arguments) -> Int32 {
    if let bad = reportUnknown(args, known: ["clear", "dry-run", "status"]) { return bad }

    let candidates = DockDiscovery.interfaces(where: \.isPhantomInputCandidate)
    guard !candidates.isEmpty else {
        print("no AJAZZ input interface other than the mouse is attached.")
        print("nothing to suppress — run `mousetime list` to see what is there.")
        return 1
    }

    if args.has("dry-run") {
        print("would map \(PhantomInputSuppressor.declaredUsageCount) usages to nothing on:")
        for device in candidates { print("  \(device)") }
        for block in PhantomInputSuppressor.declaredRanges {
            print(String(format: "  %@ 0x%04x...0x%04x (%d usages)",
                         HIDUsage.pageName(block.page),
                         block.usages.lowerBound, block.usages.upperBound,
                         block.usages.count))
        }
        return 0
    }

    var failed = false
    for device in candidates {
        do {
            if args.has("status") {
                let count = try PhantomInputSuppressor.appliedCount(for: device)
                print("\(count) usage(s) suppressed on \(device)")
            } else if args.has("clear") {
                try PhantomInputSuppressor.clear(from: device)
                print("cleared suppression on \(device)")
            } else {
                let count = try PhantomInputSuppressor.apply(to: device)
                print("suppressed \(count) usages on \(device)")
            }
        } catch {
            complain("\(device): \(error)")
            failed = true
        }
    }

    if !args.has("status") && !args.has("clear") {
        print("")
        print("this is not persistent: unplugging the dock or rebooting clears it.")
        print("run `mousetime daemon --suppress` (or reinstall with --suppress) to")
        print("have it reapplied whenever the interface comes back.")
    }
    return failed ? 1 : 0
}

// MARK: - battery

func runBattery(_ args: Arguments) -> Int32 {
    if let bad = reportUnknown(args, known: ["test-notification", "v", "verbose"]) { return bad }

    if args.has("test-notification") {
        // The situation this feature exists for cannot be produced on demand, so
        // there has to be a way to prove the notification path works.
        let posted = Notifier.post(
            title: "mousetime", subtitle: "AJAZZ AJ159 APEX",
            body: "Test: battery would be at 5%", sound: "Submarine")
        // Deliberately not "notification shown": osascript exits 0 even when
        // nothing is displayed, which is exactly the open bug here.
        print(posted
            ? "osascript accepted it — if nothing appeared on screen, that is issue #1"
            : "osascript refused to post")
        return posted ? 0 : 1
    }

    do {
        guard let (device, status) = try StatusQuery.readFirstAvailable() else {
            print("no AJAZZ control interface attached.")
            return 1
        }
        if args.has("v", "verbose") {
            print("\(device)")
            print("    raw: \(status.raw.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
        guard status.hasUsableMouseBattery else {
            print("mouse battery: unavailable (mouse reported "
                + "\(status.mouseOnline ? "online" : "offline"), value \(status.mouseBattery))")
            print("the receiver answers from its own cache; wake the mouse and try again.")
            return 1
        }
        print("mouse battery: \(status.mouseBattery)%")
        if status.keyboardOnline {
            print("keyboard battery: \(status.keyboardBattery)%")
        }
        return 0
    } catch {
        complain("\(error)")
        return 1
    }
}

// MARK: - daemon

func runDaemon(_ args: Arguments) -> Int32 {
    if let bad = reportUnknown(args, known: ["all", "interval", "settle", "v", "verbose", "suppress", "battery",
                 "battery-interval", "battery-thresholds"]) {
        return bad
    }

    var configuration = ClockSyncService.Configuration()
    if let text = args.value("interval") {
        guard let interval = parseDuration(text) else {
            complain("bad --interval \"\(text)\"; expected something like 15m, 900s or 900")
            return 2
        }
        configuration.interval = interval
    }
    if let text = args.value("settle") {
        guard let settle = parseDuration(text) else {
            complain("bad --settle \"\(text)\"; expected something like 2.5s")
            return 2
        }
        configuration.settle = settle
    }

    let scope: Scope = args.has("all") ? .allAjazz : .control
    print("\(stamp(Date())) daemon starting: interval=\(brief(configuration.interval)) "
        + "settle=\(brief(configuration.settle)) scope=\(args.has("all") ? "all-ajazz" : "control")")

    let log = DaemonLog(verbose: args.has("v", "verbose"))
    let service = ClockSyncService(
        configuration: configuration,
        sendingTo: scope.predicate,
        onEvent: { log.report($0) }
    )
    service.start()

    // Suppression rides along with the daemon because the mapping is attached
    // to a live HID service: unplugging the dock or rebooting drops it, and
    // something has to notice the interface coming back. Kept on its own
    // monitor rather than folded into ClockSyncService — different interface,
    // different concern.
    var suppressionMonitor: DockMonitor?
    if args.has("suppress") {
        let monitor = DockMonitor(
            matching: \.isPhantomInputCandidate,
            onAppear: { device in
                do {
                    let count = try PhantomInputSuppressor.apply(to: device)
                    log.note("suppressed \(count) usages on \(device)")
                } catch {
                    log.note("FAILED to suppress \(device): \(error)")
                }
            }
        )
        do {
            try monitor.start()
            suppressionMonitor = monitor
        } catch {
            log.note("FAILED to watch for the phantom-input interface: \(error)")
        }
    }
    _ = suppressionMonitor  // held for the process lifetime

    // Battery warnings. Opt-in for the same reason as suppression: it polls the
    // radio, and not every user wants notifications.
    var batteryMonitor: BatteryMonitor?
    if args.has("battery") {
        var configuration = BatteryMonitor.Configuration()
        if let text = args.value("battery-interval") {
            guard let interval = parseDuration(text) else {
                complain("bad --battery-interval \"\(text)\"")
                return 2
            }
            configuration.interval = interval
        }
        if let text = args.value("battery-thresholds") {
            let levels = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !levels.isEmpty, levels.allSatisfy({ (1...100).contains($0) }) else {
                complain("bad --battery-thresholds \"\(text)\"; expected something like 20,10,5")
                return 2
            }
            configuration.thresholds = levels
        }

        let monitor = BatteryMonitor(configuration: configuration) { event in
            switch event {
            case .reading(_, let status):
                log.note("battery    mouse at \(status.mouseBattery)%")
            case .low(let threshold, let percent):
                log.note("battery    LOW: \(percent)% (crossed \(threshold)%) — notifying")
                Notifier.post(
                    title: "Mouse battery low",
                    subtitle: "AJAZZ AJ159 APEX",
                    body: "\(percent)% remaining. Time to dock it.",
                    sound: "Submarine")
            case .unusable(let status):
                log.note("battery    no usable reading (mouse "
                    + "\(status.mouseOnline ? "online" : "offline"))")
            case .failed(let message):
                log.note("battery    FAILED: \(message)")
            }
        }
        monitor.start()
        batteryMonitor = monitor
        log.note("battery    watching, every \(brief(configuration.interval)), "
            + "warn at \(configuration.thresholds.map(String.init).joined(separator: "/"))%")
    }
    _ = batteryMonitor  // held for the process lifetime

    installSignalHandlers {
        print("\(stamp(Date())) stopping")
        service.stop()
        exit(0)
    }

    // The IOKit notification source, the timer, the workspace observers and the
    // settle delays are all attached to this run loop.
    RunLoop.current.run()
    return 0
}

/// Writes daemon events to stdout, collapsing the routine ones.
///
/// The sync interval is seconds, not minutes, so logging every successful
/// periodic sync would bury the events that actually matter under thousands of
/// identical lines a day. Routine periodic successes are therefore summarised on
/// a heartbeat; anything unusual — a device appearing or going, a refusal — is
/// always printed immediately.
private final class DaemonLog {
    private let verbose: Bool
    private let heartbeat: TimeInterval = 15 * 60
    private var lastHeartbeat: Date?
    private var collapsed = 0

    init(verbose: Bool) {
        self.verbose = verbose
    }

    /// Prints a line from outside the sync service, on the same log.
    func note(_ message: String) {
        emit("\(stamp(Date())) \(message)")
    }

    func report(_ event: ClockSyncService.Event) {
        let time = stamp(Date())
        switch event {
        case .appeared(let device):
            emit("\(time) appeared  \(device)")
        case .disappeared(let device):
            emit("\(time) gone      \(device)")

        case .synced(let reason, let when, let device):
            let line = "\(time) synced    [\(reason.rawValue)] \(stamp(when)) via \(device)"
            if reason == .periodic && !verbose {
                collapse(line)
            } else {
                emit(line)
            }

        case .failed(let reason, let outcome):
            emit("\(time) FAILED    [\(reason.rawValue)] "
                + "\(outcome.attempts.count) interface(s) refused:")
            for attempt in outcome.attempts {
                guard let failure = attempt.failure else { continue }
                emit("\(time)             \(attempt.device) → \(failure)")
            }

        case .absent(let reason):
            // Expected whenever the dock is unplugged, and the periodic timer
            // keeps firing, so this collapses too.
            let line = "\(time) absent    [\(reason.rawValue)] no matching interface"
            if reason == .periodic && !verbose {
                collapse(line)
            } else {
                emit(line)
            }

        case .debounced(let reason):
            if verbose { emit("\(time) skipped   [\(reason.rawValue)] just synced") }

        case .failedToStart(let message):
            emit("\(time) FAILED    could not watch for devices: \(message)")
            emit("\(time)           falling back to the periodic timer only")
        }
    }

    /// Prints `line` at most once per heartbeat, noting how many were folded in.
    private func collapse(_ line: String) {
        let now = Date()
        if let last = lastHeartbeat, now.timeIntervalSince(last) < heartbeat {
            collapsed += 1
            return
        }
        lastHeartbeat = now
        let folded = collapsed
        collapsed = 0
        write(folded > 0 ? "\(line) (+\(folded) more like this)" : line)
    }

    /// Prints a noteworthy line and reopens the heartbeat window, so the next
    /// routine line is shown instead of being folded away. That way the log
    /// records the recovery after a disconnect or a refusal, rather than going
    /// quiet again for fifteen minutes.
    private func emit(_ line: String) {
        write(line)
        lastHeartbeat = nil
        collapsed = 0
    }

    private func write(_ line: String) {
        print(line)
    }
}

// MARK: - Shared helpers

private let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func stamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

func hex(_ value: Int, _ width: Int) -> String {
    String(format: "%0\(width)x", value)
}

func brief(_ interval: TimeInterval) -> String {
    if interval >= 3600, interval.truncatingRemainder(dividingBy: 3600) == 0 {
        return "\(Int(interval / 3600))h"
    }
    if interval >= 60, interval.truncatingRemainder(dividingBy: 60) == 0 {
        return "\(Int(interval / 60))m"
    }
    // Not `formatted()`: that is locale-aware, and a log line reading
    // "settle=2,5s" in a German locale is a needless obstacle when someone
    // pastes it into a bug report.
    return String(format: "%gs", interval)
}

func complain(_ message: String) {
    FileHandle.standardError.write(Data("mousetime: \(message)\n".utf8))
}

/// Rejects unrecognised flags rather than running with defaults nobody asked
/// for — a typo'd `--interval` in a launchd plist is otherwise invisible.
private func reportUnknown(_ args: Arguments, known: Set<String>) -> Int32? {
    let strays = args.unrecognized(known: known)
    guard strays.isEmpty else {
        complain("unknown option(s): \(strays.joined(separator: ", "))")
        return 2
    }
    return nil
}

/// Runs `handler` on SIGINT/SIGTERM via the main queue, so cleanup happens on
/// the same run loop as everything else instead of inside a signal context.
private func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) {
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler(handler: handler)
        source.activate()
        signalSources.append(source)
    }
}

/// Kept alive for the process lifetime; a cancelled `DispatchSourceSignal`
/// stops delivering.
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []
