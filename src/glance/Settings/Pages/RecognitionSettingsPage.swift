//
//  RecognitionSettingsPage.swift
//  glance
//

import SwiftUI

struct RecognitionSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var settings = AppSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController`, not a local copy — same reasoning as
    /// `PasswordSettingsPage`.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            unlockedState
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
        // Password/name/enrollment flows run in the notch, outside this
        // window, so nothing else prompts a re-check once one closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                SettingsOptionSliderRowContent(
                    title: "Match confidence",
                    stepLabels: MatchConfidenceLevel.allCases.map(\.title),
                    index: matchConfidenceIndex,
                    stopCount: MatchConfidenceLevel.allCases.count
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Liveness")
                SettingsGroup {
                    SettingsOptionSliderRowContent(
                        title: "Liveness protection",
                        stepLabels: LivenessProtection.allCases.map(\.title),
                        index: livenessProtectionIndex,
                        stopCount: LivenessProtection.allCases.count
                    )
                }
                SettingsCaption(text: LivenessProtection(settings: settings).summary)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Attention")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Require eye contact",
                        subtitle: "Only unlocks when your eyes are open and you're looking at your Mac. Won't unlock if your eyes are closed or you're looking away.",
                        subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                    ) {
                        MacIDToggle(isOn: $settings.requireEyeContact)
                    }
                }
            }
        }
    }

    // MARK: - Liveness protection

    private var livenessProtectionIndex: Binding<Double> {
        Binding(
            get: { Double(LivenessProtection(settings: settings).rawValue) },
            set: { value in
                let clamped = min(max(Int(value.rounded()), 0), LivenessProtection.allCases.count - 1)
                LivenessProtection(rawValue: clamped)?.apply(to: settings)
            }
        )
    }

    // MARK: - Match confidence

    /// Nearest of the three snap points to whatever's stored, in case the
    /// value doesn't land exactly on one of the stops.
    private var matchConfidenceLevel: MatchConfidenceLevel {
        .nearest(to: coordinator.matchThreshold)
    }

    private var matchConfidenceIndex: Binding<Double> {
        Binding(
            get: { matchConfidenceLevel.sliderIndex },
            set: { coordinator.matchThreshold = MatchConfidenceLevel.from(sliderIndex: $0).threshold }
        )
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }
}

/// The three selectable points on the "Match confidence" slider — named
/// rather than exposing the raw cosine-similarity threshold directly.
private enum MatchConfidenceLevel: Int, CaseIterable {
    case lessStrict, standard, moreStrict

    var title: String {
        switch self {
        case .lessStrict: return "Less strict"
        case .standard: return "Default"
        case .moreStrict: return "More strict"
        }
    }

    var threshold: Float {
        switch self {
        case .lessStrict: return ArcFaceEmbedder.lessStrictThreshold
        case .standard: return ArcFaceEmbedder.defaultThreshold
        case .moreStrict: return ArcFaceEmbedder.moreStrictThreshold
        }
    }

    /// Position in `allCases` — same role as `AutoLockInterval.sliderIndex`.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to threshold: Float) -> Self {
        allCases.min { abs($0.threshold - threshold) < abs($1.threshold - threshold) } ?? .standard
    }
}
