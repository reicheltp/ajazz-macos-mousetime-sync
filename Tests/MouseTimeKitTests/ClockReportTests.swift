// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import Testing

@testable import MouseTimeKit

/// The dock ignores a malformed report without complaining, so a regression in
/// the byte layout would present as "the clock just stopped working" with no
/// error anywhere. These tests are the only thing standing in for hardware.
@Suite("Clock report wire format")
struct ClockReportTests {

    /// Builds a fixed local date, independent of the machine's time zone, so
    /// the expected bytes are stable.
    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
    ) -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return (calendar.date(from: components)!, calendar)
    }

    @Test("every byte of a known timestamp")
    func knownTimestamp() {
        let (moment, calendar) = date(2026, 8, 20, 14, 37, 9)
        let report = ClockReport.bytes(for: moment, calendar: calendar)

        #expect(report.count == 64)

        // 2026 == 0x07ea
        let expected: [Int: UInt8] = [
            0: 0x28,  // report ID
            7: 0xd7,  // set date/time
            8: 0x07, 9: 0xea,  // year, big endian
            10: 8,  // month
            11: 20,  // day
            12: 14,  // hour
            13: 37,  // minute
            14: 9,  // second
        ]

        for (offset, want) in expected {
            #expect(report[offset] == want, "byte \(offset)")
        }

        for (offset, byte) in report.enumerated() where expected[offset] == nil {
            #expect(byte == 0, "byte \(offset) should be padding")
        }
    }

    @Test("midnight in January — zero-based vs one-based fields")
    func midnightJanuary() {
        // The dock's own reset value. Hour, minute and second are zero-based;
        // month and day are one-based. Mixing those up is the easy mistake.
        let (moment, calendar) = date(2001, 1, 1, 0, 0, 0)
        let report = ClockReport.bytes(for: moment, calendar: calendar)

        #expect(report[ClockReport.Offset.month] == 1)
        #expect(report[ClockReport.Offset.day] == 1)
        #expect(report[ClockReport.Offset.hour] == 0)
        #expect(report[ClockReport.Offset.minute] == 0)
        #expect(report[ClockReport.Offset.second] == 0)
        // 2001 == 0x07d1
        #expect(report[ClockReport.Offset.yearHigh] == 0x07)
        #expect(report[ClockReport.Offset.yearLow] == 0xd1)
    }

    @Test("December 31st, 23:59:59 — the upper end of every field")
    func endOfYear() {
        let (moment, calendar) = date(2026, 12, 31, 23, 59, 59)
        let report = ClockReport.bytes(for: moment, calendar: calendar)

        #expect(report[ClockReport.Offset.month] == 12)
        #expect(report[ClockReport.Offset.day] == 31)
        #expect(report[ClockReport.Offset.hour] == 23)
        #expect(report[ClockReport.Offset.minute] == 59)
        #expect(report[ClockReport.Offset.second] == 59)
    }

    @Test("the report ID is both the ID and the first transferred byte")
    func reportIDIsInBuffer() {
        let report = ClockReport.bytes(for: Date())
        #expect(report[0] == ClockReport.reportID)
        #expect(ClockReport.reportID == 0x28)
    }

    @Test("uses local time, not UTC")
    func usesLocalTime() {
        // 12:00 Berlin in August is 10:00 UTC. The dock shows what it is given,
        // so the report must carry 12, not 10.
        let (moment, calendar) = date(2026, 8, 20, 12, 0, 0)
        let report = ClockReport.bytes(for: moment, calendar: calendar)
        #expect(report[ClockReport.Offset.hour] == 12)
    }
}
