//
//  LegacyMigration.swift
//  Mac ID
//
//  One-time move from the app's previous identity, `com.samuelmittman.macid`, to this one.
//
//  The bundle ID changed because the old one was held by a free personal team and Apple would not let
//  the paid team register it. Everything macOS keys by bundle ID started empty as a result: settings,
//  the licence, keychain items, privacy permissions, login item. This carries over what can safely be
//  carried and deliberately leaves the rest:
//
//  * Carried: the licence key and every preference, so nobody is asked to re-activate or re-tune.
//  * Not carried: the stored password and face data. They are encrypted under a key that lives in the
//    previous identity's keychain group, which this build cannot read — so onboarding progress and the
//    security notice are left behind too, and setup runs once more instead of leaving the app looking
//    configured while it has no password to type.
//  * Not carried: the session-key protection flag (it describes a key that doesn't exist here) and
//    Sparkle's bookkeeping, apart from the user's automatic-update choice.
//
//  Runs from the first access to `AppSettings.shared` / `LicenseManager.shared`, because both read their
//  values once, at init. Later would be too late to matter.
//

import AppKit
import Foundation
import os

nonisolated enum LegacyMigration {
    static let legacyBundleID = "com.samuelmittman.macid"

    private static let doneKey = "MacID.migratedFromLegacyBundleID"
    private static let excluded: Set<String> = [
        "GlanceSettings.hasCompletedOnboarding",
        "GlanceSettings.onboardingResumeStep",
        "GlanceSettings.hasAcknowledgedSecurityNotice",
    ]
    private static let carriedExact: Set<String> = ["SUEnableAutomaticChecks"]
    private static let log = Logger(subsystem: "com.samuelmittman.macid", category: "migration")

    /// True for the launch that performed the move, so it can finish the parts that need AppKit.
    private(set) static var didMigrate = false

    /// Swift runs a `static let` initializer exactly once, thread-safely — which is the whole guarantee
    /// needed here, since two singletons can race to trigger this.
    private static let once: Void = run()

    static func migrateIfNeeded() { _ = once }

    private static func run() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != legacyBundleID, !defaults.bool(forKey: doneKey) else { return }
        // Marked done even when there was nothing to move, so a fresh install never looks again.
        defer { defaults.set(true, forKey: doneKey) }

        let app = legacyBundleID as CFString
        guard let keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else { return }

        var carried = 0
        for key in keys {
            let wanted = (key.hasPrefix("GlanceSettings.") && !excluded.contains(key)) || carriedExact.contains(key)
            // Never overwrite a value this identity already has.
            guard wanted, defaults.object(forKey: key) == nil,
                  let value = CFPreferencesCopyAppValue(key as CFString, app) else { continue }
            defaults.set(value, forKey: key)
            carried += 1
        }
        didMigrate = true
        log.info("carried \(carried, privacy: .public) settings over from \(legacyBundleID, privacy: .public)")
    }

    /// The parts that need a running app. Call once from `applicationDidFinishLaunching`.
    @MainActor
    static func finishLaunch() {
        // An upgrade from the DMG replaces the app's files but not a copy that is already running, and
        // that copy keeps its own face unlock armed. Two copies both typing the password at the lock
        // screen would put the second one into whatever window has focus once the Mac is unlocked.
        for old in NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID) {
            old.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !old.isTerminated { old.forceTerminate() }
            }
        }

        guard didMigrate else { return }
        // The previous identity's login item doesn't carry over, and a face-unlock app that isn't
        // running after a restart simply doesn't work. Anyone who doesn't want it can switch it off in
        // General settings.
        do {
            try LaunchAtLogin.setEnabled(true)
        } catch {
            log.error("couldn't register the login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
