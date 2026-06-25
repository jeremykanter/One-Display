//
//  LidMonitor.swift
//  One Display
//
//  Detects when the MacBook lid is closed (clamshell) so the app can override
//  macOS's default "stay awake on the external" behavior and sleep instead.
//
//  Detection reads `AppleClamshellState` from the IOPMrootDomain IORegistry
//  entry and watches its general-interest notifications. We fire only on the
//  open→closed transition, so waking the machine while the lid is still closed
//  does not immediately re-sleep it.
//

import Foundation
import IOKit

/// C-compatible callback (captures nothing; the monitor is passed via `refcon`).
private nonisolated func lidInterestCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            monitor.evaluate()
        }
    }
}

@MainActor
final class LidMonitor {

    /// Called once each time the lid transitions from open to closed.
    var onLidClosed: (() -> Void)?

    private var rootDomain: io_service_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var lastClosed = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return }

        // Seed the current state so we don't fire on launch if already closed.
        lastClosed = isLidClosed()

        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notificationPort else { return }
        IONotificationPortSetDispatchQueue(notificationPort, .main)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(notificationPort, rootDomain,
                                         kIOGeneralInterest, lidInterestCallback,
                                         ctx, &notifier)
    }

    /// Re-read the clamshell state and fire `onLidClosed` on an open→closed edge.
    func evaluate() {
        let closed = isLidClosed()
        defer { lastClosed = closed }
        if closed && !lastClosed {
            onLidClosed?()
        }
    }

    /// `true` when the lid is shut. Desktops (no clamshell) report `false`.
    func isLidClosed() -> Bool {
        guard rootDomain != 0 else { return false }
        guard let prop = IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return false }
        return (prop.takeRetainedValue() as? Bool) ?? false
    }

    deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
    }
}
