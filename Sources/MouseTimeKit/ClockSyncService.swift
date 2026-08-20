import AppKit
import Foundation

/// Keeps the dock's clock in step with the system clock.
///
/// Replaces polling with four triggers, each covering a way the dock's clock can
/// end up wrong:
///
/// - the dock appearing — it comes back from a reset at `2001-01-01 00:00`
/// - waking from sleep — the dock loses time while the machine is down
/// - the system clock or time zone changing — daylight saving, travel
/// - a periodic timer — drift, and any transition the others missed
///
/// Like ``DockMonitor``, state is only touched from the run loop ``start()`` was
/// called on; `@unchecked Sendable` records that rather than pretending the
/// IOKit C callbacks can be actor-isolated.
public final class ClockSyncService: @unchecked Sendable {
    /// Why a sync was attempted. Appears verbatim in the log.
    public enum Reason: String, Sendable {
        case startup
        case connect
        case wake
        case clockChange = "clock-change"
        case periodic
    }

    /// Something worth reporting. The caller decides how to present it.
    public enum Event: Sendable {
        case appeared(DeviceInfo)
        case disappeared(DeviceInfo)
        case synced(reason: Reason, time: Date, device: DeviceInfo)
        case failed(reason: Reason, outcome: ClockSync.Outcome)
        /// No matching interface was present, so nothing was attempted.
        case absent(reason: Reason)
        /// Suppressed because a successful sync just happened.
        case debounced(reason: Reason)
        case failedToStart(String)
    }

    public struct Configuration: Sendable {
        /// How often to re-send the time.
        ///
        /// This is the primary trigger, not a safety net. Measured on an AJ159:
        /// the dock forgets the time within a few minutes — most likely when
        /// the mouse's radio link drops as it goes to sleep — *without*
        /// re-enumerating on USB. So no device notification fires, and the only
        /// thing that recovers the display is re-sending.
        ///
        /// The cost is one 64-byte feature report to a USB-powered dock, so a
        /// short interval is close to free; the mouse's battery is not involved.
        public var interval: TimeInterval
        /// How long to wait after the dock appears before sending. The firmware
        /// will not accept a report immediately after enumeration — sent too
        /// early, it is silently lost.
        public var settle: TimeInterval
        /// Successful syncs closer together than this are suppressed. Several
        /// interfaces of the same receiver appear at once, so a single physical
        /// connect produces several triggers.
        public var debounce: TimeInterval

        public init(
            interval: TimeInterval = 30,
            settle: TimeInterval = 2.5,
            debounce: TimeInterval = 2
        ) {
            self.interval = interval
            self.settle = settle
            self.debounce = debounce
        }
    }

    private let configuration: Configuration
    private let predicate: (DeviceInfo) -> Bool
    private let emit: (Event) -> Void

    private var monitor: DockMonitor?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastSuccess: Date?
    private var isInitialScan = false

    /// - Parameters:
    ///   - predicate: which interfaces to send the clock report to. The default
    ///     is the narrow one — AJAZZ interfaces that are not standard input
    ///     devices — which is what keeps this out of TCC's way.
    ///   - onEvent: called on the run loop for every ``Event``.
    public init(
        configuration: Configuration = Configuration(),
        sendingTo predicate: @escaping (DeviceInfo) -> Bool = { $0.isControlInterface },
        onEvent: @escaping (Event) -> Void
    ) {
        self.configuration = configuration
        self.predicate = predicate
        self.emit = onEvent
    }

    deinit { stop() }

    /// Installs all triggers. The caller is responsible for running the run
    /// loop afterwards.
    public func start() {
        // Watch for any AJAZZ interface, not just the control one: the
        // interfaces of a single receiver do not appear in a guaranteed order,
        // and noticing the receiver at all is the signal we want.
        let monitor = DockMonitor(
            matching: { $0.isAjazz },
            onAppear: { [weak self] device in self?.handleAppear(device) },
            onDisappear: { [weak self] device in self?.emit(.disappeared(device)) }
        )
        self.monitor = monitor

        isInitialScan = true
        do {
            try monitor.start()
        } catch {
            emit(.failedToStart(String(describing: error)))
        }
        isInitialScan = false

        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, .wake)
        observe(NotificationCenter.default, .NSSystemClockDidChange, .clockChange)
        observe(NotificationCenter.default, .NSSystemTimeZoneDidChange, .clockChange)

        let timer = Timer(timeInterval: configuration.interval, repeats: true) {
            [weak self] _ in
            self?.sync(reason: .periodic)
        }
        RunLoop.current.add(timer, forMode: .default)
        self.timer = timer
    }

    /// Removes all triggers.
    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        monitor?.stop()
        monitor = nil
    }

    /// Syncs now, ignoring the debounce. Used by the one-shot command path.
    @discardableResult
    public func syncNow(reason: Reason = .startup) -> ClockSync.Outcome {
        perform(reason: reason, respectDebounce: false)
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ reason: Reason
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: nil) {
            [weak self] _ in
            self?.sync(reason: reason)
        }
        observers.append(observer)
    }

    private func handleAppear(_ device: DeviceInfo) {
        emit(.appeared(device))
        if isInitialScan {
            // Already enumerated and settled long ago; no need to wait.
            sync(reason: .startup, after: 0)
        } else {
            sync(reason: .connect, after: configuration.settle)
        }
    }

    private func sync(reason: Reason, after delay: TimeInterval? = nil) {
        let wait = delay ?? 0
        guard wait > 0 else {
            _ = perform(reason: reason, respectDebounce: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            _ = self?.perform(reason: reason, respectDebounce: true)
        }
    }

    @discardableResult
    private func perform(reason: Reason, respectDebounce: Bool) -> ClockSync.Outcome {
        if respectDebounce, let last = lastSuccess,
            Date().timeIntervalSince(last) < configuration.debounce
        {
            emit(.debounced(reason: reason))
            return ClockSync.Outcome(attempts: [])
        }

        let now = Date()
        let outcome = ClockSync.send(now, to: predicate)

        if let device = outcome.accepted {
            lastSuccess = now
            emit(.synced(reason: reason, time: now, device: device))
        } else if outcome.attempts.isEmpty {
            emit(.absent(reason: reason))
        } else {
            emit(.failed(reason: reason, outcome: outcome))
        }
        return outcome
    }
}
