//
//  TrialManager.swift
//  Mac ID
//
//  A 1-day free trial, so someone can confirm face unlock actually works on their hardware before
//  paying for it.
//
//  The trial record lives in the keychain rather than `UserDefaults` for one reason: keychain items
//  survive deleting the app, so uninstalling and reinstalling does not hand out a fresh trial.
//  Preferences do not survive that, which would make the trial effectively unlimited.
//
//  This is deliberately honest about what it is: a speed bump, not DRM. Anyone determined can clear
//  the keychain item or patch the check out of a binary they already have on disk — that is true of
//  every client-side trial, and pretending otherwise would mean spending real complexity for no real
//  protection. It stops casual reuse, which is all it is meant to do.
//

import Foundation
import Observation

@Observable
@MainActor
final class TrialManager {
    static let shared = TrialManager()

    /// The trial length, in days.
    static let trialDays = 1

    enum State: Equatable {
        case notStarted
        case active(daysRemaining: Int)
        case expired
    }

    private(set) var state: State = .notStarted

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    /// Days left, rounded up so the last partial day still reads as "1 day left" rather than "0".
    var daysRemaining: Int {
        if case .active(let days) = state { return days }
        return 0
    }

    private static let account = "trial-period"

    /// `lastSeen` exists only to catch the clock being wound back. Without it, setting the system
    /// date to last week would refresh the trial indefinitely.
    private struct Record: Codable {
        var started: Date
        var lastSeen: Date
    }

    private init() {
        refresh()
    }

    /// Begins the trial if it has never run. Calling this once a trial is under way or finished does
    /// nothing, so it is safe to wire straight to a button.
    func start() {
        guard case .notStarted = state else { return }
        let now = Date()
        write(Record(started: now, lastSeen: now))
        refresh()
    }

    /// Recomputes `state` from the stored record. Cheap; call it whenever the trial's remaining time
    /// is about to be shown.
    func refresh() {
        guard let record = read() else {
            state = .notStarted
            return
        }

        let now = Date()
        // A clock earlier than the last run means the date was moved backwards. Treat that as the
        // trial being over rather than silently granting more time. A few minutes of slack absorbs
        // ordinary NTP corrections, which routinely step the clock a little in either direction.
        if now < record.lastSeen.addingTimeInterval(-300) {
            state = .expired
            return
        }

        // Advance the high-water mark so a later rollback is still caught.
        if now > record.lastSeen {
            write(Record(started: record.started, lastSeen: now))
        }

        let elapsed = now.timeIntervalSince(record.started)
        let total = TimeInterval(Self.trialDays) * 86_400
        if elapsed >= total {
            state = .expired
        } else {
            state = .active(daysRemaining: max(1, Int(ceil((total - elapsed) / 86_400))))
        }
    }

    // MARK: - Storage

    private func read() -> Record? {
        guard let data = try? KeychainManager.read(account: Self.account) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func write(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        // A failure here is not worth interrupting the user for: the worst case is the trial state
        // not persisting, which `refresh()` reads back as `.notStarted` on the next launch.
        try? KeychainManager.save(account: Self.account, data: data)
    }
}
