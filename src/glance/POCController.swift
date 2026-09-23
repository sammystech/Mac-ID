//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import AppKit
import os
import Observation

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "Idle"

    /// Every `return false` below is a silent failure from the user's side — the face matched and
    /// then nothing happened. Logged so a refusal can be read back rather than reproduced.
    private static let injectionLog = Logger(subsystem: "com.samuelmittman.macid", category: "timing")

    func refreshAccessibilityStatus() {
        let trusted = KeystrokeInjector.isAccessibilityTrusted()
        if trusted != accessibilityGranted { accessibilityGranted = trusted }
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    /// The one-click fix every "Accessibility is off" warning routes to.
    ///
    /// Two steps, because either alone can leave someone stuck. The prompt call is what puts Mac ID
    /// back into the System Settings list — after `tccutil reset`, or a re-signed build, the app
    /// isn't listed at all, so there is no switch to find. But macOS shows that prompt's dialog
    /// only sparingly, so the pane is opened directly as well rather than trusting the dialog to
    /// appear.
    func openAccessibilitySettings() {
        _ = KeystrokeInjector.promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility monitoring
    //
    // The grant can disappear while the app is running — revoked in System Settings, reset with
    // tccutil, or invalidated by a rebuild whose designated requirement changed. Nothing noticed
    // before: face unlock kept recognising faces and then silently refusing to type, which from the
    // lock screen is indistinguishable from being rejected. These observers keep
    // `accessibilityGranted` live so every warning in the UI tracks the real state.

    @ObservationIgnored private var accessibilityObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var accessibilityPollTask: Task<Void, Never>?

    init() {
        startAccessibilityMonitoring()
    }

    private func startAccessibilityMonitoring() {
        // Posted system-wide whenever the Accessibility trust list changes. The trust value itself
        // settles slightly after the notification, hence the short delay before re-reading it.
        accessibilityObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.refreshAccessibilityStatus()
                self?.updateAccessibilityPolling()
            }
        })
        accessibilityObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccessibilityStatus() }
        })
        updateAccessibilityPolling()
    }

    /// While the grant is missing, re-check every couple of seconds so the warnings clear the
    /// moment the user flips the switch — the distributed notification is not guaranteed on every
    /// macOS release. Stops as soon as it is granted; a trusted app pays nothing.
    private func updateAccessibilityPolling() {
        if accessibilityGranted {
            accessibilityPollTask?.cancel()
            accessibilityPollTask = nil
            return
        }
        guard accessibilityPollTask == nil else { return }
        accessibilityPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refreshAccessibilityStatus()
                if self.accessibilityGranted {
                    self.accessibilityPollTask = nil
                    return
                }
            }
        }
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Authenticate to set up or use Mac ID")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "Enter a password first."
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "Password saved and encrypted."
            hasStoredPassword = true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Reads + decrypts + injects the stored password, zeroing the plaintext
    /// buffer before returning. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked.
    /// Returns whether the password was actually typed. Callers must not report a successful
    /// unlock without checking: every `return` below is a path where nothing reached the
    /// login window, and showing a success checkmark for those is how a missing Accessibility
    /// grant looked like a working unlock that simply did not log you in.
    @discardableResult
    func injectStoredPassword(requireAuthoritativeLock: Bool = false) async -> Bool {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            accessibilityGranted = false
            updateAccessibilityPolling()
            statusMessage = "Accessibility not granted — open System Settings and enable Mac ID."
            Self.injectionLog.error("injection refused: Accessibility not granted")
            return false
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Session locked — authenticate with Touch ID first."
            Self.injectionLog.error("injection refused: session key locked")
            return false
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "Skipped: CGSession reports screen is not actually locked."
                Self.injectionLog.error("injection refused: CGSession says the screen is not locked")
                return false
            }
        }

        statusMessage = "Injecting…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
            statusMessage = "Injected stored password + Return at \(Date().formatted(date: .omitted, time: .standard))"
            Self.injectionLog.info("injected password + Return")
            return true
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
            Self.injectionLog.error("injection threw: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
