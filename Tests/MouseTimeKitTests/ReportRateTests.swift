// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Testing

@testable import MouseTimeKit

/// This is a *write* to the mouse, on the channel that also carries profile and
/// firmware commands. The hardware confirmed it once; these pin the bytes so a
/// refactor cannot quietly change what gets sent.
@Suite("Report rate")
struct ReportRateTests {

    /// A real `0xd3` reply from an AJ159 APEX through its receiver, at 500 Hz.
    static let captured: [UInt8] = [
        0xd3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x02, 0x02, 0x00, 0x00, 0x00, 0x0c, 0x01,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x03, 0x04, 0x07, 0xff, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x05, 0x00, 0x14, 0x00, 0x05, 0x00,
        0x00, 0x00, 0x64, 0x64, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    @Test("rate codes match the vendor's table")
    func codes() {
        #expect(ReportRate.code(forHz: 8000) == 0x81)
        #expect(ReportRate.code(forHz: 1000) == 0x01)
        #expect(ReportRate.code(forHz: 500) == 0x02)
        #expect(ReportRate.code(forHz: 125) == 0x08)
        #expect(ReportRate.code(forHz: 1001) == nil)
        #expect(ReportRate.hz(forCode: 0x03) == nil)  // the other encoding's 1000 Hz
        #expect(ReportRate.supported == [8000, 4000, 2000, 1000, 500, 250, 125])
    }

    @Test("checksum makes bytes 0-7 sum to 0xff")
    func checksum() {
        // Known from the dongle-ID query the driver sends: 8f ... 70.
        #expect(MouseRelay.checksummed([0x8f]) == [0x8f, 0, 0, 0, 0, 0, 0, 0x70, 0])
        #expect(MouseRelay.checksummed([0xd3])[7] == 0x2c)  // what the mouse echoed
    }

    @Test("parses the captured block")
    func parses() throws {
        let block = try MouseOptionBlock(reply: Self.captured)
        #expect(block.rate == 500)
        #expect(block.profile == 0)
    }

    @Test("the write is the vendor's, changing only the rate")
    func write() throws {
        let block = try MouseOptionBlock(reply: Self.captured)
        let out = try #require(block.writing(rate: 1000))

        // Exactly what went to the hardware when this was first confirmed.
        var expected = Self.captured
        expected[0] = 0x53
        expected[7] = 0xac
        expected[9] = 0x01
        expected[17] = 0xff
        expected[18] = 0x08
        #expect(out == expected)
        #expect(out.count == 64)
    }

    @Test("refuses anything that is not a settings block")
    func rejects() {
        var wrongCommand = Self.captured
        wrongCommand[0] = 0xf7
        #expect(throws: MouseOptionBlock.ParseError.self) { try MouseOptionBlock(reply: wrongCommand) }

        var unknownRate = Self.captured
        unknownRate[9] = 0x03
        #expect(throws: MouseOptionBlock.ParseError.self) { try MouseOptionBlock(reply: unknownRate) }

        #expect(throws: MouseOptionBlock.ParseError.self) {
            try MouseOptionBlock(reply: Array(Self.captured.prefix(20)))
        }
    }

    @Test("unsupported rates produce no write")
    func unsupported() throws {
        #expect(try MouseOptionBlock(reply: Self.captured).writing(rate: 1001) == nil)
    }
}
