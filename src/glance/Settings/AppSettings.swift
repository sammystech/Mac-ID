//
//  AppSettings.swift
//  glance
//
//  Backed directly by `UserDefaults.standard` — each property's `didSet`
//  writes through immediately, so there's no explicit "save" step.
//

import Foundation
import Observation

/// How long the Touch-ID-unlocked session may sit idle before it re-locks.
enum AutoLockInterval: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var id: Int { rawValue }

    var title: String { rawValue == 1 ? "1 day" : "\(rawValue) days" }

    var duration: TimeInterval { TimeInterval(rawValue) * 24 * 60 * 60 }

    /// Position in `allCases`, used to drive the discrete 4-stop slider.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> AutoLockInterval {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .sevenDays
    }
}

/// Unlock success/failure animation style shown in the notch overlay.
enum UnlockAnimationStyle: String, CaseIterable, Identifiable {
    case none
    case minimal
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .original: return "Original"
        }
    }

    /// The styles the picker offers; `.none` is still a valid stored value but is now produced by the "Show animation" toggle, not a tile.
    static let selectableCases: [UnlockAnimationStyle] = [.minimal, .original]
}

/// Liveness as one three-step choice. Each level is a fixed combination of the underlying switches
/// (`livenessChecksEnabled`, `livenessMode`, `printedPhotoSensitivity`), which stay the storage so
/// scans, Face Lab and older preferences all keep reading the same values.
enum LivenessProtection: Int, CaseIterable, Identifiable {
    /// Face match only. Fastest; a photo of you could get in.
    case minimal
    /// Deny cues on: rejects a printed photo and a photo on a phone screen. The default.
    case medium
    /// Deny cues plus a required proof of life (blink, depth, head turn), and the stricter
    /// printed-photo check. Slowest; can wait on someone holding perfectly still.
    case max

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .medium: return "Medium"
        case .max: return "Max"
        }
    }

    var summary: String {
        switch self {
        case .minimal:
            return "Minimal protection, fastest. Only checks that it's your face, so a photo of you could unlock your Mac."
        case .medium:
            return "Medium protection. Also rejects a printed photo or a photo on a phone screen. Slightly slower."
        case .max:
            return "Max protection, slowest. Also waits for a sign of a real face, like a blink or a slight head turn."
        }
    }

    @MainActor init(settings: AppSettings) {
        if !settings.livenessChecksEnabled {
            self = .minimal
        } else if settings.livenessMode == .heavy {
            self = .max
        } else {
            self = .medium
        }
    }

    @MainActor func apply(to settings: AppSettings) {
        switch self {
        case .minimal:
            settings.livenessChecksEnabled = false
        case .medium:
            settings.livenessChecksEnabled = true
            settings.livenessMode = .light
            settings.printedPhotoSensitivity = .standard
        case .max:
            settings.livenessChecksEnabled = true
            settings.livenessMode = .heavy
            settings.printedPhotoSensitivity = .strict
        }
    }
}

