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

// MARK: - daemon

func runDaemon(_ args: Arguments) -> Int32 {
    if let bad = reportUnknown(args, known: ["all", "interval", "settle", "v", "verbose"]) {
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
