//
//  FaceUnlockCoordinator.swift
//  glance
//
//  Connects face recognition to the actual unlock path. Off by default; user opts in after validating accuracy in Face Lab.
//
//  Known limitation: LivenessAnalyzer defeats a photo but not a replayed video (real non-rigid motion looks live) — a successful spoof types the real macOS password.
//

import Foundation
import CoreGraphics
import Observation
import OSLog

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()

    /// Persisted via AppSettings. Setting to false cancels any in-flight scan and disarms the overlay immediately.
    var isEnabled: Bool {
        didSet {
            AppSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { disarmOverlay() }
        }
    }

    /// Kept independent from Face Lab's own `threshold` so tuning the debug tool never silently changes the real unlock gate.
    var matchThreshold: Float {
        didSet { AppSettings.shared.matchThreshold = matchThreshold }
    }
    /// Shares its setting with NotchOverlayController's scanning timeout, so the background loop stops in step with the UI collapsing.
    private var scanWindowDuration: TimeInterval {
        TimeInterval(AppSettings.shared.faceDetectionSeconds)
    }
    /// Requires several consecutive below-threshold frames so a single bad-angle read doesn't trigger the failure animation.
    private let wrongFaceStreakThreshold = 6
    /// How many recent frames of the same tracked face get averaged into the embedding that is actually
    /// matched. Larger is steadier but slower to first unlock; five is ~150ms of frames at the rate the
    /// pipeline now runs at.
    private static let embeddingFusionWindow = 5
    /// How long to wait before looking for another camera frame. Short enough that processing, not
    /// polling, is what paces the scan loop.
    private static let framePollInterval: UInt64 = 5_000_000
    /// Run the rectangle detector every Nth processed frame. It is the most expensive thing on the
    /// path (~10ms) and answers a question that cannot change between frames — a phone or sheet of
    /// paper does not appear and vanish in 33ms. Its cue needs 3 firing frames, and a scan window
    /// sees far more than 5x that, so raising this from 3 costs the cue nothing.
    private static let bezelCheckInterval = 5

    /// Timing for the one number that matters — trigger to unlocked. Camera warm-up dominates it, so
    /// it is reported separately from the recognition work that follows. Read it with:
    ///     log stream --predicate 'subsystem == "com.samuelmittman.macid"' --info
    private static let timingLog = Logger(subsystem: "com.samuelmittman.macid", category: "timing")

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    /// One-shot per lock session — an auto-retry that could itself auto-retry would loop the camera for the whole lock session.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle bails once superseded (see `runScanCycle(generation:)`).
    private var scanGeneration = 0
    /// When the last scan cycle was armed — collapses a single wake into a single arm (see `.wake` branch of `evaluateTrigger`).
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms of each other; anything in this window counts as the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    /// Held separately from `scanTask` since it's scheduled from inside the scan task it follows — reusing `scanTask` would self-cancel it.
    private var autoRetryTask: Task<Void, Never>?
    /// Gap between headless auto-retries, just to keep the camera from restarting in a tight loop.
    private let headlessRetryDelay: Duration = .seconds(1)

    /// When off, no notch/pill presence at all — every overlay call in this file is conditioned on this rather than just skipping the video.
    private var showsUI: Bool { AppSettings.shared.showUnlockAnimation }

    /// Reads the space key on the lock screen for the "On space" trigger; only runs while locked + opted in.
    private let spaceKeyMonitor = SpaceKeyMonitor()

    init(pocController: POCController) {
        self.pocController = pocController
        self.isEnabled = AppSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = AppSettings.shared.matchThreshold
        spaceKeyMonitor.onSpaceKeyDown = { [weak self] in self?.handleSpaceKeyPress() }
        observeLockAndWakeEvents()
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            // Also tracked so screensaver-stop and display-only wakes still wake this up.
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeLockAndWakeEvents()
                // Warm the camera *during* the settle delay rather than after it. This is the single
                // largest term in time-to-unlock: `startRunning()` needs a few hundred milliseconds
                // before it yields a usable frame, and it used to be reached only after this sleep
                // and the arm animation — roughly 550ms of waiting before the hardware was even
                // asked to start. Everything the recognizer then does costs ~25ms a frame against
                // that.
                self.recoverSessionIfNeeded()
                self.recoverAccessibilityIfNeeded()
                self.prewarmCamera()
                // Brief settle delay: CGSession's reported state can lag the true state right after wake.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.evaluateTrigger()
            }
        }
    }

    /// Re-prompts for Touch ID after a manual unlock, when the session key is locked.
    ///
    /// The session key lives only in RAM, so it is locked by every app launch — including the
    /// relaunch macOS forces when one of the app's permissions is toggled. There is no way to
    /// prompt at the lock screen (no UI can host a Touch ID sheet there), so a prompt dismissed at
    /// launch used to leave face unlock silently dead: `evaluateTrigger` would set a status message
    /// nobody sees and return without ever showing the notch. The only symptom was the lock screen
    /// doing nothing at all.
    ///
    /// A manual unlock is the one moment the user is provably at the machine and has just
    /// authenticated, which makes it the right time to ask again.
    private func recoverSessionIfNeeded() {
        guard lockMonitor.lastEvent == .screenUnlocked else { return }
        guard isEnabled,
              LicenseManager.shared.isEntitled,
              SecureCredentialManager.hasStoredPassword(),
              !SecureCredentialManager.isSessionUnlocked
        else { return }

        // Someone who cancels means it, so back off rather than re-asking on every unlock. Cleared
        // on a successful unlock, so a later genuine relock still recovers.
        let now = ContinuousClock.now
        if let last = lastSessionPromptAt, now - last < Self.sessionPromptCooldown { return }
        lastSessionPromptAt = now

        Task { [weak self] in
            // Let the unlock animation finish first; a Touch ID sheet racing it gets dismissed.
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !SecureCredentialManager.isSessionUnlocked else { return }
            await self.pocController.unlockSession()
            if SecureCredentialManager.isSessionUnlocked {
                self.lastSessionPromptAt = nil
            }
        }
    }

    /// One diagnostic line per scan rather than per frame.
    private var loggedScanDiagnostics = false

    /// Points the user at the Accessibility switch right after they log in by hand, when face
    /// unlock is set up but can't type.
    ///
    /// Without the grant a scan still recognises the face — the logs show sub-second matches — and
    /// then `injectStoredPassword` refuses, so the user types their password themselves with no idea
    /// why. That manual login is the moment they are at the machine and have just seen it fail, so
    /// it is when the fix is most likely to be understood rather than dismissed.
    private func recoverAccessibilityIfNeeded() {
        guard lockMonitor.lastEvent == .screenUnlocked else { return }
        pocController.refreshAccessibilityStatus()
        guard isEnabled,
              SecureCredentialManager.hasStoredPassword(),
              !pocController.accessibilityGranted
        else { return }

        let now = ContinuousClock.now
        if let last = lastAccessibilityPromptAt, now - last < Self.sessionPromptCooldown { return }
        lastAccessibilityPromptAt = now

        statusMessage = "Face unlock recognised you but couldn't type — Accessibility is off."
        Task { [weak self] in
            // Behind the Touch ID sheet `recoverSessionIfNeeded` may be raising, not on top of it.
            try? await Task.sleep(for: .milliseconds(2500))
            guard let self, !self.pocController.accessibilityGranted else { return }
            self.pocController.openAccessibilitySettings()
        }
    }

    private var lastAccessibilityPromptAt: ContinuousClock.Instant?
    private var lastSessionPromptAt: ContinuousClock.Instant?
    private static let sessionPromptCooldown = Duration.seconds(300)

    /// Speculative: starts the capture session on the cheap, stable preconditions, before the
    /// settle delay has confirmed we will actually scan. `evaluateTrigger` calls `abandonPrewarm()`
    /// on every path that turns out not to scan, so the camera is never left running — which
    /// matters, because a running session lights the recording indicator.
    private func prewarmCamera() {
        guard isEnabled,
              LicenseManager.shared.isEntitled,
              SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword()
        else { return }
        Task { [weak self] in await self?.camera.start() }
    }

    /// Stops a speculatively-started camera when no scan took ownership of it.
    private func abandonPrewarm() {
        guard scanTask == nil else { return }
        camera.stop()
    }

    private func evaluateTrigger() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else { abandonPrewarm(); return }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear the one-shot guard.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard isEnabled, !hasArmedForCurrentLock else { abandonPrewarm(); return }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else { abandonPrewarm(); return }
        // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Main display" (nil) always resolves.
        guard NotchGeometry.preferredScreen() != nil else { abandonPrewarm(); return }

        // Gated here rather than deeper in the scan so an unlicensed copy never turns the camera on.
        // `isEntitled` covers a paid key or a live trial; the trial's remaining days are re-checked
        // here rather than cached, so it stops working the moment it lapses mid-session.
        TrialManager.shared.refresh()
        guard LicenseManager.shared.isEntitled else {
            statusMessage = "Your free trial has ended — add a licence key in Settings → About."
            abandonPrewarm()
            return
        }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once from Password settings first."
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return
        }

        // A deselected trigger means "don't auto-scan for this signal," not "do nothing" — the user can still opt in by hand.
        let shouldAutoScan = AppSettings.shared.unlockTriggers.contains(signal)

        // Headless has nothing to arm/hover, so if this signal isn't selected there's nothing to do — and hasArmedForCurrentLock
        // must stay false, or a later selected signal could never fire (nothing else calls arm() to reset it).
        guard showsUI || shouldAutoScan else { abandonPrewarm(); return }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        Task { [weak self] in
            guard let self else { return }
            // Start the capture session *now*, not after the arm animation. `AVCaptureSession.startRunning()`
            // takes a few hundred milliseconds to produce a first usable frame, and until this it was only
            // reached after 250ms of animation buffer — so the two costs were paid back to back instead of
            // at the same time. `start()` is idempotent and `runScanCycle` still calls it, so this only ever
            // moves the warm-up earlier. Gated on `shouldAutoScan` so hover-to-start doesn't light the
            // camera indicator while the user is only being offered a scan, not given one.
            if shouldAutoScan {
                await self.camera.start()
            }
            // arm() only shows a small closed notch silhouette, so this only needs a brief buffer past the login window's entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self.arm(autoScan: shouldAutoScan)
        }
    }

    /// Whether the last arm was recent enough to be part of the same wake burst rather than a new one.
    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// nil for signals that shouldn't arm anything — including a nil `lastEvent`, or the first observation would fire regardless of user selection.
    private func requiredTrigger(for event: LockEventKind?) -> UnlockTrigger? {
        switch event {
        case .wake: return .onWake
        case .screenLocked: return .onLock
        case .screenUnlocked, .willSleep, nil: return nil
        }
    }

    private func disarmOverlay() {
        scanTask?.cancel()
        scanTask = nil
        // Bumping makes any cycle still suspended at `await camera.start()` inert, rather than resuming and re-showing the overlay.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        camera.stop()
        NotchOverlayController.shared.disarm()
        // Covers isEnabled being switched off directly, keeping "disarmed" and "not listening for space" in lockstep.
        spaceKeyMonitor.stop()
    }

    /// Idempotent and safe to call on every lock/wake event. Deliberately does not prompt for Input Monitoring — a missing grant just means "don't listen."
    private func updateSpaceMonitor() {
        let shouldListen = isEnabled
            && AppSettings.shared.unlockTriggers.contains(.onSpace)
            && LockMonitor.isScreenActuallyLocked()
            && SpaceKeyMonitor.hasInputMonitoringAccess()
        if shouldListen {
            spaceKeyMonitor.start()
        } else {
            spaceKeyMonitor.stop()
        }
    }

    /// Runs the same gate chain as `evaluateTrigger`, then starts a scan. Independent of `LockMonitor` events, so doesn't touch `hasArmedForCurrentLock`.
    private func handleSpaceKeyPress() {
        guard isEnabled,
              AppSettings.shared.unlockTriggers.contains(.onSpace),
              LockMonitor.isScreenActuallyLocked(),
              NotchGeometry.preferredScreen() != nil,
              SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword()
        else { return }

        // Already looking — swallows auto-repeat/double-presses and lets "On wake"/"On lock" override "On space" with no special-casing.
        guard NotchOverlayController.shared.phase != .scanning else { return }

        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // Closed pill/notch already up — expand and scan, like a hover retry.
            startScanCycle()
        } else {
            Task { [weak self] in await self?.arm(autoScan: true) }
        }
    }

    /// Either way the overlay still arms — a deselected trigger only skips the automatic scan, leaving hover-to-start available.
    private func arm(autoScan: Bool) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        guard showsUI else {
            // Headless: evaluateTrigger() already guaranteed autoScan is true here, so this is just "start scanning."
            startScanCycle()
            return
        }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        if autoScan {
            startScanCycle()
        }
    }

    /// Called on arm, and again whenever the overlay hover-activates.
    private func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// `generation` is what makes overlapping cycles safe: `Task.cancel()` is cooperative, so a superseded cycle still runs to the
    /// end of this function, and its global side effects (`camera.stop()` etc.) could otherwise land on the newer cycle instead
    /// of itself. This was a real bug — a superseded `camera.stop()` queued behind the newer cycle's `startRunning()` made the
    /// camera visibly switch on then die mid-warm-up, leaving the surviving cycle polling a dead session and never unlocking.
    private func runScanCycle(generation: Int) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        let scanStartedAt = ContinuousClock.now
        await camera.start()
        guard generation == scanGeneration else { return }

        if let error = camera.errorMessage {
            statusMessage = error
            camera.stop()
            return
        }

        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.beginScanning()
        }
        statusMessage = "Looking for your face…"

        let outcome = await observeScanWindow(
            deadline: Date().addingTimeInterval(scanWindowDuration),
            requireOverlayScanning: showsUI,
            scanStartedAt: scanStartedAt
        )

        // A newer cycle now owns the camera and overlay — leave both alone, and leave the auto-retry one-shot unspent.
        guard generation == scanGeneration else { return }

        camera.stop()

        switch outcome {
        case .matched:
            // The unlock already happened inside observeScanWindow — this only decides whether anything is shown about it.
            if showsUI {
                NotchOverlayController.shared.finish(success: true)
            }
        case .injectionFailed:
            // pocController already holds the specific reason; surfacing it beats a generic failure.
            statusMessage = pocController.statusMessage
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
            }

        case .consistentlyWrongFace:
            statusMessage = "Face not recognized."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Face not recognized — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .spoofSuspected:
            statusMessage = "Couldn't confirm a live face."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Couldn't confirm a live face — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .noResolution:
            statusMessage = "No face detected."
            if showsUI {
                // No explicit collapse call: NotchOverlayController's own scanning timeout fires on the same mark and collapses itself.
                statusMessage = "No face detected — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        }
    }

    /// `delay` waits out whatever the overlay is still showing so the retry doesn't start underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard AppSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentLock else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Re-check rather than trust the delay: the user may have unlocked by password or retried manually while this waited.
            guard LockMonitor.isScreenActuallyLocked(), self.isEnabled else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    nonisolated private static func ms(from instant: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - instant) / .milliseconds(1))
    }

    private enum ScanOutcome {
        case matched
        /// Face was recognised but the password never reached the login window — almost always a
        /// missing Accessibility grant. Distinct from a failed match so the UI can say so.
        case injectionFailed
        case consistentlyWrongFace
        /// A deny cue (glare, device rectangle) fired — actively rejected as a spoof regardless of match. Same failure path as `.consistentlyWrongFace`.
        case spoofSuspected
        case noResolution
    }

    /// Recognition and liveness run concurrently and each latches when it succeeds, so unlock fires the moment the second lands;
    /// liveness never fails the scan by staying undecided, it just keeps scanning until `deadline`.
    /// `requireOverlayScanning` bails early once the overlay's own timeout collapses the UI — only applied when there is an
    /// overlay, since headlessly `phase` never becomes `.scanning` at all.
    private func observeScanWindow(
        deadline: Date,
        requireOverlayScanning: Bool,
        scanStartedAt: ContinuousClock.Instant
    ) async -> ScanOutcome {
        let livenessEnabled = AppSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { AppSettings.shared.livenessMode }
        // Read fresh per frame, like the mode, so changing it in Settings mid-scan takes effect.
        liveness.tuningProvider = { AppSettings.shared.printedPhotoSensitivity.applied() }
        liveness.enabledCuesProvider = {
            // "Off" removes the cue outright rather than pushing its threshold out of reach, so it
            // can't accumulate frames or show up as evidence in the outcome message.
            var cues = Set(LivenessCue.allCases)
            if AppSettings.shared.printedPhotoSensitivity == .off {
                cues.remove(.printedPhoto)
            }
            return cues
        }
        var consecutiveWrongFaceFrames = 0

        /// Cleared the moment a detected face fails to match, so a latched match can't be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        /// Turning liveness off in Settings makes this half permanently ready.
        var livenessConfirmed = !livenessEnabled
        /// Last frame's selected face, passed back so `selectDominantFace` stays on the same person instead of flip-flopping.
        var lastFaceBoundingBox: CGRect?
        /// Cheap way to detect "no new camera frame yet" vs. "fresh frame" — without it a repeat frame would corrupt the liveness motion signal.
        var lastProcessedFrameID: UInt64?
        /// Rolling embeddings for the face currently being tracked — see `fusedEmbedding` below.
        var recentEmbeddings: [[Float]] = []
        var processedFrames = 0
        var firstFrameAt: ContinuousClock.Instant?

        // Once per scan, not per frame — reset here, before the loop.
        loggedScanDiagnostics = false
        while Date() < deadline, !Task.isCancelled,
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            guard LockMonitor.isScreenActuallyLocked() else { return .noResolution }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                // Poll well inside the camera's ~33ms cadence. This used to be 20ms, which on its own is
                // fine — but added to the ~20ms a frame takes to process it made a ~40ms cycle against
                // 33ms frame arrivals, so roughly every fourth frame was skipped and every scan took
                // longer than it needed to. It also delayed the very first frame after warm-up.
                try? await Task.sleep(nanoseconds: Self.framePollInterval)
                continue
            }
            if firstFrameAt == nil {
                firstFrameAt = .now
                Self.timingLog.info("camera: first frame \(Self.ms(from: scanStartedAt), privacy: .public) ms after the scan began")
            }
            lastProcessedFrameID = frame.id

            // The rectangle detector is the single most expensive thing on this path and it answers a
            // question that cannot change between consecutive frames: a phone or sheet of paper does not
            // appear and vanish in 33ms. Running it every third processed frame keeps the cue's own
            // `deviceFrames: 3` threshold reachable well inside the scan window while cutting its cost.
            let runsBezelCheck = processedFrames % Self.bezelCheckInterval == 0
            processedFrames += 1

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let (result, crop) = try? pipeline.recognize(in: frame, preferNear: previousBoundingBox) else { return nil }
                let overlap = runsBezelCheck
                    ? DeviceBezelDetector.detect(
                        in: frame.pixelBuffer, faceBoundingBox: result.face.boundingBox
                      ).faceOverlapFraction
                    : nil
                return (result, LivenessFeatureExtractor.extract(
                    from: result, deviceOverlapFraction: overlap, faceCrop: crop
                ))
            }.value

            guard let (result, livenessFrame) = outcome else {
                consecutiveWrongFaceFrames = 0
                lastFaceBoundingBox = nil
                // Whoever was being tracked is gone; their partial template must not be blended
                // into whoever shows up next.
                recentEmbeddings.removeAll()
                try? await Task.sleep(nanoseconds: Self.framePollInterval)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Fed regardless of match, so liveness stays a genuinely independent gate rather than one starved by recognition confidence.
            var confirmingCue: LivenessCue?
            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    // Overrides everything, including a match and any confirmation that already happened.
                    lastOutcome = snapshot.decision.denialReason
                    // Logged because this is the one refusal a real face can trigger — a deny cue firing
                    // on the actual user. It used to be stored in `lastOutcome` and shown nowhere, so from
                    // the lock screen it was indistinguishable from not being recognised.
                    Self.timingLog.info("liveness DENIED: \(String(describing: snapshot.decision), privacy: .public) - \(snapshot.decision.denialReason ?? "", privacy: .public)")
                    return .spoofSuspected
                case .confirmed(let cue):
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            // Match on an average of the last few frames rather than on whichever single frame arrived.
            // A per-frame embedding carries real noise — landmark jitter moves the alignment a pixel or
            // two and the embedding wobbles with it — and averaging unit vectors cancels the part of that
            // wobble that is uncorrelated between frames while leaving the identity signal intact. Only
            // frames of the same continuously-tracked face are in the buffer, so this cannot blend people.
            recentEmbeddings.append(result.embedding)
            if recentEmbeddings.count > Self.embeddingFusionWindow {
                recentEmbeddings.removeFirst()
            }
            let fusedEmbedding = FaceEmbedding.average(recentEmbeddings) ?? result.embedding

            // `activeIdentities`, not `identities`: someone switched off on the Your Face page stays enrolled but must not unlock.
            let activeIdentities = FaceEnrollmentStore.shared.activeIdentities
            let scored = pipeline.score(fusedEmbedding, against: activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold)

            // Only successes used to be logged, which made every refusal indistinguishable: a
            // stale enrolment (recorded under a different model, so `bestMatch` returns nil no
            // matter whose face it is) looked exactly like a genuine non-match. Logged once per
            // scan so a real refusal can be read back instead of guessed at.
            if !loggedScanDiagnostics {
                loggedScanDiagnostics = true
                let stale = activeIdentities.filter { $0.isStale(comparedTo: pipeline.embedder) }
                let best = scored.first.map { String(format: "%.3f", $0.centroidSimilarity) } ?? "none"
                Self.timingLog.info("liveness: \(livenessEnabled ? "on" : "off", privacy: .public), mode \(AppSettings.shared.livenessMode.rawValue, privacy: .public), printed-photo \(AppSettings.shared.printedPhotoSensitivity.rawValue, privacy: .public)")
                Self.timingLog.info(
                    """
                    scan: \(activeIdentities.count, privacy: .public) active identities, \
                    \(stale.count, privacy: .public) stale (enrolled under a different model), \
                    best \(best, privacy: .public) vs threshold \
                    \(String(format: "%.2f", self.matchThreshold), privacy: .public)
                    """)
                if let first = activeIdentities.first {
                    Self.timingLog.info(
                        """
                        enrolment model \(first.modelIdentifier, privacy: .public), \
                        embedder model \(self.pipeline.embedder.modelIdentifier, privacy: .public)
                        """)
                }
            }

            if let matched {
                consecutiveWrongFaceFrames = 0
                readyMatch = matched
            } else {
                readyMatch = nil
                consecutiveWrongFaceFrames += 1
                if consecutiveWrongFaceFrames >= wrongFaceStreakThreshold {
                    let best = scored.first.map { String(format: "%.3f", $0.centroidSimilarity) } ?? "none"
                    Self.timingLog.info("refused: best \(best, privacy: .public) < \(String(format: "%.2f", self.matchThreshold), privacy: .public) over \(self.wrongFaceStreakThreshold, privacy: .public) frames")
                    return .consistentlyWrongFace
                }
            }

            if let readyMatch, livenessConfirmed {
                statusMessage = "Recognized — unlocking…"
                let sinceFirstFrame = firstFrameAt.map { Self.ms(from: $0) } ?? 0
                Self.timingLog.info("matched after \(processedFrames, privacy: .public) frames, \(sinceFirstFrame, privacy: .public) ms of recognition, \(Self.ms(from: scanStartedAt), privacy: .public) ms total")
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                lastOutcome = "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.centroidSimilarity)), \(livenessNote)."
                guard await pocController.injectStoredPassword(requireAuthoritativeLock: true) else {
                    return .injectionFailed
                }
                return .matched
            }

            try? await Task.sleep(nanoseconds: Self.framePollInterval)
        }
        if livenessEnabled && !livenessConfirmed {
            Self.timingLog.info("scan window ended: liveness never confirmed (\(processedFrames, privacy: .public) frames)")
        } else {
            Self.timingLog.info("scan window ended without a match (\(processedFrames, privacy: .public) frames)")
        }
        return .noResolution
    }
}
