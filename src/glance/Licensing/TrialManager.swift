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
//  The keychain alone can still be cleared, and a second macOS user account has a keychain of its
//  own, so the fulfilment service also keeps one trial start per Mac (by the same hashed hardware
//  fingerprint as activation). Starting a trial needs to reach it once; the service answers with the
//  earliest start that Mac has ever had, so a Mac that already used its day gets an expired trial,
//  not a new one. After that the trial runs offline, and each launch re-syncs when it can.
//
//  Patching the check out of the binary is still possible, as with any client-side trial; that is
//  what the notarized signature and the licence receipt are for, not this.
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

    /// When the trial runs out, or nil when none has started.
    var endsAt: Date? {
        read().map { $0.started.addingTimeInterval(TimeInterval(Self.trialDays) * 86_400) }
    }

    enum StartResult {
        case started
        /// The service says this Mac's trial began earlier and has already run out.
        case alreadyUsed
        case unreachable
    }

    /// Begins the trial if it has never run on this Mac. Needs the service once, so a trial can't be
    /// renewed by clearing local state. Calling this once a trial is under way or finished does
    /// nothing, so it is safe to wire straight to a button.
    func start() async -> StartResult {
        guard case .notStarted = state else { return isActive ? .started : .alreadyUsed }
        guard let serverStart = await Self.syncWithService(started: nil) else { return .unreachable }
        let now = Date()
        write(Record(started: min(serverStart, now), lastSeen: now))
        refresh()
        return isActive ? .started : .alreadyUsed
    }

    /// At launch: brings a running trial's start into line with the service's record, which is the
    /// earliest this Mac has reported. Only ever moves the start earlier. Offline, nothing changes.
    func syncIfNeeded() async {
        guard let record = read(),
              let serverStart = await Self.syncWithService(started: record.started) else { return }
        if serverStart < record.started {
            write(Record(started: serverStart, lastSeen: record.lastSeen))
        }
        refresh()
    }

    static let endpoint = URL(string: "https://macid.net/api/trial")!

    /// POSTs this Mac's fingerprint (and, if known, its local start) and returns the start the
    /// service holds. Nil when the service can't be reached.
    private nonisolated static func syncWithService(started: Date?) async -> Date? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var body: [String: Any] = [
            "machine": Activation.machineFingerprint,
            "app_version": version,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let started { body["started"] = started.timeIntervalSince1970 }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MacID/\(version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = json["started"] as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
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
