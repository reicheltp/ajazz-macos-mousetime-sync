// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import MouseTimeKit

/// Everything that talks to the receiver, on one dedicated thread.
///
/// One thread, because every exchange is a multi-step sequence over a single
/// channel and two of them interleaving would mix up replies. Not the main
/// thread, because a radio round-trip to a sleeping mouse takes a couple of
/// seconds of polling, and the menu must not freeze for that.
///
/// The services are the same ones the CLI daemon runs. Updates go out through
/// `publish`, from the hardware thread; the receiver hops them to the main actor.
final class Engine: @unchecked Sendable {
    struct Settings: Sendable {
        var holdRate: Int?
        var suppress: Bool
    }

    enum Update: Sendable {
        case dockPresent(Bool)
        case clockSynced(Date)
        case battery(DeviceStatus)
        case mouseAsleep
        case batteryLow(threshold: Int, percent: Int)
        case rate(Int)
        case log(String)
    }

    private let publish: @Sendable (Update) -> Void
    private let thread = HardwareThread()

    // Touched only on the hardware thread.
    private var clock: ClockSyncService?
    private var battery: BatteryMonitor?
    private var rate: ReportRateKeeper?
    private var suppression: DockMonitor?
    private var docks: Set<UInt64> = []

    init(publish: @escaping @Sendable (Update) -> Void) {
        self.publish = publish
    }

    func start(with settings: Settings) {
        thread.start()
        thread.scheduler.after(0) { [self] in startServices(settings) }
    }

    /// Reads battery and rate now, rather than waiting for the next poll.
    func refresh() {
        thread.scheduler.after(0) { [self] in
            battery?.poll()
            rate?.check()
        }
    }

    func holdRate(_ hz: Int?) {
        thread.scheduler.after(0) { [self] in rate?.setTarget(hz) }
    }

    func setSuppression(_ enabled: Bool) {
        thread.scheduler.after(0) { [self] in
            if enabled { startSuppression() } else { stopSuppression() }
        }
    }

    // MARK: - On the hardware thread

    private func startServices(_ settings: Settings) {
        let clock = ClockSyncService { [weak self] event in self?.handle(event) }
        clock.start()
        self.clock = clock

        let battery = BatteryMonitor { [weak self] event in self?.handle(event) }
        battery.start()
        self.battery = battery

        let rate = ReportRateKeeper(configuration: .init(hz: settings.holdRate)) {
            [weak self] event in self?.handle(event)
        }
        do {
            try rate.start()
        } catch {
            publish(.log("rate       could not watch for the receiver: \(error); timer only"))
        }
        self.rate = rate

        if settings.suppress { startSuppression() }
    }

    private func handle(_ event: ClockSyncService.Event) {
        switch event {
        case .appeared(let device):
            if device.isDock { docks.insert(device.registryID) }
            publish(.dockPresent(!docks.isEmpty))
        case .disappeared(let device):
            docks.remove(device.registryID)
            publish(.dockPresent(!docks.isEmpty))
            if docks.isEmpty { battery?.deviceWentAway() }
        case .synced(_, let time, _):
            publish(.clockSynced(time))
        case .failed(let reason, let outcome):
            let why = outcome.attempts.compactMap { $0.failure.map(String.init(describing:)) }
            publish(.log("clock      FAILED [\(reason.rawValue)]: \(why.joined(separator: "; "))"))
        case .failedToStart(let message):
            publish(.log("clock      could not watch for devices: \(message); timer only"))
        case .absent, .debounced:
            break
        }
    }

    private func handle(_ event: BatteryMonitor.Event) {
        switch event {
        case .reading(_, let status):
            publish(.battery(status))
        case .low(let threshold, let percent):
            publish(.batteryLow(threshold: threshold, percent: percent))
        case .unusable:
            publish(.mouseAsleep)
        case .failed(let message):
            publish(.log("battery    FAILED: \(message)"))
        }
    }

    private func handle(_ event: ReportRateKeeper.Event) {
        switch event {
        case .checked(let hz):
            publish(.rate(hz))
        case .corrected(let from, let to):
            publish(.rate(to))
            publish(.log("rate       was \(from) Hz, set back to \(to) Hz"))
        case .unreachable:
            break  // the mouse is asleep; the battery reading says so already
        case .failed(let message):
            publish(.log("rate       FAILED: \(message)"))
        }
    }

    private func startSuppression() {
        guard suppression == nil else { return }
        let monitor = DockMonitor(matching: \.isPhantomInputCandidate) { [weak self] device in
            do {
                let count = try PhantomInputSuppressor.apply(to: device)
                self?.publish(.log("suppressed \(count) usages on \(device)"))
            } catch {
                self?.publish(.log("FAILED to suppress \(device): \(error)"))
            }
        }
        do {
            try monitor.start()
            suppression = monitor
        } catch {
            publish(.log("FAILED to watch for the phantom-input interface: \(error)"))
        }
    }

    private func stopSuppression() {
        suppression?.stop()
        suppression = nil
        for device in DockDiscovery.interfaces(where: \.isPhantomInputCandidate) {
            do {
                try PhantomInputSuppressor.clear(from: device)
                publish(.log("cleared suppression on \(device)"))
            } catch {
                publish(.log("FAILED to clear suppression on \(device): \(error)"))
            }
        }
    }
}

/// A thread that does nothing but run its run loop, for the services to live on.
final class HardwareThread: Thread, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    override init() {
        super.init()
        name = "mousetime.hardware"
        qualityOfService = .utility
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with no sources returns immediately; a port keeps it alive
        // until the timers and IOKit notifications are installed.
        RunLoop.current.add(Port(), forMode: .default)
        ready.signal()
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    override func start() {
        super.start()
        ready.wait()  // so `scheduler` is usable as soon as this returns
    }

    /// Schedules work on this thread. Valid once ``start()`` has returned.
    var scheduler: RunLoopScheduler {
        RunLoopScheduler(runLoop: runLoop!)
    }
}
