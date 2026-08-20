// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import Testing

@testable import MouseTimeKit

/// `DeviceInfo`'s predicates decide which interface gets written to and which
/// gets left alone. Getting `isControlInterface` wrong in the permissive
/// direction means poking at keyboards; getting it wrong in the strict
/// direction means the clock never syncs.
@Suite("Interface classification")
struct DeviceInfoTests {

    private func make(
        vendorID: Int = 0,
        product: String = "",
        manufacturer: String = "",
        usagePage: Int = 0,
        usage: Int = 0
    ) -> DeviceInfo {
        DeviceInfo(
            registryID: 1,
            vendorID: vendorID,
            productID: 0,
            product: product,
            manufacturer: manufacturer,
            serial: "",
            primaryUsagePage: usagePage,
            primaryUsage: usage,
            transport: "USB",
            locationID: 0
        )
    }

    @Test("recognises AJAZZ by vendor ID and by name")
    func recognisesAjazz() {
        #expect(make(vendorID: 0x249a).isAjazz)
        #expect(make(product: "AJAZZ 2.4G 8K").isAjazz)
        #expect(make(manufacturer: "ajazz").isAjazz)
        #expect(!make(vendorID: 0x05ac, product: "Magic Trackpad").isAjazz)
    }

    @Test("the dock is the interface carrying 2.4G in its name")
    func recognisesDock() {
        #expect(make(product: "AJAZZ 2.4G 8K").isDock)
        #expect(make(product: "ajazz 2.4g receiver").isDock)
        // Wired mouse: AJAZZ, but no radio link, so no display to sync.
        #expect(!make(vendorID: 0x249a, product: "AJ159 APEX").isDock)
        // An AJAZZ keyboard must not be mistaken for the dock.
        #expect(!make(product: "AJAZZ AK820MAX").isDock)
    }

    @Test("mouse, keyboard and consumer interfaces count as input devices")
    func identifiesInputDevices() {
        let mouse = make(usagePage: 0x01, usage: 0x02)
        let pointer = make(usagePage: 0x01, usage: 0x01)
        let keyboard = make(usagePage: 0x01, usage: 0x06)
        let keypad = make(usagePage: 0x01, usage: 0x07)
        let consumer = make(usagePage: 0x0c, usage: 0x01)

        for device in [mouse, pointer, keyboard, keypad, consumer] {
            #expect(device.isStandardInputDevice, "\(device)")
        }

        // Vendor-defined page: this is where the control channel lives.
        #expect(!make(usagePage: 0xff00, usage: 0x01).isStandardInputDevice)
    }

    @Test("control interface means AJAZZ and not an input device")
    func identifiesControlInterface() {
        // The one we want to write to.
        #expect(
            make(vendorID: 0x249a, product: "AJAZZ 2.4G 8K", usagePage: 0xff00, usage: 0x01)
                .isControlInterface)

        // AJAZZ, but it is the mouse — never write here.
        #expect(
            !make(vendorID: 0x249a, product: "AJAZZ 2.4G 8K", usagePage: 0x01, usage: 0x02)
                .isControlInterface)

        // AJAZZ, but it is the phantom-input keyboard interface.
        #expect(
            !make(vendorID: 0x249a, product: "AJAZZ 2.4G 8K", usagePage: 0x01, usage: 0x06)
                .isControlInterface)

        // Somebody else's vendor interface: not ours to touch.
        #expect(!make(vendorID: 0x05ac, usagePage: 0xff00, usage: 0x01).isControlInterface)
    }
}

@Suite("HID usage names")
struct HIDUsageTests {

    @Test("names the usages that matter for the phantom-input hunt")
    func namesSuspects() {
        // The prime suspect: macOS turns this into "open System Settings".
        #expect(HIDUsage.name(page: 0x0c, usage: 0x019f) == "Consumer/AL ControlPanel")
        // Legitimate browser back/forward — must stay recognisable so it does
        // not get filtered away by mistake.
        #expect(HIDUsage.name(page: 0x0c, usage: 0x0224) == "Consumer/AC Back")
        #expect(HIDUsage.name(page: 0x0c, usage: 0x0225) == "Consumer/AC Forward")
        #expect(HIDUsage.name(page: 0x09, usage: 4) == "Button/Button4")
        #expect(HIDUsage.name(page: 0x09, usage: 5) == "Button/Button5")
    }

    @Test("decodes keyboard usage ranges")
    func decodesKeyboard() {
        #expect(HIDUsage.keyName(0x04) == "a")
        #expect(HIDUsage.keyName(0x1d) == "z")
        #expect(HIDUsage.keyName(0x1e) == "1")
        #expect(HIDUsage.keyName(0x26) == "9")
        #expect(HIDUsage.keyName(0x27) == "0")
        #expect(HIDUsage.keyName(0x3a) == "F1")
        #expect(HIDUsage.keyName(0x45) == "F12")
        #expect(HIDUsage.keyName(0x68) == "F13")
        #expect(HIDUsage.keyName(0xe3) == "LeftCmd")
    }

    @Test("vendor pages are labelled, not silently swallowed")
    func labelsVendorPages() {
        #expect(HIDUsage.pageName(0xff00) == "Vendor(0xff00)")
        #expect(HIDUsage.name(page: 0xff00, usage: 0x01) == "Vendor(0xff00)/0x0001")
        #expect(HIDUsage.pageName(0x01) == "GenericDesktop")
    }
}
