// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation

/// Silences the receiver interface that emits input nobody asked for.
///
/// The AJ159's second HID interface declares four collections: a consumer array
/// spanning usages `0x0000`–`0x033C`, a keyboard collection taking any keycode
/// with any modifier, a system-control collection that can request sleep or
/// power down, and a vendor page. Because the consumer field is a bare range
/// rather than an enumeration, *any* 16-bit value is a well-formed report — so a
/// corrupted 2.4 GHz packet becomes a real system action or a real keystroke.
///
/// Nothing the user presses depends on that interface: the five buttons, the
/// wheel and horizontal scroll are all on the mouse interface. So the whole
/// thing can be mapped to nothing.
///
/// The mechanism is macOS's own `UserKeyMapping` property, the same one
/// `hidutil` sets and the same one behind every "disable Caps Lock" recipe. It
/// needs no permission and is scoped to one matched service.
///
/// Two known limits, both documented rather than worked around:
///
/// - The mapping is **not persistent**. It is attached to a live HID service, so
///   unplugging the dock or rebooting clears it. ``ClockSyncService`` reapplies
///   it when the interface reappears, which is why suppression rides along with
///   the daemon rather than being a one-shot command.
/// - Whether a usage mapped to zero is *discarded* rather than passed through is
///   not something this code can prove. The mapping is verifiably present in the
///   event system's active filter, which is as far as observation goes without
///   being able to trigger the phantom events on demand.
public enum PhantomInputSuppressor {

    /// A contiguous block of usages to silence on one usage page.
    public struct Block: Sendable, Equatable {
        public let page: Int
        public let usages: ClosedRange<Int>

        public init(page: Int, usages: ClosedRange<Int>) {
            self.page = page
            self.usages = usages
        }
    }

    /// Everything the AJ159's second interface declares it can send.
    ///
    /// Taken from its report descriptor rather than guessed — see
    /// `docs/PROTOCOL.md`. Suppressing the declared ranges rather than a
    /// hand-picked list of "bad" usages is deliberate: the symptoms people
    /// notice (`0x019F` opening System Settings, `0x0221` opening Spotlight)
    /// are just the visible members of a range that is entirely reachable by
    /// a corrupted packet.
    public static let declaredRanges: [Block] = [
        // Consumer Control, report ID 3: Usage Minimum 0x0000, Maximum 0x033C.
        Block(page: HIDUsage.consumerPage, usages: 0x0000...0x033c),
        // Keyboard, report ID 7: modifiers 0xE0-0xE7 plus six keycodes, with
        // Usage Minimum 0x00 and Maximum 0xFF.
        Block(page: HIDUsage.keyboardPage, usages: 0x0000...0x00ff),
        // System Control, report ID 2: power down, sleep, wake.
        Block(page: HIDUsage.genericDesktopPage, usages: 0x0081...0x0083),
    ]

    /// Total number of usages ``declaredRanges`` covers.
    public static var declaredUsageCount: Int {
        declaredRanges.reduce(0) { $0 + $1.usages.count }
    }

    public enum Failure: Error, CustomStringConvertible {
        case hidutilFailed(status: Int32, output: String)
        case notApplied(expected: Int, actual: Int)

        public var description: String {
            switch self {
            case .hidutilFailed(let status, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return "hidutil exited \(status)"
                    + (detail.isEmpty ? "" : ": \(detail)")
            case .notApplied(let expected, let actual):
                return "mapping did not take: expected \(expected) entries, found \(actual)"
            }
        }
    }

    /// A `UserKeyMapping` value mapping every usage in `blocks` to nothing.
    ///
    /// The source encoding is a 64-bit integer: usage page in the high 32 bits,
    /// usage in the low 32. A destination of zero is the idiom for "drop it".
    public static func mapping(for blocks: [Block] = declaredRanges) -> String {
        var entries: [String] = []
        entries.reserveCapacity(declaredUsageCount)
        for block in blocks {
            let base = UInt64(block.page) << 32
            for usage in block.usages {
                entries.append(
                    #"{"HIDKeyboardModifierMappingSrc":\#(base | UInt64(usage)),"#
                        + #""HIDKeyboardModifierMappingDst":0}"#
                )
            }
        }
        return #"{"UserKeyMapping":[\#(entries.joined(separator: ","))]}"#
    }

    /// hidutil's matching dictionary for one interface.
    ///
    /// Matches on primary usage as well as the IDs, because a receiver publishes
    /// several interfaces under the same vendor and product ID and only one of
    /// them may be touched.
    static func matching(_ device: DeviceInfo) -> String {
        #"{"VendorID":\#(device.vendorID),"ProductID":\#(device.productID),"#
            + #""PrimaryUsagePage":\#(device.primaryUsagePage),"#
            + #""PrimaryUsage":\#(device.primaryUsage)}"#
    }

    /// Silences `device`, then reads the mapping back to confirm it took.
    ///
    /// - Returns: the number of usages now mapped to nothing.
    @discardableResult
    public static func apply(
        to device: DeviceInfo, blocks: [Block] = declaredRanges
    ) throws -> Int {
        _ = try hidutil(["property", "--matching", matching(device), "--set", mapping(for: blocks)])

        let expected = blocks.reduce(0) { $0 + $1.usages.count }
        let actual = try appliedCount(for: device)
        guard actual == expected else {
            throw Failure.notApplied(expected: expected, actual: actual)
        }
        return actual
    }

    /// Removes any mapping from `device`, restoring its normal behaviour.
    public static func clear(from device: DeviceInfo) throws {
        _ = try hidutil([
            "property", "--matching", matching(device), "--set", #"{"UserKeyMapping":[]}"#,
        ])
    }

    /// How many usages are currently mapped on `device`.
    public static func appliedCount(for device: DeviceInfo) throws -> Int {
        let output = try hidutil([
            "property", "--matching", matching(device), "--get", "UserKeyMapping",
        ])
        // hidutil prints the property as a plist-ish blob; counting the source
        // keys is more robust than trying to parse its formatting.
        return output.components(separatedBy: "HIDKeyboardModifierMappingSrc").count - 1
    }

    private static func hidutil(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting: a large mapping produces enough output to fill
        // the pipe buffer, and waiting first would deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure.hidutilFailed(status: process.terminationStatus, output: output)
        }
        return output
    }
}
