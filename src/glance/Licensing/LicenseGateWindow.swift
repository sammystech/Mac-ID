//
//  LicenseGateWindow.swift
//  Mac ID
//
//  The activation screen shown at launch before the rest of the app starts.
//
//  Deliberately a real, activating `NSWindow` rather than reusing the notch overlay that onboarding
//  uses: that overlay is `.borderless`/`.nonactivatingPanel` precisely so it can sit over the notch
//  without stealing focus, and a panel that refuses to become key cannot receive typed characters.
//  This screen exists to be typed into, so it needs an ordinary titled window that can become key.
//
//  Mac ID normally runs as `.accessory` (menu bar only, no Dock icon). An accessory app's windows can
//  be shown but the app never properly activates, so the text field would render focused while
//  keystrokes went to whatever was frontmost. The gate therefore flips to `.regular` while it is up
//  and restores `.accessory` on the way out — the same trade onboarding makes.
//

import AppKit
import SwiftUI

@MainActor
final class LicenseGateWindow {
    /// Held for the window's lifetime. A local would be released as soon as the presenting function
    /// returned, taking the window with it.
    private static var shared: LicenseGateWindow?

    private var window: NSWindow?
    private let onActivated: () -> Void

    private init(onActivated: @escaping () -> Void) {
        self.onActivated = onActivated
    }

    /// Shows the gate and calls `onActivated` once a valid key has been entered. Never calls back if
    /// the user quits instead, which is the only other way out.
    static func present(onActivated: @escaping () -> Void) {
        // Re-presenting would orphan the first window behind the second.
        if let existing = shared, existing.window != nil {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let gate = LicenseGateWindow(onActivated: onActivated)
        shared = gate
        gate.show()
    }

    #if DEBUG
    /// Layout check only: `-MacIDPreviewGate expired` (or `trial`) on a Debug build shows the gate in
    /// that state and nothing else runs. Never compiled into a release.
    static var previewState: TrialManager.State?
    #endif

    private func show() {
        var view = LicenseGateView(
            onActivated: { [weak self] in self?.finish() },
            onQuit: { NSApp.terminate(nil) }
        )
        #if DEBUG
        view.previewState = Self.previewState
        #endif

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            // No `.resizable`, no `.miniaturizable`: the layout is fixed, and a minimised gate in an
            // app with no Dock icon would be unrecoverable.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.center()
        // Without a licence there is nothing behind this window to return to, so closing it is
        // equivalent to quitting. Making that explicit avoids leaving a running, invisible,
        // unlicensed app with no Dock icon and no way to bring anything back.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        self.window = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        window?.close()
        window = nil
        // Back to menu-bar-only. `presentOnboardingGate` / `revealSettingsWindow` re-assert whichever
        // policy they need, so handing back in the app's normal resting state keeps this from
        // fighting whatever runs next.
        NSApp.setActivationPolicy(.accessory)
        LicenseGateWindow.shared = nil
        onActivated()
    }
}

/// Straight to the price card with the terms box focused, and to the lost-key form. Both are handled
/// by the page's script (see web/index.html, `handleHash`).
enum LicenseLinks {
    static let buy = URL(string: "https://macid.net/#licence")!
    static let recover = URL(string: "https://macid.net/#recover")!
}

private struct LicenseGateView: View {
    let onActivated: () -> Void
    let onQuit: () -> Void
    var previewState: TrialManager.State?

    private var trialState: TrialManager.State { previewState ?? trial.state }

    @State private var key = ""
    // Starts with the reason a stored key was dropped, if it was, so the gate explains itself.
    @State private var error: String? = LicenseManager.shared.refusedMessage
    @State private var isActivating = false
    @State private var isStartingTrial = false
    @State private var trial = TrialManager.shared
    @FocusState private var fieldFocused: Bool

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trialAvailable: Bool {
        trialState == .notStarted
    }

    var body: some View {
        VStack(spacing: 0) {
            Image("appicon")
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.top, 26)
                .padding(.bottom, 10)

            Text("Mac ID")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.top, 4)

            if !trialAvailable {
                // Once the trial is over, buying is the way forward, so it leads.
                // A Button rather than a Link: a Link ignores the prominent button style.
                Button { NSWorkspace.shared.open(LicenseLinks.buy) } label: {
                    Text("Buy a licence — $4.99")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 28)
                .padding(.top, 20)

                HStack(spacing: 8) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                    Text("then paste your key")
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .fixedSize()
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
            }

            if trialAvailable {
                Button(action: startTrial) {
                    Text(isStartingTrial ? "Starting trial…" : "Start \(TrialManager.trialDays)-day free trial")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isStartingTrial)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 28)
                .padding(.top, 20)

                HStack(spacing: 8) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                    Text("or enter a key")
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .fixedSize()
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("ABCD-EFGH-JKMN-PQRS", text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(error == nil ? Color.clear : Color.red.opacity(0.6), lineWidth: 1)
                    )
                    .focused($fieldFocused)
                    .onChange(of: key) { _, _ in error = nil }
                    // Single-line now that keys are 19 characters, so Return can submit.
                    .onSubmit(activate)

                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)

            // Never the prominent button: the trial, or buying, is what the eye should land on first.
            Button(action: activate) { Text(isActivating ? "Activating…" : "Activate").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(trimmedKey.isEmpty || isActivating)
            .padding(.horizontal, 28)
            .padding(.top, 10)

            Spacer(minLength: 14)

            HStack(spacing: 10) {
                if trialAvailable {
                    Link("Buy a licence", destination: LicenseLinks.buy)
                        .font(.system(size: 11))
                    Text("·")
                        .foregroundStyle(SettingsMetrics.textTertiary)
                }
                Link("Lost your key?", destination: LicenseLinks.recover)
                    .font(.system(size: 11))
                Text("·")
                    .foregroundStyle(SettingsMetrics.textTertiary)
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            .padding(.bottom, 18)
        }
        .frame(width: 400, height: 420)
        .background(.ultraThickMaterial)
        .onAppear {
            trial.refresh()
            // Never auto-focused: the trial or the buy button should be what the eye lands on, and a
            // focused field would swallow Return meant for them.
            fieldFocused = false
        }
    }

    private var subtitle: String {
        switch trialState {
        case .notStarted:
            return "Try every feature free for \(TrialManager.trialDays == 1 ? "a day" : "\(TrialManager.trialDays) days"). No payment, no account."
        case .expired:
            return "Your free trial has ended. Mac ID won't unlock your Mac until you add a licence key."
        case .active:
            // Not normally reachable — an active trial launches straight into the app.
            return "Enter your licence key to activate."
        }
    }

    private func startTrial() {
        guard !isStartingTrial else { return }
        isStartingTrial = true
        Task {
            defer { isStartingTrial = false }
            switch await trial.start() {
            case .started:
                onActivated()
            case .alreadyUsed:
                error = "This Mac has already used its free trial. Enter a licence key to keep using Mac ID."
            case .unreachable:
                error = "Couldn't reach macid.net to start the trial. Check your internet connection and try again."
            }
        }
    }

    private func activate() {
        guard !trimmedKey.isEmpty, !isActivating else { return }
        isActivating = true
        Task {
            defer { isActivating = false }
            do {
                try await LicenseManager.shared.activate(trimmedKey)
                onActivated()
            } catch {
                // `LicenseError` carries user-facing text for every way activation can fail.
                self.error = error.localizedDescription
            }
        }
    }
}
