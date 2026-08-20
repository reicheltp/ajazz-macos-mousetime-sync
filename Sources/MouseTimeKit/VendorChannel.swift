// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import IOKit
import IOKit.hid

/// The receiver's vendor-defined HID interface, opened for one exchange.
///
/// Framing, confirmed against the hardware and against AJAZZ's own web driver:
/// a 64-byte **feature** report under report ID **0**, with the command in byte
/// 0 and the reply read back from the same report.
///
/// Reply shape is per command, not uniform — see ``exchange(_:settle:expectingEcho:)``.
///
/// Nothing here needs a macOS permission: a vendor-defined interface is not a
/// protected input device.
struct VendorChannel {
    /// Report ID used for every exchange. The interface declares no report IDs
    /// at all, so 0 is the only correct value — a command byte that happens to
    /// look like an ID (`0x28` for the clock) is *data*, not an ID.
    static let reportID: CFIndex = 0

    /// Declared report length, from the interface's report descriptor.
    static let reportSize = 64

    private let device: IOHIDDevice

    /// Opens `info`'s interface, runs `body`, and closes it again.
    static func withOpen<T>(_ info: DeviceInfo, _ body: (VendorChannel) throws -> T) throws -> T {
        var result: Result<T, Error>?

        DockDiscovery.forEachService { service, candidate in
            guard candidate.registryID == info.registryID else { return true }

            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                result = .failure(Failure.unavailable)
                return false
            }
            let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard opened == kIOReturnSuccess else {
                result = .failure(Failure.openFailed(opened))
                return false
            }
            defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

            result = Result { try body(VendorChannel(device: device)) }
            return false
        }

        guard let result else { throw Failure.unavailable }
        return try result.get()
    }

    enum Failure: Error, CustomStringConvertible {
        case unavailable
        case openFailed(IOReturn)
        case sendFailed(IOReturn)
        case readFailed(IOReturn)
        /// The reply did not echo the command, so it is not an answer to it.
        case unexpectedReply(expected: UInt8, got: UInt8)

        var description: String {
            switch self {
            case .unavailable:
                return "the interface went away"
            case .openFailed(let code):
                return String(format: "open failed (0x%08x)", UInt32(bitPattern: code))
            case .sendFailed(let code):
                return String(format: "sending failed (0x%08x)", UInt32(bitPattern: code))
            case .readFailed(let code):
                return String(format: "reading failed (0x%08x)", UInt32(bitPattern: code))
            case .unexpectedReply(let expected, let got):
                return String(format: "reply was 0x%02x, expected an echo of 0x%02x", got, expected)
            }
        }
    }

    /// Sends `payload`, zero-padded to the declared report length.
    func send(_ payload: [UInt8]) throws {
        precondition(payload.count <= Self.reportSize, "payload longer than a report")
        var report = [UInt8](repeating: 0, count: Self.reportSize)
        report.replaceSubrange(0..<payload.count, with: payload)

        let result = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                device, kIOHIDReportTypeFeature, Self.reportID,
                buffer.baseAddress!, buffer.count)
        }
        guard result == kIOReturnSuccess else { throw Failure.sendFailed(result) }
    }

    /// Reads one report back.
    func read() throws -> [UInt8] {
        var report = [UInt8](repeating: 0, count: Self.reportSize)
        var length = report.count
        let result = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, Self.reportID, &report, &length)
        guard result == kIOReturnSuccess else { throw Failure.readFailed(result) }
        return report
    }

    /// Sends a command and reads the reply.
    ///
    /// The `settle` pause mirrors what AJAZZ's own driver does between writing
    /// and reading; without it the reply is not ready yet.
    ///
    /// Whether the reply echoes the command byte is **per command**, not a
    /// property of the channel: the identify query `0xf1` answers with `f1 ...`,
    /// while the status query `0xf7` puts a flag byte in position 0. So echo
    /// checking is opt-in, and callers that cannot use it validate the reply
    /// their own way.
    func exchange(
        _ payload: [UInt8], settle: TimeInterval = 0.05, expectingEcho: Bool = false
    ) throws -> [UInt8] {
        try send(payload)
        Thread.sleep(forTimeInterval: settle)
        let reply = try read()

        guard expectingEcho, let command = payload.first else { return reply }
        guard reply.first == command else {
            throw Failure.unexpectedReply(expected: command, got: reply.first ?? 0)
        }
        return reply
    }
}
