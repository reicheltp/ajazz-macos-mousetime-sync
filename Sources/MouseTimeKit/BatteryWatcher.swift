// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation

/// Decides when a low-battery warning is due.
///
/// Kept as a pure state machine with no IOKit and no notifications in it,
/// because the situation it exists for — a nearly empty battery — cannot be
/// produced on demand for testing. Everything here is covered by unit tests
/// instead; ``BatteryMonitor`` does the talking to hardware.
public struct BatteryAlarm: Sendable {
    /// Charge levels that warrant a warning, warned at on the way *down*.
    public let thresholds: [Int]

    /// How far above the *highest* threshold the charge must climb before the
    /// alarm re-arms. Without it, a reading hovering on a boundary would notify
    /// over and over.
    public let hysteresis: Int

    /// The lowest threshold already warned about in this discharge cycle.
    private var warned: Int?

    public init(thresholds: [Int] = [20, 10, 5], hysteresis: Int = 3) {
        // Descending, so the *lowest* crossed threshold is the one reported: a
        // battery that jumps 25 → 4 should warn about 5, not 20.
        self.thresholds = thresholds.sorted(by: >)
        self.hysteresis = hysteresis
    }

    /// Feeds a reading in and returns the threshold to warn about, if any.
    ///
    /// One warning per threshold per discharge cycle. A cycle ends only when the
    /// charge climbs clear of the highest threshold — a few points of recovery
    /// while still low is not a new cycle, it is the same low battery.
    public mutating func evaluate(percent: Int) -> Int? {
        if let highest = thresholds.first, percent >= highest + hysteresis {
            warned = nil
        }

        // `last`, not `first`: thresholds run high to low, and the reading may
        // have fallen past several of them between two polls. At 4% the useful
        // warning is "5%", not "20%".
        guard let crossed = thresholds.last(where: { percent <= $0 }) else {
            return nil
        }

        // Already warned at this level or a lower one in this cycle.
        if let warned, crossed >= warned { return nil }

        warned = crossed
        return crossed
    }

    /// Forgets what has been warned about. Used when the device disappears, so
    /// reconnecting with a low battery warns once more.
    public mutating func reset() {
        warned = nil
    }

    /// The lowest threshold warned about so far, for display.
    public var lastWarned: Int? { warned }
}

/// Polls the receiver for battery level and reports threshold crossings.
///
/// `@unchecked Sendable` for the same reason as the other monitors here: all
/// state is touched only from the run loop ``start()`` was called on.
public final class BatteryMonitor: @unchecked Sendable {
    public enum Event: Sendable {
        case reading(DeviceInfo, DeviceStatus)
        /// The charge fell to or below `threshold`. This is the warning.
        case low(threshold: Int, percent: Int)
        /// A reading arrived but cannot be trusted — mouse asleep or absent.
        case unusable(DeviceStatus)
        case failed(String)
    }

    public struct Configuration: Sendable {
        /// How often to ask. Battery moves slowly; polling hard would only
        /// wake the radio for nothing.
        public var interval: TimeInterval
        public var thresholds: [Int]
        /// Delay before retrying after a reading that could not be used.
        ///
        /// Right after the dock appears, the radio link to the mouse is not up
        /// yet and it reads as offline. Waiting a full interval for that would
        /// leave the level unknown for minutes over a few seconds' problem.
        public var retryInterval: TimeInterval

        public init(
            interval: TimeInterval = 300, thresholds: [Int] = [20, 10, 5],
            retryInterval: TimeInterval = 30
        ) {
            self.interval = interval
            self.thresholds = thresholds
            self.retryInterval = retryInterval
        }
    }

    private let configuration: Configuration
    private let predicate: (DeviceInfo) -> Bool
    private let emit: (Event) -> Void
    private var alarm: BatteryAlarm
    private var timer: Timer?
    private var retryTimer: Timer?

    public init(
        configuration: Configuration = Configuration(),
        matching predicate: @escaping (DeviceInfo) -> Bool = { $0.isControlInterface },
        onEvent: @escaping (Event) -> Void
    ) {
        self.configuration = configuration
        self.predicate = predicate
        self.emit = onEvent
        self.alarm = BatteryAlarm(thresholds: configuration.thresholds)
    }

    deinit { stop() }

    /// Starts polling on the current run loop, checking once immediately.
    public func start() {
        poll()
        let timer = Timer(timeInterval: configuration.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.current.add(timer, forMode: .default)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// Schedules a single follow-up read. Replaces any pending one, so a run of
    /// unusable readings cannot pile up timers.
    private func scheduleRetry() {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: configuration.retryInterval, repeats: false) {
            [weak self] _ in
            self?.poll()
        }
        RunLoop.current.add(timer, forMode: .default)
        retryTimer = timer
    }

    /// Forgets warning state, so a reconnected device with a low battery warns
    /// once more rather than staying quiet.
    public func deviceWentAway() {
        alarm.reset()
    }

    /// Reads once and reports. Public so a one-shot command can reuse it.
    @discardableResult
    public func poll() -> DeviceStatus? {
        do {
            guard let (device, status) = try StatusQuery.readFirstAvailable(matching: predicate)
            else { return nil }  // nothing attached; not an error

            guard status.hasUsableMouseBattery else {
                emit(.unusable(status))
                scheduleRetry()
                return status
            }

            emit(.reading(device, status))
            if let threshold = alarm.evaluate(percent: status.mouseBattery) {
                emit(.low(threshold: threshold, percent: status.mouseBattery))
            }
            return status
        } catch {
            emit(.failed(String(describing: error)))
            scheduleRetry()
            return nil
        }
    }
}
