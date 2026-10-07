// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import AppKit
import Foundation

/// The mouse's USB report rate, and the wire encoding its firmware uses for it.
///
/// Pinned from AJAZZ's own web driver (`qmk.top/v4`): the AJ159 APEX is a
/// `mouse_pan1080_g62_*` device, every variant of which inherits its settings
/// code unchanged from `CommonMsPan1080`. That class encodes rates as below —
/// note 8000 Hz is `0x81`, not a small number, and there is no code `3`.
public enum ReportRate {
    /// Supported rates in Hz, keyed by their wire code.
    static let byCode: [UInt8: Int] = [
        0x81: 8000, 0x82: 4000, 0x84: 2000, 0x01: 1000, 0x02: 500, 0x04: 250, 0x08: 125,
    ]

    /// Every rate the firmware has a code for, fastest first.
    public static let supported: [Int] = byCode.values.sorted(by: >)

    public static func hz(forCode code: UInt8) -> Int? { byCode[code] }

    public static func code(forHz hz: Int) -> UInt8? {
        byCode.first { $0.value == hz }?.key
    }
}

/// The mouse's 64-byte settings block ("option param 0" in AJAZZ's driver).
///
/// Read with `0xd3`, written with `0x53`, and laid out identically both ways:
/// byte 8 is the active profile, byte 9 the report rate, and the rest carries
/// debounce, lighting, sleep timers and sensor options. There is no narrower
/// command the vendor's UI uses to change the rate — it rewrites this whole
/// block — so this does the same, changing nothing it was not asked to.
struct MouseOptionBlock: Equatable {
    static let readCommand: UInt8 = 0xd3
    static let writeCommand: UInt8 = 0x53

    static let profileOffset = 8
    static let rateOffset = 9

    /// The block as the mouse returned it.
    let bytes: [UInt8]

    enum ParseError: Error, CustomStringConvertible {
        case short(Int)
        case notAnOptionBlock(UInt8)
        case unknownRateCode(UInt8)

        var description: String {
            switch self {
            case .short(let count):
                return "settings reply was \(count) bytes, expected 64"
            case .notAnOptionBlock(let first):
                return String(format: "reply starts 0x%02x, not the settings block (0xd3)", first)
            case .unknownRateCode(let code):
                return String(format: "unrecognised report-rate code 0x%02x", code)
            }
        }
    }

    /// Validates a reply to ``readCommand``.
    ///
    /// The checks are deliberately strict, because this block is about to be
    /// written back: the reply must echo the command and carry a rate code the
    /// firmware is known to use. Anything else means the layout is not the one
    /// documented here, and writing it back would be guessing.
    init(reply: [UInt8]) throws {
        guard reply.count >= VendorChannel.reportSize else { throw ParseError.short(reply.count) }
        guard reply[0] == Self.readCommand else { throw ParseError.notAnOptionBlock(reply[0]) }
        guard ReportRate.hz(forCode: reply[Self.rateOffset]) != nil else {
            throw ParseError.unknownRateCode(reply[Self.rateOffset])
        }
        bytes = Array(reply.prefix(VendorChannel.reportSize))
    }

    var rate: Int { ReportRate.hz(forCode: bytes[Self.rateOffset])! }
    var profile: Int { Int(bytes[Self.profileOffset]) }

    /// The write that sets `hz`, leaving every other setting as read.
    ///
    /// Mirrors AJAZZ's `setMouseOption0` byte for byte: bytes 1–6 are zero,
    /// byte 11 is zero, and bytes 17–18 are the constants `ff 08` it always
    /// sends. This firmware reads those two back as `00 00`, so they look like
    /// write-only markers; they are sent because the vendor sends them, not
    /// copied from the read.
    func writing(rate hz: Int) -> [UInt8]? {
        guard let code = ReportRate.code(forHz: hz) else { return nil }
        var out = bytes
        out[0] = Self.writeCommand
        for index in 1...6 { out[index] = 0 }
        out[Self.rateOffset] = code
        out[11] = 0
        out[17] = 0xff
        out[18] = 0x08
        return MouseRelay.checksummed(out)
    }
}

