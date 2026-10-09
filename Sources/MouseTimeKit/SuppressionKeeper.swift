// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import AppKit
import Foundation

/// Keeps ``PhantomInputSuppressor``'s mapping in force.
///
/// Applying it once on connect is not enough. After a wake the event system
/// was seen holding an empty mapping in the keyboard filter while the stored
/// property still listed every entry — same service, no re-enumeration, so no
/// connect notification either — and phantom keystrokes came straight through.
/// So besides the connect, this checks the active filter after a wake and on a
/// timer, and reapplies when it comes up short.
public final class SuppressionKeeper: @unchecked Sendable {
    public enum Event: Sendable {
        /// Applied because the interface appeared.
        case applied(DeviceInfo, count: Int)
        /// The active filter had lost entries; they were put back.
        case restored(DeviceInfo, found: Int, count: Int)
        case failed(DeviceInfo, String)
    }

    public struct Configuration: Sendable {
        /// How often to check the active filter when nothing else prompts it.
        public var interval: TimeInterval
        /// Checks after a wake, as delays from it. More than one, because when
        /// exactly the event system rebuilds its filters is not known.
        public var wakeChecks: [TimeInterval]

        public init(interval: TimeInterval = 60, wakeChecks: [TimeInterval] = [1, 5, 15, 45]) {
            self.interval = interval
            self.wakeChecks = wakeChecks
        }
    }

    private let configuration: Configuration
    private let emit: (Event) -> Void
    private var monitor: DockMonitor?
    private var timer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var scheduler = RunLoopScheduler.current

    public init(configuration: Configuration = .init(), onEvent: @escaping (Event) -> Void) {
        self.configuration = configuration
        self.emit = onEvent
    }

    deinit { stop() }

    /// Applies to whatever is attached and installs the triggers. Throws only
    /// if the device monitor cannot start; the timer still runs in that case.
    public func start() throws {
        scheduler = .current
        timer = scheduler.every(configuration.interval) { [weak self] in self?.check() }

        // System wake and display wake both: the second also covers a lock
        // screen, and either may be when the filters are rebuilt.
        let scheduler = self.scheduler
        let delays = configuration.wakeChecks
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] _ in
                guard self != nil else { return }
                for delay in delays {
                    scheduler.after(delay) { [weak self] in self?.check() }
                }
            })
        }

        let monitor = DockMonitor(matching: \.isPhantomInputCandidate) { [weak self] device in
            self?.apply(to: device)
        }
        self.monitor = monitor
        try monitor.start()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObservers = []
        monitor?.stop()
        monitor = nil
    }

    /// Reapplies wherever the active filter is short. Quiet when all is well.
    public func check() {
        let expected = PhantomInputSuppressor.declaredUsageCount
        for device in DockDiscovery.interfaces(where: \.isPhantomInputCandidate) {
            do {
                let found = try PhantomInputSuppressor.appliedCount(for: device)
                guard found < expected else { continue }
                let count = try PhantomInputSuppressor.apply(to: device)
                emit(.restored(device, found: found, count: count))
            } catch {
                emit(.failed(device, String(describing: error)))
            }
        }
    }

    private func apply(to device: DeviceInfo) {
        do {
            emit(.applied(device, count: try PhantomInputSuppressor.apply(to: device)))
        } catch {
            emit(.failed(device, String(describing: error)))
        }
    }
}
