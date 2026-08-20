// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import IOKit
import IOKit.hid

/// One HID interface, as described by the IO registry.
///
/// A single AJAZZ receiver publishes several interfaces: a mouse, one or more
/// keyboard/consumer interfaces, and a vendor-defined one that carries the
/// control protocol. They are separate `IOHIDDevice` services and have to be
/// told apart, because the clock command only works on the last one and the
/// others must not be disturbed.
public struct DeviceInfo: Sendable, Hashable, CustomStringConvertible {
    public let registryID: UInt64
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let manufacturer: String
    public let serial: String
    public let primaryUsagePage: Int
    public let primaryUsage: Int
    public let transport: String
    public let locationID: Int

    /// AJAZZ's USB vendor ID.
    public static let ajazzVendorID = 0x249a

    /// Whether this is AJAZZ hardware.
    ///
    /// The vendor ID alone is not enough — some units ship under a white-label
    /// ID — so the descriptive strings are checked too.
    public var isAjazz: Bool {
        if vendorID == Self.ajazzVendorID { return true }
        return "\(manufacturer) \(product)".localizedCaseInsensitiveContains("ajazz")
    }

    /// Whether this is the 2.4 GHz receiver dock, the part with the display.
    ///
    /// The dock identifies itself with a product string like `AJAZZ 2.4G 8K`.
    /// Product IDs differ per model and per firmware revision, so they are
    /// never matched on; the `2.4G` marker is what separates the dock from the
    /// mouse's own wired interface.
    public var isDock: Bool {
        isAjazz && product.localizedCaseInsensitiveContains("2.4g")
    }

    /// Whether this interface is a plain input device — a mouse, a keyboard, or
    /// a consumer-control endpoint.
    ///
    /// These are the interfaces macOS protects behind the Input Monitoring
    /// permission, and the ones whose behaviour users notice. The clock command
    /// never needs them.
    public var isStandardInputDevice: Bool {
        switch primaryUsagePage {
        case HIDUsage.genericDesktopPage:
            return [
                HIDUsage.pointerUsage, HIDUsage.mouseUsage,
                HIDUsage.keyboardUsage, HIDUsage.keypadUsage,
            ].contains(primaryUsage)
        case HIDUsage.keyboardPage, HIDUsage.consumerPage:
            return true
        default:
            return false
        }
    }

    /// Whether this interface is a pointing device — the one thing on an AJAZZ
    /// receiver that must never be interfered with.
    public var isPointingDevice: Bool {
        primaryUsagePage == HIDUsage.genericDesktopPage
            && [HIDUsage.pointerUsage, HIDUsage.mouseUsage].contains(primaryUsage)
    }

    /// Whether this is the receiver interface that emits phantom input: an
    /// AJAZZ input interface that is not the mouse.
    ///
    /// On the AJ159 that is the interface whose primary usage is Consumer, and
    /// whose descriptor also declares a keyboard collection and a system-control
    /// collection. Everything the user actually presses lives on the pointing
    /// device, so this one has no legitimate traffic — see
    /// ``PhantomInputSuppressor``.
    public var isPhantomInputCandidate: Bool {
        isAjazz && isStandardInputDevice && !isPointingDevice
    }

    /// Whether this interface is a plausible carrier for the control protocol:
    /// AJAZZ hardware that is not a standard input device.
    ///
    /// Matching this narrowly is what keeps the clock sync out of TCC's way —
    /// a vendor-defined HID interface is not a protected input device, so
    /// talking to it needs no permission at all.
    public var isControlInterface: Bool {
        isAjazz && !isStandardInputDevice
    }

    public var description: String {
        String(
            format: "%04x:%04x %@ %@ %@",
            vendorID, productID,
            HIDUsage.name(page: primaryUsagePage, usage: primaryUsage),
            product.isEmpty ? "(no product string)" : "\"\(product)\"",
            transport.isEmpty ? "" : "[\(transport)]"
        ).trimmingCharacters(in: .whitespaces)
    }
}

/// Finds HID interfaces by reading the IO registry.
///
/// Deliberately does not use `IOHIDManager`: opening a manager that matches
/// every device also opens keyboards, which trips the Input Monitoring
/// permission check. Reading registry properties is unprivileged, so
/// enumeration and filtering happen here and only the interface we actually
/// need is ever opened.
public enum DockDiscovery {
    /// Visits every `IOHIDDevice` in the registry, handing the caller both the
    /// live service handle and its decoded properties. Return `false` from
    /// `body` to stop early. Service handles are released on the way out.
    static func forEachService(_ body: (io_service_t, DeviceInfo) -> Bool) {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) else { return }

        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes the matching dictionary.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = describe(service)
            let keepGoing = body(service, info)
            IOObjectRelease(service)
            if !keepGoing { return }
        }
    }

    /// All interfaces accepted by `predicate`, in registry order.
    public static func interfaces(
        where predicate: (DeviceInfo) -> Bool = { _ in true }
    ) -> [DeviceInfo] {
        var found: [DeviceInfo] = []
        forEachService { _, info in
            if predicate(info) { found.append(info) }
            return true
        }
        return found
    }

    static func describe(_ service: io_service_t) -> DeviceInfo {
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)

        return DeviceInfo(
            registryID: registryID,
            vendorID: intProperty(service, kIOHIDVendorIDKey) ?? 0,
            productID: intProperty(service, kIOHIDProductIDKey) ?? 0,
            product: stringProperty(service, kIOHIDProductKey) ?? "",
            manufacturer: stringProperty(service, kIOHIDManufacturerKey) ?? "",
            serial: stringProperty(service, kIOHIDSerialNumberKey) ?? "",
            primaryUsagePage: intProperty(service, kIOHIDPrimaryUsagePageKey) ?? 0,
            primaryUsage: intProperty(service, kIOHIDPrimaryUsageKey) ?? 0,
            transport: stringProperty(service, kIOHIDTransportKey) ?? "",
            locationID: intProperty(service, kIOHIDLocationIDKey) ?? 0
        )
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        property(service, key) as? String
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
    }
}