/// Talks to the mouse *through* the receiver, over the 2.4 GHz link.
///
/// The receiver relays commands it is handed while the mouse is selected, and
/// gates both directions with flags in its status reply. Sequence, from AJAZZ's
/// driver and confirmed on the hardware:
///
///     f6 05            select the mouse
///     f7  → byte 5     "can send": poll until 1, then send the command
///     f7  → byte 0     "can read": poll until 1
///     fc               ask for the reply to be fetched
///     GetReport        the mouse's answer
///
/// Status byte 6 says which device the flags are about (`2` mouse, `3` both).
struct MouseRelay {
    let channel: VendorChannel

    enum Failure: Error, CustomStringConvertible {
        /// The receiver never signalled it could reach the mouse — asleep, out
        /// of range, or switched off. Not a fault; try again later.
        case mouseUnreachable

        var description: String {
            switch self {
            case .mouseUnreachable: return "the mouse is not reachable over the radio (asleep?)"
            }
        }
    }

    private static let pollInterval: TimeInterval = 0.1
    private static let polls = 10
    private static let gap: TimeInterval = 0.01

    /// Sets byte 7 so that bytes 0–7 sum to `0xff` — the firmware's "Bit7"
    /// checksum. A command shorter than 9 bytes is padded first, as the
    /// vendor does.
    static func checksummed(_ payload: [UInt8]) -> [UInt8] {
        var out = payload
        if out.count < 9 { out += [UInt8](repeating: 0, count: 9 - out.count) }
        let sum = out[0..<7].reduce(0) { $0 &+ $1 }
        out[7] = 0xff &- sum
        return out
    }

    /// Sends `payload` to the mouse and returns its reply.
    func exchange(_ payload: [UInt8]) throws -> [UInt8] {
        try send(payload)
        return try read()
    }

    /// Sends `payload` to the mouse without waiting for an answer.
    func send(_ payload: [UInt8]) throws {
        try channel.send(StatusQuery.selectMouse)
        Thread.sleep(forTimeInterval: Self.gap)
        try waitFor(flagAt: 5)
        Thread.sleep(forTimeInterval: Self.gap)
        try channel.send(Self.checksummed(payload))
    }

    private func read() throws -> [UInt8] {
        try waitFor(flagAt: 0)
        Thread.sleep(forTimeInterval: Self.gap)
        try channel.send([0xfc])
        Thread.sleep(forTimeInterval: Self.gap)
        return try channel.read()
    }

    private func waitFor(flagAt index: Int) throws {
        for _ in 0..<Self.polls {
            Thread.sleep(forTimeInterval: Self.pollInterval)
            let status = try channel.exchange([StatusQuery.statusCommand], settle: Self.gap)
            let aboutMouse = status[6] == 2 || status[6] == 3
            if aboutMouse && status[index] == 1 { return }
        }
        throw Failure.mouseUnreachable
    }
}

/// Reads and sets the mouse's report rate.
public enum ReportRateControl {
    /// What one read or one enforcement found.
    public enum Outcome: Sendable, Equatable {
        /// Already at the requested rate; nothing was written.
        case unchanged(hz: Int)
        /// Written, and confirmed by reading back.
        case changed(from: Int, to: Int)
    }

    public enum Failure: Error, CustomStringConvertible {
        case unsupportedRate(Int)
        /// The write went out, but reading back shows something else.
        case notApplied(requested: Int, readBack: Int)

        public var description: String {
            switch self {
            case .unsupportedRate(let hz):
                return "\(hz) Hz is not a rate this mouse supports "
                    + "(\(ReportRate.supported.map(String.init).joined(separator: ", ")))"
            case .notApplied(let requested, let readBack):
                return "wrote \(requested) Hz but the mouse reads back \(readBack) Hz"
            }
        }
    }

    /// How long to let the mouse store a new block before reading it back.
    /// The vendor waits 100 ms; this is the margin the first tests used.
    static let commitDelay: TimeInterval = 0.3

    static func readBlock(_ relay: MouseRelay) throws -> MouseOptionBlock {
        try MouseOptionBlock(reply: relay.exchange([MouseOptionBlock.readCommand]))
    }

    /// The mouse's current report rate, read through `device`.
    public static func read(from device: DeviceInfo) throws -> Int {
        try VendorChannel.withOpen(device) { try readBlock(MouseRelay(channel: $0)).rate }
    }

