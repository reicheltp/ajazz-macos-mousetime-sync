import Foundation

/// The dock's "set date and time" command.
///
/// The dock has no battery-backed clock. It comes up at `2001-01-01 00:00` and
/// stays there until something tells it the time; the Windows driver does that
/// on connect, and nothing on macOS does. This is that command.
///
/// Layout — a 64-byte HID **feature** report where byte 0 is the report ID and
/// is part of the transferred buffer:
///
/// | Offset | Value          | Meaning                          |
/// |--------|----------------|----------------------------------|
/// | 0      | `0x28`         | report ID                        |
/// | 7      | `0xd7`         | opcode: set date/time            |
/// | 8...9  | big endian     | year (2026 = `0x07ea`)           |
/// | 10     | 1...12         | month                            |
/// | 11     | 1...31         | day                              |
/// | 12     | 0...23         | hour                             |
/// | 13     | 0...59         | minute                           |
/// | 14     | 0...59         | second                           |
/// | rest   | `0x00`         | padding                          |
///
/// A malformed report is ignored silently by the dock — there is no error to go
/// on — so ``ClockReport`` is deliberately pure and covered byte-for-byte by
/// tests. Everything that touches IOKit lives elsewhere.
public enum ClockReport {
    /// HID report ID, also the first transferred byte.
    public static let reportID: UInt8 = 0x28

    /// Total transferred length, including the report ID.
    public static let size = 64

    /// Opcode selecting the set-date/time command.
    static let opcode: UInt8 = 0xd7

    enum Offset {
        static let opcode = 7
        static let yearHigh = 8
        static let yearLow = 9
        static let month = 10
        static let day = 11
        static let hour = 12
        static let minute = 13
        static let second = 14
    }

    /// Builds the report for `date`.
    ///
    /// The dock displays exactly what it is given, so pass a local time — which
    /// is what the default `Calendar.current` produces.
    public static func bytes(for date: Date, calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)

        var report = [UInt8](repeating: 0, count: size)
        report[0] = reportID
        report[Offset.opcode] = opcode

        let year = c.year ?? 0
        report[Offset.yearHigh] = UInt8truncating(year >> 8)
        report[Offset.yearLow] = UInt8truncating(year)
        report[Offset.month] = UInt8truncating(c.month ?? 1)
        report[Offset.day] = UInt8truncating(c.day ?? 1)
        report[Offset.hour] = UInt8truncating(c.hour ?? 0)
        report[Offset.minute] = UInt8truncating(c.minute ?? 0)
        report[Offset.second] = UInt8truncating(c.second ?? 0)
        return report
    }

    /// Truncating conversion. Date components from a valid `Date` always fit,
    /// but a trap here would take down a background daemon over a calendar
    /// edge case, which is a worse outcome than a wrong digit on a display.
    private static func UInt8truncating(_ value: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: value)
    }
}