/// What can prompt Face Unlock. Multi-select; at least one is always kept
/// selected, since a Mac with none armed would never show the notch.
enum UnlockTrigger: String, CaseIterable, Identifiable {
    /// The display turned back on (see `LockEventKind.wake`).
    case onWake
    /// The screen just became locked, no wake involved.
    case onLock
    /// Pressing space on the lock screen starts a scan. The lock screen's
    /// Secure Event Input blocks normal event taps, so this is detected via
    /// IOKit HID instead (see `SpaceKeyMonitor`), requiring Input Monitoring.
    case onSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onWake: return "On wake"
        case .onLock: return "On lock"
        case .onSpace: return "On space"
        }
    }

    var iconName: String {
        switch self {
        case .onWake: return "moon.fill"
        case .onLock: return "lock.laptopcomputer"
        case .onSpace: return "space"
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    static let shared: AppSettings = {
        LegacyMigration.migrateIfNeeded()
        let settings = AppSettings()
        settings.normalizeLivenessProtection()
        return settings
    }()

    private enum Key {
        static let isFaceUnlockEnabled = "GlanceSettings.isFaceUnlockEnabled"
        static let matchThreshold = "GlanceSettings.matchThreshold"
        /// Which threshold calibration `matchThreshold` was set under; see
        /// `ArcFaceEmbedder.thresholdCalibration`.
        static let matchThresholdModel = "GlanceSettings.matchThresholdModel"
        static let livenessChecksEnabled = "GlanceSettings.livenessChecksEnabled"
        static let requireEyeContact = "GlanceSettings.requireEyeContact"
        static let livenessMode = "GlanceSettings.livenessMode"
        static let printedPhotoSensitivity = "GlanceSettings.printedPhotoSensitivity"
        static let minimumFaceWidth = "GlanceSettings.minimumFaceWidth"
        static let unlockAnimationStyle = "GlanceSettings.unlockAnimationStyle"
        static let showUnlockAnimation = "GlanceSettings.showUnlockAnimation"
        /// Legacy bool key — read once during migration, then ignored.
        static let playUnlockAnimation = "GlanceSettings.playUnlockAnimation"
        static let unlockTriggers = "GlanceSettings.unlockTriggers"
        static let retryOnHover = "GlanceSettings.retryOnHover"
        static let faceDetectionSeconds = "GlanceSettings.faceDetectionSeconds"
        // New key rather than the old "autoRetryOnce": that one defaulted to off, and retrying is
        // now on for everyone unless they turn it off.
        static let autoRetry = "GlanceSettings.autoRetry"
        static let hapticFeedbackEnabled = "GlanceSettings.hapticFeedbackEnabled"
        static let preferredDisplayID = "GlanceSettings.preferredDisplayID"
        static let preferredDisplayName = "GlanceSettings.preferredDisplayName"
        static let autoLockIntervalDays = "GlanceSettings.autoLockIntervalDays"
        static let defaultCameraID = "GlanceSettings.defaultCameraID"
        static let builtInDisplayCameraID = "GlanceSettings.builtInDisplayCameraID"
        static let externalDisplayCameraID = "GlanceSettings.externalDisplayCameraID"
        static let hasCompletedOnboarding = "GlanceSettings.hasCompletedOnboarding"
        static let onboardingResumeStep = "GlanceSettings.onboardingResumeStep"
        static let hasAcknowledgedSecurityNotice = "GlanceSettings.hasAcknowledgedSecurityNotice"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var isFaceUnlockEnabled: Bool {
        didSet { defaults.set(isFaceUnlockEnabled, forKey: Key.isFaceUnlockEnabled) }
    }
    var matchThreshold: Float {
        didSet {
            defaults.set(matchThreshold, forKey: Key.matchThreshold)
            defaults.set(ArcFaceEmbedder.thresholdCalibration, forKey: Key.matchThresholdModel)
        }
    }
    /// Master switch for liveness checking. Off means face recognition
    /// alone decides an unlock — a photo of the enrolled user would pass.
    var livenessChecksEnabled: Bool {
        didSet { defaults.set(livenessChecksEnabled, forKey: Key.livenessChecksEnabled) }
    }
    /// Unlock only while the person's eyes are open and on the camera — see `EyeContact`. Off by
    /// default: it adds a moment to every unlock and asks something of the user.
    var requireEyeContact: Bool {
        didSet { defaults.set(requireEyeContact, forKey: Key.requireEyeContact) }
    }
    /// Light (deny-only) vs Heavy (deny plus a required proof of life) —
    /// see `LivenessMode`.
    var livenessMode: LivenessMode {
        didSet { defaults.set(livenessMode.rawValue, forKey: Key.livenessMode) }
    }
    /// How hard the printed-photo deny cue tries; see `PrintedPhotoSensitivity`.
    var printedPhotoSensitivity: PrintedPhotoSensitivity {
        didSet { defaults.set(printedPhotoSensitivity.rawValue, forKey: Key.printedPhotoSensitivity) }
    }
    /// Mirrored into `FaceRecognitionPipeline.minimumProminentFaceWidth` on
    /// every change, since that's read from a background `nonisolated` context.
    var minimumFaceWidth: Float {
        didSet {
            defaults.set(minimumFaceWidth, forKey: Key.minimumFaceWidth)
            FaceRecognitionPipeline.minimumProminentFaceWidth = minimumFaceWidth
        }
    }
    /// The remembered choice (`.minimal`/`.original` only); `showUnlockAnimation`
    /// tracks on/off separately so toggling back on restores the prior pick.
    /// Read `effectiveUnlockAnimationStyle`, not this, to decide what to show.
    var unlockAnimationStyle: UnlockAnimationStyle {
        didSet { defaults.set(unlockAnimationStyle.rawValue, forKey: Key.unlockAnimationStyle) }
    }
    var showUnlockAnimation: Bool {
        didSet { defaults.set(showUnlockAnimation, forKey: Key.showUnlockAnimation) }
    }

    /// What the overlay should actually render — the pick, or `.none` when
    /// animations are switched off entirely.
    var effectiveUnlockAnimationStyle: UnlockAnimationStyle {
        showUnlockAnimation ? unlockAnimationStyle : .none
    }

    /// Which signals arm Face Unlock. Persisted as raw-value strings; the
    /// setter refuses to store an empty set (see `UnlockTrigger`).
    var unlockTriggers: Set<UnlockTrigger> {
        didSet {
            // Belt-and-braces behind the picker's own min-one rule. This
            // reassignment re-enters didSet once, then terminates since the
            // corrected value is never itself empty.
            if unlockTriggers.isEmpty {
                unlockTriggers = oldValue.isEmpty ? Set(UnlockTrigger.allCases) : oldValue
            }
            defaults.set(unlockTriggers.map(\.rawValue), forKey: Key.unlockTriggers)
        }
    }
    var retryOnHover: Bool {
        didSet { defaults.set(retryOnHover, forKey: Key.retryOnHover) }
    }
    /// How long each scan cycle looks for a face before giving up. Must stay
    /// equal to `FaceUnlockCoordinator.scanWindowDuration` and
    /// `NotchOverlayController.scanTimeoutDuration`.
    var faceDetectionSeconds: Int {
        didSet {
            // Only reassign when clamping actually changes the value —
            // unconditional reassignment would recurse infinitely, since the
            // slider only ever produces already-in-range values.
            let clamped = min(max(faceDetectionSeconds, Self.faceDetectionRange.lowerBound),
                               Self.faceDetectionRange.upperBound)
            guard clamped == faceDetectionSeconds else {
                faceDetectionSeconds = clamped
                return
            }
            defaults.set(faceDetectionSeconds, forKey: Key.faceDetectionSeconds)
        }
    }
    /// After a failed scan, try again on its own up to `FaceUnlockCoordinator.maxAutoRetries` times
    /// before leaving it to a hover on the notch.
    var autoRetry: Bool {
        didSet { defaults.set(autoRetry, forKey: Key.autoRetry) }
    }
    /// Trackpad haptic on hovering the notch/pill and on a successful unlock —
    /// see `NotchOverlayView`'s hover handler and `.onChange(of: controller.phase)`.
    var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Key.hapticFeedbackEnabled) }
    }

    static let faceDetectionRange = 3...10

    /// Which display Face Unlock shows on. `nil` means `NotchGeometry.preferredScreen()`'s
    /// default, re-evaluated live; a pinned display has deliberately no
    /// fallback if disconnected (see `FaceUnlockCoordinator.evaluateTrigger()`).
    var preferredDisplayID: String? {
        didSet { defaults.set(preferredDisplayID, forKey: Key.preferredDisplayID) }
    }
    /// The chosen display's name at pick time — cosmetic only, so the row can
    /// show something recognizable when that display is disconnected.
    var preferredDisplayName: String? {
        didSet { defaults.set(preferredDisplayName, forKey: Key.preferredDisplayName) }
    }
    /// Enforced by `SessionAutoLocker`, not here — this is only the stored
    /// preference.
    var autoLockInterval: AutoLockInterval {
        didSet { defaults.set(autoLockInterval.rawValue, forKey: Key.autoLockIntervalDays) }
    }
    /// Device `uniqueID`s, not device objects — devices can disconnect/
    /// reconnect between launches, but their unique ID is stable.
    var defaultCameraID: String? {
        didSet { defaults.set(defaultCameraID, forKey: Key.defaultCameraID) }
    }
    var builtInDisplayCameraID: String? {
        didSet { defaults.set(builtInDisplayCameraID, forKey: Key.builtInDisplayCameraID) }
    }
    var externalDisplayCameraID: String? {
        didSet { defaults.set(externalDisplayCameraID, forKey: Key.externalDisplayCameraID) }
    }

    /// Gates first-run onboarding — `AppDelegate` shows it instead of the
    /// Settings window until this is `true`. Set once, by `OnboardingController`
    /// on the true first-run flow reaching `.complete`.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }
    /// Where to resume first-run onboarding if the app quit mid-flow; `nil`
    /// starts fresh at `.intro`. Steps depending on in-memory capture state
    /// collapse to `.preSetup` before storing, since that state doesn't
    /// survive a relaunch — see `OnboardingStep.resumeTarget`.
    var onboardingResumeStep: OnboardingStep? {
        didSet { defaults.set(onboardingResumeStep?.rawValue, forKey: Key.onboardingResumeStep) }
    }
    /// Gates the one-time post-update notice for users who completed onboarding before the
    /// security-disclaimer step existed. Set alongside `hasCompletedOnboarding` for anyone
    /// finishing normal onboarding (which now includes that step), and separately by
    /// `OnboardingController.startPostUpdateNotice()` once the standalone catch-up notice is
    /// acknowledged. Defaults `false`, so an upgrading 1.0 install (where this key has never
    /// been written) correctly triggers the catch-up flow once.
    var hasAcknowledgedSecurityNotice: Bool {
        didSet { defaults.set(hasAcknowledgedSecurityNotice, forKey: Key.hasAcknowledgedSecurityNotice) }
    }

    private init() {
        // Enabled by default — onboarding already enrolled a face and set a
        // password specifically to use Face Unlock.
        isFaceUnlockEnabled = defaults.object(forKey: Key.isFaceUnlockEnabled) as? Bool ?? true
        // A stored threshold is only carried over if it was set for the embedding space still in
        // use. After a backbone change the old number means nothing — keeping it would silently
        // leave unlock wide open or permanently shut, with no visible sign either way.
        let storedThresholdModel = defaults.string(forKey: Key.matchThresholdModel)
        if storedThresholdModel == ArcFaceEmbedder.thresholdCalibration,
           let stored = defaults.object(forKey: Key.matchThreshold) as? Float {
            matchThreshold = stored
        } else {
            let seeded = ArcFaceEmbedder.defaultThreshold
            matchThreshold = seeded
            defaults.set(seeded, forKey: Key.matchThreshold)
            defaults.set(ArcFaceEmbedder.thresholdCalibration, forKey: Key.matchThresholdModel)
        }
        livenessChecksEnabled = defaults.object(forKey: Key.livenessChecksEnabled) as? Bool ?? true
        requireEyeContact = defaults.object(forKey: Key.requireEyeContact) as? Bool ?? false
        // Light by default — Heavy requires a blink/pose/depth signal a
        // still, non-blinking user may never produce, while Light still
        // catches the main attack (a photo on a phone screen).
        livenessMode = defaults.string(forKey: Key.livenessMode)
            .flatMap(LivenessMode.init(rawValue:)) ?? .light
        printedPhotoSensitivity = defaults.string(forKey: Key.printedPhotoSensitivity)
            .flatMap(PrintedPhotoSensitivity.init(rawValue:)) ?? .standard
        // No longer a setting: always the old "Far" stop, the smallest face the pipeline accepts,
        // so Mac ID works from close up to arm's length and beyond without anyone tuning it. A
        // closer face is always fine; this is only a minimum.
        minimumFaceWidth = Self.allDistancesFaceWidth

        // Resolve the stored style first, `.none` included, then split it
        // into the pick + the on/off flag the UI now works in.
        let storedStyle: UnlockAnimationStyle
        if let raw = defaults.string(forKey: Key.unlockAnimationStyle),
           let style = UnlockAnimationStyle(rawValue: raw) {
            storedStyle = style
        } else if let legacy = defaults.object(forKey: Key.playUnlockAnimation) as? Bool {
            // Migrate the oldest on/off toggle: off → none, on → original.
            storedStyle = legacy ? .original : .none
        } else {
            storedStyle = .original
        }
        // A stored `.none` becomes "off, remembering .original" so
        // switching back on has something to restore.
        unlockAnimationStyle = storedStyle == .none ? .original : storedStyle
        showUnlockAnimation = defaults.object(forKey: Key.showUnlockAnimation) as? Bool
            ?? (storedStyle != .none)

        // On wake/lock by default, not on space — `.onSpace` needs Input
        // Monitoring, which a fresh install shouldn't request unprompted.
        let storedTriggers = (defaults.array(forKey: Key.unlockTriggers) as? [String])?
            .compactMap { raw -> UnlockTrigger? in
                // "onActivity" was merged into "onWake"; keep old installs working.
                if raw == "onActivity" { return .onWake }
                return UnlockTrigger(rawValue: raw)
            }
        unlockTriggers = storedTriggers.map(Set.init).flatMap { $0.isEmpty ? nil : $0 }
            ?? [.onWake, .onLock]
        retryOnHover = defaults.object(forKey: Key.retryOnHover) as? Bool ?? true
        faceDetectionSeconds = (defaults.object(forKey: Key.faceDetectionSeconds) as? Int)
            .map { min(max($0, Self.faceDetectionRange.lowerBound), Self.faceDetectionRange.upperBound) }
            ?? 5
        autoRetry = defaults.object(forKey: Key.autoRetry) as? Bool ?? true
        hapticFeedbackEnabled = defaults.object(forKey: Key.hapticFeedbackEnabled) as? Bool ?? true
        preferredDisplayID = defaults.string(forKey: Key.preferredDisplayID)
        preferredDisplayName = defaults.string(forKey: Key.preferredDisplayName)

        // Defaults to 7 days — long enough not to nag daily users, short
        // enough not to leave an abandoned session live indefinitely.
        autoLockInterval = (defaults.object(forKey: Key.autoLockIntervalDays) as? Int)
            .flatMap(AutoLockInterval.init(rawValue:)) ?? .sevenDays
        defaultCameraID = defaults.string(forKey: Key.defaultCameraID)
        builtInDisplayCameraID = defaults.string(forKey: Key.builtInDisplayCameraID)
        externalDisplayCameraID = defaults.string(forKey: Key.externalDisplayCameraID)

        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        onboardingResumeStep = defaults.string(forKey: Key.onboardingResumeStep)
            .flatMap(OnboardingStep.init(rawValue:))
        hasAcknowledgedSecurityNotice = defaults.object(forKey: Key.hasAcknowledgedSecurityNotice) as? Bool ?? false

        // Push into the nonisolated mirror immediately, or FaceRecognitionPipeline
        // would keep its own default.
        FaceRecognitionPipeline.minimumProminentFaceWidth = minimumFaceWidth
    }

    static let allDistancesFaceWidth: Float = 0.15

    /// Snaps liveness preferences saved by older versions (any mix of the old toggle and pickers)
    /// onto the nearest of the three levels, so what the slider shows is what scans do. Run after
    /// `shared` exists: an initialiser's own assignments don't reach `didSet`, so they wouldn't
    /// be saved.
    func normalizeLivenessProtection() {
        LivenessProtection(settings: self).apply(to: self)
    }
}
