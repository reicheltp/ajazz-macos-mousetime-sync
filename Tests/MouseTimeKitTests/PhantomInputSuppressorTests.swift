// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import Testing

@testable import MouseTimeKit

/// The suppressor writes a mapping that disables a whole HID interface. Getting
/// the source encoding wrong would produce a mapping macOS accepts and ignores —
/// which looks exactly like a mapping that works, since the phantom events it
/// targets are intermittent anyway. Hence tests on the encoding itself.
@Suite("Phantom input suppression")
struct PhantomInputSuppressorTests {

    private func device(page: Int, usage: Int) -> DeviceInfo {
        DeviceInfo(
            registryID: 1, vendorID: 0x3151, productID: 0x5007,
            product: "AJAZZ 2.4G 8K", manufacturer: "", serial: "",
            primaryUsagePage: page, primaryUsage: usage,
            transport: "USB", locationID: 0x143300
        )
    }

    @Test("covers exactly what the AJ159 descriptor declares")
    func coversDeclaredRanges() {
        // Consumer 0x0000-0x033C is 829 usages, keyboard 0x00-0xFF is 256, and
        // System Control 0x81-0x83 is 3.
        #expect(PhantomInputSuppressor.declaredUsageCount == 829 + 256 + 3)
        #expect(PhantomInputSuppressor.declaredUsageCount == 1088)
    }

    @Test("encodes the source as page in the high 32 bits, usage in the low")
    func encodesSource() {
        let json = PhantomInputSuppressor.mapping(for: [
            .init(page: 0x0c, usages: 0x019f...0x019f)
        ])
        // 0x0C << 32 | 0x019F == 51539607967
        #expect(json.contains("\"HIDKeyboardModifierMappingSrc\":51539607967"))
        #expect(json.contains("\"HIDKeyboardModifierMappingDst\":0"))
        #expect(json.hasPrefix("{\"UserKeyMapping\":["))
        #expect(json.hasSuffix("]}"))
    }

    @Test("the usages behind the visible symptoms are all in there")
    func includesKnownOffenders() {
        let json = PhantomInputSuppressor.mapping()
        let offenders: [(String, Int, Int)] = [
            ("AL ControlPanel", 0x0c, 0x019f),  // opens System Settings
            ("VolumeUp", 0x0c, 0x00e9),  // Option+volume opens the Sound pane
            ("AC Search", 0x0c, 0x0221),  // opens Spotlight
            ("keyboard a", 0x07, 0x04),  // a stray keystroke
            ("LeftCmd", 0x07, 0xe3),  // a stray modifier
            ("SystemSleep", 0x01, 0x82),  // sleeps the machine
        ]
        for (name, page, usage) in offenders {
            let src = UInt64(page) << 32 | UInt64(usage)
            #expect(
                json.contains("\"HIDKeyboardModifierMappingSrc\":\(src)"),
                "\(name) (\(String(format: "0x%02x/0x%04x", page, usage))) should be suppressed")
        }
    }

    @Test("nothing on the button page is touched")
    func leavesMouseButtonsAlone() {
        // Browser back and forward are buttons 4 and 5 on the mouse interface.
        // A mapping that reached the Button page would break them.
        let json = PhantomInputSuppressor.mapping()
        for button in 1...5 {
            let src = UInt64(HIDUsage.buttonPage) << 32 | UInt64(button)
            #expect(!json.contains("\"HIDKeyboardModifierMappingSrc\":\(src)"))
        }
    }

    @Test("matching pins one interface, not the whole receiver")
    func matchingIsSpecific() {
        let json = PhantomInputSuppressor.matching(device(page: 0x0c, usage: 0x01))
        // Without the usage keys this would also match the mouse, which shares
        // the vendor and product ID.
        #expect(json.contains("\"PrimaryUsagePage\":12"))
        #expect(json.contains("\"PrimaryUsage\":1"))
        #expect(json.contains("\"VendorID\":12625"))
        #expect(json.contains("\"ProductID\":20487"))
    }
}

@Suite("Which interface gets suppressed")
struct PhantomInputCandidateTests {

    private func make(
        vendorID: Int = 0x3151, product: String = "AJAZZ 2.4G 8K",
        page: Int, usage: Int
    ) -> DeviceInfo {
        DeviceInfo(
            registryID: 1, vendorID: vendorID, productID: 0x5007,
            product: product, manufacturer: "", serial: "",
            primaryUsagePage: page, primaryUsage: usage,
            transport: "USB", locationID: 0
        )
    }

    @Test("the consumer interface is the target")
    func targetsConsumer() {
        #expect(make(page: 0x0c, usage: 0x01).isPhantomInputCandidate)
    }

    @Test("the mouse is never a target")
    func sparesPointingDevices() {
        let mouse = make(page: 0x01, usage: 0x02)
        let pointer = make(page: 0x01, usage: 0x01)
        #expect(mouse.isPointingDevice)
        #expect(pointer.isPointingDevice)
        #expect(!mouse.isPhantomInputCandidate)
        #expect(!pointer.isPhantomInputCandidate)
    }

    @Test("the control channel is never a target")
    func sparesControlInterface() {
        // Suppressing this would break the clock, which is the whole point of
        // the program.
        let control = make(page: 0xffff, usage: 0x02)
        #expect(control.isControlInterface)
        #expect(!control.isPhantomInputCandidate)
    }

    @Test("other vendors' devices are never touched")
    func sparesOtherVendors() {
        // A wireless keyboard next to it must not be caught by this.
        let cidoo = make(vendorID: 0x320f, product: "CIDOO V87", page: 0x01, usage: 0x06)
        #expect(!cidoo.isPhantomInputCandidate)
    }

    @Test("a real keyboard interface on an AJAZZ receiver would also count")
    func catchesKeyboardPrimary() {
        // The AJ159 exposes its keyboard collection behind a consumer primary
        // usage, but another model might make it primary instead.
        #expect(make(page: 0x01, usage: 0x06).isPhantomInputCandidate)
    }
}
