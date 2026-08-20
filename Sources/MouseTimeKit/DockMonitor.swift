// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation
import IOKit
import IOKit.hid

/// Watches the IO registry for HID interfaces appearing and disappearing.
///
/// Uses `IOServiceAddMatchingNotification` rather than polling: the dock
/// vanishes entirely when the mouse sleeps or the hub is switched to another
/// machine, and comes back with its clock reset, so the *transition* is what
/// matters. Registry notifications are unprivileged, unlike `IOHIDManager`,
/// which opens the devices it matches and therefore trips Input Monitoring.
///
/// All callbacks arrive on the run loop that ``start()`` was called from. The
/// type is `@unchecked Sendable` because its state is only ever touched from
/// that one run loop, while the IOKit callbacks that reach it are C function
/// pointers and thus nonisolated by construction.
public final class DockMonitor: @unchecked Sendable {
    public typealias Handler = (DeviceInfo) -> Void

    /// Why the monitor could not start.
    public enum StartError: Error, CustomStringConvertible {
        case notificationPortUnavailable
        case matchingDictionaryUnavailable
        case registrationFailed(kern_return_t)

        public var description: String {
            switch self {
            case .notificationPortUnavailable:
                return "could not create an IOKit notification port"
            case .matchingDictionaryUnavailable:
                return "could not build an IOHIDDevice matching dictionary"
            case .registrationFailed(let code):
                return String(format: "IOServiceAddMatchingNotification failed (0x%08x)",
                              UInt32(bitPattern: code))
            }
        }
    }

    private let predicate: (DeviceInfo) -> Bool
    private let onAppear: Handler
    private let onDisappear: Handler

    private var notifyPort: IONotificationPortRef?
    private var appearIterator: io_iterator_t = 0
    private var disappearIterator: io_iterator_t = 0

    public init(
        matching predicate: @escaping (DeviceInfo) -> Bool,
        onAppear: @escaping Handler,
        onDisappear: @escaping Handler = { _ in }
    ) {
        self.predicate = predicate
        self.onAppear = onAppear
        self.onDisappear = onDisappear
    }

    deinit { tearDown() }

    /// Registers for notifications on the current run loop.
    ///
    /// Interfaces that are already attached are reported through `onAppear`
    /// before this returns — draining the iterator is both how existing matches
    /// are delivered and how the notification is armed.
    public func start() throws {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw StartError.notificationPortUnavailable
        }
        notifyPort = port

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        try register(kIOFirstMatchNotification, deviceAppeared, context, &appearIterator)
        try register(kIOTerminatedNotification, deviceDisappeared, context, &disappearIterator)

        drain(appearIterator, through: onAppear)
        drain(disappearIterator, through: onDisappear)
    }

    /// Deregisters and releases everything.
    public func stop() { tearDown() }

    private func register(
        _ type: String,
        _ callback: IOServiceMatchingCallback,
        _ context: UnsafeMutableRawPointer,
        _ iterator: inout io_iterator_t
    ) throws {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) else {
            throw StartError.matchingDictionaryUnavailable
        }

        // IOServiceAddMatchingNotification consumes a reference to the matching
        // dictionary, but IOServiceMatching hands Swift an owned one that ARC
        // will also release. The extra retain balances that out; without it the
        // dictionary is over-released.
        let result = IOServiceAddMatchingNotification(
            notifyPort,
            type,
            Unmanaged.passRetained(matching).takeUnretainedValue(),
            callback,
            context,
            &iterator
        )
        guard result == KERN_SUCCESS else {
            throw StartError.registrationFailed(result)
        }
    }

    fileprivate func drain(_ iterator: io_iterator_t, through handler: Handler) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = DockDiscovery.describe(service)
            IOObjectRelease(service)
            if predicate(info) { handler(info) }
        }
    }

    fileprivate var appearHandler: Handler { onAppear }
    fileprivate var disappearHandler: Handler { onDisappear }

    private func tearDown() {
        if appearIterator != 0 {
            IOObjectRelease(appearIterator)
            appearIterator = 0
        }
        if disappearIterator != 0 {
            IOObjectRelease(disappearIterator)
            disappearIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }
}

// Top-level functions rather than closures: they capture nothing, which is what
// lets them convert to the C function pointer IOKit expects.

private func deviceAppeared(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let context else { return }
    let monitor = Unmanaged<DockMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.drain(iterator, through: monitor.appearHandler)
}

private func deviceDisappeared(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let context else { return }
    let monitor = Unmanaged<DockMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.drain(iterator, through: monitor.disappearHandler)
}
