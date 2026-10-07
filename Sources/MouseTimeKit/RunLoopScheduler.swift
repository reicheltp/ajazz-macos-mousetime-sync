// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation

/// Runs work on one specific run loop, from any thread.
///
/// Every exchange with the receiver is a multi-step sequence — select the
/// mouse, poll a flag, send, poll again, fetch — and two of them interleaving
/// would hand one caller the other's reply, or worse, put a write where a read
/// was expected. The services here therefore do all of their hardware work on
/// the run loop they were started on, and anything that arrives elsewhere (a
/// wake notification, a delayed retry) is hopped back onto it with this rather
/// than run where it landed.
///
/// In the CLI daemon that run loop is the main one, so this changes nothing
/// there. In the menu bar app it is a dedicated hardware thread, which keeps a
/// slow radio round-trip from freezing the menu.
public struct RunLoopScheduler: @unchecked Sendable {
    // CFRunLoop is documented as thread-safe for adding timers, which is all
    // this does with it; that is what makes the unchecked conformance sound.
    private let runLoop: CFRunLoop

    /// A scheduler for the run loop of the calling thread.
    public static var current: RunLoopScheduler { RunLoopScheduler(runLoop: CFRunLoopGetCurrent()) }

    public init(runLoop: CFRunLoop) {
        self.runLoop = runLoop
    }

    /// Runs `block` on the run loop after `delay` seconds (or as soon as it
    /// next turns, for zero). Returns the timer so it can be cancelled.
    @discardableResult
    public func after(_ delay: TimeInterval, _ block: @escaping @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in block() }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
        return timer
    }

    /// Runs `block` on the run loop every `interval` seconds.
    @discardableResult
    public func every(_ interval: TimeInterval, _ block: @escaping @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
        return timer
    }
}
