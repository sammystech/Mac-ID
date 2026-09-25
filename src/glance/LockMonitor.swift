//
//  LockMonitor.swift
//  glance
//
//  Detects macOS lock/unlock state for the CGEvent injection POC.
//

import Foundation
import AppKit
import CoreGraphics
import Observation

/// Which signal most recently fired — `withObservationTracking`'s `onChange` doesn't say which property changed, so observers
/// read this alongside the monotonic `eventCount` to tell events apart.
enum LockEventKind {
    case screenLocked
    case screenUnlocked
    case willSleep
    /// Display turned back on, from system sleep, display sleep, or the screensaver stopping.
    case wake
    /// Another macOS account took over the screen (fast user switching), or this one came back.
    /// Only ever a reason to stand down or re-check — never a trigger to scan.
    case sessionResigned
    case sessionActivated
}

@Observable
final class LockMonitor {
    /// NOT trustworthy alone: any same-user process can post these distributed notifications, and this process can be
    /// suspended before one is delivered (e.g. lid-close sleep racing a lock). UI/trigger signal only, never a security gate.
    private(set) var isScreenLocked: Bool = false

    /// Catches the case above: lock may have already happened while suspended, so wake is the first chance to notice — callers
    /// should re-derive lock state via `isScreenActuallyLocked()` on change rather than trust `isScreenLocked`.
    private(set) var wakeEventCount: Int = 0

    /// True from `willSleepNotification` until the next wake. `screenIsLocked` fires ~150ms before the system actually finishes
    /// suspending (measured via pmset/os_log correlation), so callers should skip acting on a lock while this is true and wait
    /// for the wake trigger instead.
    private(set) var isSleeping: Bool = false

    /// Observers track `eventCount` (changes on every event, even repeats of the same kind) then read `lastEvent`.
    private(set) var lastEvent: LockEventKind?
    private(set) var eventCount: Int = 0

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        startMonitoring()
    }

    deinit {
        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributed.removeObserver(observer)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
    }

    private func startMonitoring() {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenLocked = true
            self?.record(.screenLocked)
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenLocked = false
            self?.record(.screenUnlocked)
        })
        // Observing the key press that dismissed the screensaver isn't possible — Secure Event Input suppresses keyboard taps
        // on the lock screen regardless of Accessibility trust — so this notification stands in for it.
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.wake)
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSleeping = true
            self?.record(.willSleep)
        })
        // Display- and system-level wake are treated as equivalent triggers — they land within ~100ms of each other in either order.
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordWake()
        })
        // With two accounts logged in, both copies of Mac ID keep running and the one in the background
        // still sees its own session as locked. These make it stand down the instant another account
        // takes the screen, instead of lighting the camera over someone else's session.
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.sessionResigned)
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.sessionActivated)
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordWake()
        })
    }

    private func recordWake() {
        isSleeping = false
        wakeEventCount += 1
        record(.wake)
    }

    private func record(_ kind: LockEventKind) {
        lastEvent = kind
        eventCount += 1
    }

    /// Authoritative lock state from the CoreGraphics session server, not a spoofable notification. Fails closed if unavailable.
    ///
    /// "Locked" here means *this account's* lock screen is what's on the display. A session that another
    /// account has switched away from also reports itself locked, but it isn't on the console: nothing
    /// typed from it can reach the screen, and scanning from it would take the camera from whoever is
    /// actually there. So an off-console session reads as not locked, which stands every caller down.
    nonisolated static func isScreenActuallyLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        // `kCGSessionOnConsoleKey` is a C macro, so Swift can't see it; this is its value. Only an
        // explicit "not on console" stands down: if a future macOS dropped the key, face unlock should
        // keep working as before rather than stop everywhere.
        guard (dict["kCGSSessionOnConsoleKey"] as? Bool) ?? true else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
