// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import Testing

@testable import MouseTimeKit

/// A nearly empty battery cannot be produced on demand, so this logic can never
/// be checked against the hardware the way the clock was. These tests are the
/// only thing standing between "warns correctly" and "warns at 3 a.m. forever".
@Suite("Low battery warnings")
struct BatteryAlarmTests {

    @Test("warns once per threshold on the way down")
    func warnsOncePerThreshold() {
        var alarm = BatteryAlarm()

        #expect(alarm.evaluate(percent: 100) == nil)
        #expect(alarm.evaluate(percent: 21) == nil)
        #expect(alarm.evaluate(percent: 20) == 20)
        #expect(alarm.evaluate(percent: 20) == nil)  // no repeat
        #expect(alarm.evaluate(percent: 15) == nil)  // still in the 20 bucket
        #expect(alarm.evaluate(percent: 10) == 10)
        #expect(alarm.evaluate(percent: 8) == nil)
        #expect(alarm.evaluate(percent: 5) == 5)
        #expect(alarm.evaluate(percent: 1) == nil)  // nothing lower to warn about
    }

    @Test("a sudden drop reports the lowest threshold crossed, not the first")
    func reportsLowestCrossed() {
        // Readings arrive minutes apart, so the charge can fall past several
        // thresholds between two of them. Warning "20%" when it is actually at
        // 4% would understate the problem.
        var alarm = BatteryAlarm()
        #expect(alarm.evaluate(percent: 4) == 5)
    }

    @Test("charging resets it, so the next discharge warns again")
    func resetsWhenCharging() {
        var alarm = BatteryAlarm()
        #expect(alarm.evaluate(percent: 9) == 10)
        #expect(alarm.evaluate(percent: 100) == nil)  // docked
        #expect(alarm.evaluate(percent: 9) == 10)  // and again next cycle
    }

    @Test("a reading hovering on a boundary does not nag")
    func hysteresisPreventsNagging() {
        // A battery reporting 10, 11, 10, 12 is one low battery, not four
        // events. Nothing re-arms until it is genuinely charged: recovering a
        // few points while still under 20% is the same discharge cycle.
        var alarm = BatteryAlarm(thresholds: [20, 10, 5], hysteresis: 3)
        #expect(alarm.evaluate(percent: 10) == 10)
        for percent in [11, 10, 12, 13, 9, 10, 19] {
            #expect(alarm.evaluate(percent: percent) == nil, "\(percent)%")
        }
        // Clear of 20 + 3, so the next discharge is a new cycle.
        #expect(alarm.evaluate(percent: 23) == nil)
        #expect(alarm.evaluate(percent: 10) == 10)
    }

    @Test("thresholds are ordered regardless of how they were given")
    func ordersThresholds() {
        var alarm = BatteryAlarm(thresholds: [5, 20, 10])
        #expect(alarm.thresholds == [20, 10, 5])
        #expect(alarm.evaluate(percent: 4) == 5)
    }

    @Test("reset makes a reconnected low device warn once more")
    func explicitReset() {
        var alarm = BatteryAlarm()
        #expect(alarm.evaluate(percent: 5) == 5)
        #expect(alarm.evaluate(percent: 5) == nil)
        alarm.reset()
        #expect(alarm.evaluate(percent: 5) == 5)
    }

    @Test("full charge leaves it silent")
    func silentWhenFull() {
        var alarm = BatteryAlarm()
        for percent in [100, 90, 50, 25, 21] {
            #expect(alarm.evaluate(percent: percent) == nil, "\(percent)%")
        }
        #expect(alarm.lastWarned == nil)
    }
}

@Suite("Status reply parsing")
struct DeviceStatusTests {

    @Test("parses a real reply from the hardware")
    func parsesRealReply() {
        // Captured from an AJ159 dock with the mouse charging on it, after
        // selecting the mouse with f6 05.
        let status = DeviceStatus(reply: [0x00, 0x00, 0x64, 0x01, 0x00, 0x00, 0x02, 0x00])

        #expect(status.mouseBattery == 100)
        #expect(status.mouseOnline)
        #expect(!status.keyboardOnline)  // byte 3 is 1, and 0 means online
        #expect(status.keyboardBattery == 0)
        #expect(status.hasUsableMouseBattery)
    }

    @Test("the reply before selecting the mouse reports it offline")
    func parsesUnselectedReply() {
        // Same dock, same moment, but without the f6 05 select: byte 4 is 1.
        // The battery number is still there, which is exactly the trap that
        // hasUsableMouseBattery exists to avoid.
        let status = DeviceStatus(reply: [0x00, 0x00, 0x64, 0x01, 0x01, 0x01, 0x02, 0x00])

        #expect(status.mouseBattery == 100)
        #expect(!status.mouseOnline)
        #expect(!status.hasUsableMouseBattery)
    }

    @Test("a zero or out-of-range reading is never usable")
    func rejectsNonsense() {
        #expect(!DeviceStatus(mouseBattery: 0, mouseOnline: true).hasUsableMouseBattery)
        #expect(!DeviceStatus(mouseBattery: 200, mouseOnline: true).hasUsableMouseBattery)
        #expect(!DeviceStatus(mouseBattery: 50, mouseOnline: false).hasUsableMouseBattery)
        #expect(DeviceStatus(mouseBattery: 1, mouseOnline: true).hasUsableMouseBattery)
        #expect(DeviceStatus(mouseBattery: 100, mouseOnline: true).hasUsableMouseBattery)
    }

    @Test("a short or empty reply does not crash")
    func toleratesShortReplies() {
        let empty = DeviceStatus(reply: [])
        #expect(empty.mouseBattery == 0)
        #expect(!empty.hasUsableMouseBattery)
        #expect(!DeviceStatus(reply: [0x00, 0x00]).hasUsableMouseBattery)
    }
}
