// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation

/// What the receiver reports about the devices paired with it.
public struct DeviceStatus: Sendable, Equatable {
    /// Mouse charge, 0–100. Only meaningful when ``mouseOnline`` is true.
    public let mouseBattery: Int
    /// Keyboard charge, for receivers paired with one. Zero on a mouse-only dock.
    public let keyboardBattery: Int
    public let mouseOnline: Bool
    public let keyboardOnline: Bool
    /// The first bytes of the raw reply, for diagnostics.
    public let raw: [UInt8]

    /// Whether the mouse charge can be believed.
    ///
    /// The receiver answers the status query from its own cache, so it returns a
    /// number even when it has not heard from the mouse. A reading is only used
    /// when the mouse is reported online and the value is in range — a warning
    /// fired on a stale zero would be worse than no warning at all.
    public var hasUsableMouseBattery: Bool {
        mouseOnline && (1...100).contains(mouseBattery)
    }

    /// Parses a status reply. Offsets are from AJAZZ's own driver.
    init(reply: [UInt8]) {
        // Byte 0 and byte 5 are the driver's isCanRead/isCanSend flags. They
        // gate *relaying* commands on to the mouse over the radio, not the
        // validity of the cached battery value, so they are deliberately not
        // used as a trust signal here — measured false while the mouse was
        // plainly present and charging.
        keyboardBattery = reply.count > 1 ? Int(reply[1]) : 0
        mouseBattery = reply.count > 2 ? Int(reply[2]) : 0
        keyboardOnline = reply.count > 3 && reply[3] == 0
        mouseOnline = reply.count > 4 && reply[4] == 0
        raw = Array(reply.prefix(8))
    }

    /// Testing seam.
    public init(
        mouseBattery: Int, keyboardBattery: Int = 0,
        mouseOnline: Bool, keyboardOnline: Bool = false, raw: [UInt8] = []
    ) {
        self.mouseBattery = mouseBattery
        self.keyboardBattery = keyboardBattery
        self.mouseOnline = mouseOnline
        self.keyboardOnline = keyboardOnline
        self.raw = raw
    }
}

/// Reads ``DeviceStatus`` from the receiver.
public enum StatusQuery {
    /// Tells the receiver which paired device the next status reply is about.
    /// Skipping this leaves the mouse reported offline, whatever its real state.
    static let selectMouse: [UInt8] = [0xf6, 0x05]
    static let selectKeyboard: [UInt8] = [0xf6, 0x0a]

    /// Status/battery query.
    static let statusCommand: UInt8 = 0xf7

    /// Reads the status of the mouse paired with `device`.
    ///
    /// - Parameter attempts: how many times to poll before giving up. The
    ///   receiver needs a moment after being told which device to report on.
    public static func read(from device: DeviceInfo, attempts: Int = 5) throws -> DeviceStatus {
        try VendorChannel.withOpen(device) { channel in
            try channel.send(Self.selectMouse)

            var last: DeviceStatus?
            for _ in 0..<max(1, attempts) {
                Thread.sleep(forTimeInterval: 0.1)
                let status = DeviceStatus(reply: try channel.exchange([Self.statusCommand]))
                last = status
                if status.hasUsableMouseBattery { return status }
            }
            return last ?? DeviceStatus(reply: [])
        }
    }

    /// Reads status from the first interface that answers.
    ///
    /// Returns `nil` when no candidate interface is attached.
    public static func readFirstAvailable(
        matching predicate: (DeviceInfo) -> Bool = { $0.isControlInterface }
    ) throws -> (DeviceInfo, DeviceStatus)? {
        var firstFailure: Error?
        for device in DockDiscovery.interfaces(where: predicate) {
            do {
                return (device, try read(from: device))
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
        return nil
    }
}
