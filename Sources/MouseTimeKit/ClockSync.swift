// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import IOKit
import IOKit.hid

/// Sends ``ClockReport`` to the dock.
public enum ClockSync {
    /// What happened on one interface.
    public struct Attempt: Sendable {
        public let device: DeviceInfo
        /// `nil` means the interface accepted the report.
        public let failure: Failure?

        public var succeeded: Bool { failure == nil }
    }

    /// Why an interface did not take the report.
    public enum Failure: Sendable, CustomStringConvertible {
        /// `IOHIDDeviceOpen` failed. Expected on interfaces macOS protects.
        case openFailed(IOReturn)
        /// The interface opened but rejected the report — i.e. it is not the
        /// control interface.
        case setReportFailed(IOReturn)

        public var description: String {
            switch self {
            case .openFailed(let code):
                return String(format: "open failed (0x%08x)", UInt32(bitPattern: code))
            case .setReportFailed(let code):
                return String(format: "rejected the report (0x%08x)", UInt32(bitPattern: code))
            }
        }
    }

    /// The result of one sync pass.
    public struct Outcome: Sendable {
        public let attempts: [Attempt]

        /// The interface that took the report, if any.
        public var accepted: DeviceInfo? {
            attempts.first(where: \.succeeded)?.device
        }

        public var succeeded: Bool { accepted != nil }
    }

    /// Sets the dock's clock to `date`.
    ///
    /// Every interface accepted by `predicate` is tried until one takes the
    /// report. Which interface number carries the control channel differs
    /// between firmware revisions, and an interface that is not it simply
    /// rejects the report, so probing is cheaper and more durable than
    /// guessing. Stops at the first success.
    @discardableResult
    public static func send(
        _ date: Date = Date(),
        to predicate: (DeviceInfo) -> Bool = { $0.isControlInterface }
    ) -> Outcome {
        let report = ClockReport.bytes(for: date)
        var attempts: [Attempt] = []

        DockDiscovery.forEachService { service, info in
            guard predicate(info) else { return true }
            let failure = deliver(report, to: service)
            attempts.append(Attempt(device: info, failure: failure))
            return failure != nil  // stop once an interface accepted it
        }

        return Outcome(attempts: attempts)
    }

    private static func deliver(_ report: [UInt8], to service: io_service_t) -> Failure? {
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
            return .openFailed(kIOReturnNoDevice)
        }

        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else { return .openFailed(opened) }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // Byte 0 of the buffer is the report ID and is transferred along with
        // the rest; the ID is also passed separately, which is what the HID
        // transport expects.
        let result = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(ClockReport.reportID),
                buffer.baseAddress!,
                buffer.count
            )
        }
        return result == kIOReturnSuccess ? nil : .setReportFailed(result)
    }
}