    /// Makes the rate `hz`, writing only if it differs, and verifies the result.
    public static func ensure(_ hz: Int, on device: DeviceInfo) throws -> Outcome {
        guard ReportRate.code(forHz: hz) != nil else { throw Failure.unsupportedRate(hz) }

        return try VendorChannel.withOpen(device) { channel in
            let relay = MouseRelay(channel: channel)
            let before = try readBlock(relay)
            guard before.rate != hz else { return .unchanged(hz: hz) }

            try relay.send(before.writing(rate: hz)!)
            Thread.sleep(forTimeInterval: commitDelay)

            let after = try readBlock(relay)
            guard after.rate == hz else {
                throw Failure.notApplied(requested: hz, readBack: after.rate)
            }
            return .changed(from: before.rate, to: hz)
        }
    }

    /// The first control interface that is present, if any.
    public static func firstControlInterface(
        matching predicate: (DeviceInfo) -> Bool = { $0.isControlInterface }
    ) -> DeviceInfo? {
        DockDiscovery.interfaces(where: predicate).first
    }
}

/// Keeps the report rate where it was set.
///
/// The setting does not survive the receiver being unplugged — it came back as
/// 500 Hz after a replug that followed setting 1000 Hz — so, like the clock, it
/// has to be re-applied. Checked when the receiver appears, after wake, and on
/// a slow timer for transitions nothing announces. Each check is a read; a
/// write happens only when the rate has actually drifted.
///
/// `@unchecked Sendable` for the same reason as the other monitors: all state is
/// touched only from the run loop ``start()`` was called on.
public final class ReportRateKeeper: @unchecked Sendable {
    public enum Event: Sendable {
        case checked(Int)
        case corrected(from: Int, to: Int)
        /// The mouse could not be reached; a retry is scheduled.
        case unreachable
        case failed(String)
    }

    public struct Configuration: Sendable {
        public var hz: Int
        /// How often to re-check when nothing else prompts it.
        public var interval: TimeInterval
        /// Delay after the receiver appears. Longer than the clock's settle:
        /// the radio link to the mouse comes up after the receiver enumerates.
        public var settle: TimeInterval
        /// Delay before retrying when the mouse was not reachable.
        public var retryInterval: TimeInterval

        public init(
            hz: Int, interval: TimeInterval = 300, settle: TimeInterval = 5,
            retryInterval: TimeInterval = 30
        ) {
            self.hz = hz
            self.interval = interval
            self.settle = settle
            self.retryInterval = retryInterval
        }
    }

    private let configuration: Configuration
    private let predicate: (DeviceInfo) -> Bool
    private let emit: (Event) -> Void
    private var monitor: DockMonitor?
    private var timer: Timer?
    private var retryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isInitialScan = false

    public init(
        configuration: Configuration,
        matching predicate: @escaping (DeviceInfo) -> Bool = { $0.isControlInterface },
        onEvent: @escaping (Event) -> Void
    ) {
        self.configuration = configuration
        self.predicate = predicate
        self.emit = onEvent
    }

    deinit { stop() }

    /// Installs the triggers and checks once. Throws only if the device
    /// monitor cannot start; the timer still runs in that case.
    public func start() throws {
        let timer = Timer(timeInterval: configuration.interval, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.current.add(timer, forMode: .default)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.check(after: self?.configuration.settle ?? 0) }

        let monitor = DockMonitor(matching: predicate) { [weak self] _ in
            guard let self else { return }
            // The control interface already being there at startup is not a
            // connect; check right away rather than waiting out the settle.
            self.check(after: self.isInitialScan ? 0 : self.configuration.settle)
        }
        self.monitor = monitor
        isInitialScan = true
        defer { isInitialScan = false }
        try monitor.start()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        monitor?.stop()
        monitor = nil
    }

    private func check(after delay: TimeInterval) {
        guard delay > 0 else { return check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
    }

    /// Reads once, correcting if needed.
    public func check() {
        guard let device = ReportRateControl.firstControlInterface(matching: predicate) else {
            return  // receiver not attached; its appearance will trigger a check
        }
        do {
            switch try ReportRateControl.ensure(configuration.hz, on: device) {
            case .unchanged(let hz):
                emit(.checked(hz))
            case .changed(let from, let to):
                emit(.corrected(from: from, to: to))
            }
        } catch MouseRelay.Failure.mouseUnreachable {
            emit(.unreachable)
            scheduleRetry()
        } catch {
            emit(.failed(String(describing: error)))
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: configuration.retryInterval, repeats: false) {
            [weak self] _ in self?.check()
        }
        RunLoop.current.add(timer, forMode: .default)
        retryTimer = timer
    }
}
