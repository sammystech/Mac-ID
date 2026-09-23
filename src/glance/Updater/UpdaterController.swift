//
//  UpdaterController.swift
//  Mac ID
//
//  Thin wrapper around Sparkle's `SPUStandardUpdaterController`.
//  Split into two types because Sparkle's `@objc` delegate protocols need an `NSObject` conformer, which doesn't mix with
//  `@Observable`: `UpdaterController` is what the app touches; `UpdatePresentationDelegate` only relays Sparkle's show/hide callbacks.
//
//  Two things about this app's setup are load-bearing, both learned the hard way:
//
//  1. The feed and the EdDSA public key in Info.plist must be *this* project's, never upstream Glance's.
//     Pointing at someone else's appcast means an "update" replaces this app with a different one.
//  2. Sparkle ships as a prebuilt XCFramework carrying its own signature, and dyld refuses to load an
//     embedded framework whose Team ID doesn't match the host process. Under ad-hoc signing (no Team ID)
//     the app dies in dyld before `main`. It only works because the app is signed with a real identity.
//

import AppKit
import Observation
import Sparkle
import Security

@Observable
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private let presentationDelegate = UpdatePresentationDelegate()

    /// Mirrors `SPUUpdater.canCheckForUpdates` (KVO-only on Sparkle's side, hence the manual observation below).
    private(set) var canCheckForUpdates = false
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    /// Forwards straight to Sparkle rather than keeping a second stored copy — Sparkle already persists this itself under the
    /// same `UserDefaults` suite `AppSettings` uses.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// True when this copy is signed with an Apple Development certificate — the developer's own
    /// build, installed from `release.sh`'s local output rather than from a release.
    ///
    /// Such a build must never update itself. The public feed carries the build made for other
    /// people's Macs, which is signed differently; letting Sparkle install it over the developer's
    /// copy silently swaps the signature, which strands the keychain item holding the stored
    /// password (it belongs to the Development team) and orphans the Accessibility grant. That
    /// happened with 1.7, and from the outside it looked like face unlock had simply broken.
    ///
    /// Decided from the signing certificate, not from the presence of a provisioning profile:
    /// Developer ID releases will carry a profile too, and a profile check would then switch updates
    /// off for every customer.
    static let isDeveloperBuild: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
              let subject = SecCertificateCopySubjectSummary(leaf) as String?
        else { return false }   // ad-hoc (no certificate) or unreadable: a normal, updatable release
        return subject.hasPrefix("Apple Development:")
    }()

    var isDeveloperBuild: Bool { Self.isDeveloperBuild }

    /// True while Sparkle is showing anything, so `AppDelegate.windowWillClose` doesn't drop the Dock icon to `.accessory` mid-update.
    var isPresentingUpdateUI: Bool { presentationDelegate.isPresentingUpdateUI }

    init() {
        // `startingUpdater: false` — `start()` is called explicitly from `AppDelegate.applicationDidFinishLaunching` instead,
        // matching how the rest of `AppEnvironment`'s controllers are wired.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: presentationDelegate
        )

        // Bridges KVO (not Observation-compatible) to the `@Observable` stored property SwiftUI tracks. Hopped through
        // `Task { @MainActor in }` since the KVO closure itself carries no actor isolation the compiler can see.
        canCheckForUpdatesObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { updater, _ in
            // `[weak self]` captured on the Task's closure, not the outer KVO one — Swift 6 flags the latter as unsafe.
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// `SPUStandardUpdaterController` logs and alerts on a misconfigured Sparkle setup itself rather than throwing, so a
    /// placeholder feed URL degrades to "never finds an update" rather than crashing.
    func start() {
        // Not started at all, rather than started with automatic checks off: a manual "Check for
        // Updates" would install the public build just as surely.
        guard !Self.isDeveloperBuild else { return }
        controller.startUpdater()
    }

    /// User-initiated "Check for Updates" — shows Sparkle's standard progress UI.
    func checkForUpdates() {
        guard !Self.isDeveloperBuild else { return }
        controller.checkForUpdates(nil)
    }
}

/// Receives Sparkle's show/hide callbacks to (a) bring the app forward when it's currently `.accessory`/windowless, and
/// (b) expose `isPresentingUpdateUI`. Only the three methods needed here are implemented; the rest of the protocol is optional.
@MainActor
private final class UpdatePresentationDelegate: NSObject, SPUStandardUserDriverDelegate {
    private(set) var isPresentingUpdateUI = false

    /// Fires before any modal alert, including the plain "You're up to date" sheet from a manual check.
    func standardUserDriverWillShowModalAlert() {
        beginPresenting()
    }

    /// Fires before Sparkle shows an actual found-update window, covering the real update path once releases exist.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        beginPresenting()
    }

    /// Fires for every way an update session can end (dismissed, skipped, errored, installed) — the one place to clear the flag.
    func standardUserDriverWillFinishUpdateSession() {
        isPresentingUpdateUI = false
    }

    private func beginPresenting() {
        isPresentingUpdateUI = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
