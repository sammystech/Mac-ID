//
//  EyeContact.swift
//  Mac ID
//
//  "Require eye contact": unlock only while the person in front of the camera has their eyes open and
//  is looking at the Mac. Stops an unlock by someone holding the Mac up to a sleeping face, or catching
//  you while you're turned away.
//
//  "At the Mac" means the camera or the screen, deliberately. Calibration showed the two can't be told
//  apart reliably from a laptop camera: pupils don't move measurably between the camera and the middle
//  of the screen, and the only difference, the eyelids opening slightly wider (0.32 vs 0.28 eye
//  openness), depends too much on the shape of each person's eyes to gate on.
//
//  Built from what Vision already returns for every frame on the unlock path, so it costs almost
//  nothing: head yaw and pitch from the rectangles pass, and the eye outlines and pupil points from
//  the landmarks pass. Gaze is the head's direction plus how far the pupils sit off-centre in the eye
//  opening. Thresholds come from src/tools/eye_contact_probe.swift, run on a real face: looking at the
//  camera, at the screen, away, and with eyes closed.
//

import CoreGraphics
import Vision

nonisolated enum EyeContact {
    struct Reading: Equatable {
        /// Head rotation, radians, camera-relative (see FaceDetector).
        var yaw: Float
        var pitch: Float
        /// Average eye opening (height / width of the eye outline).
        var eyeOpenness: CGFloat
        /// Pupil position within the eye opening, -1…1 across (image space) and -1…1 down. Only x
        /// gates; y is kept for the scan log.
        var pupilX: CGFloat
        var pupilY: CGFloat
    }

    // Calibrated with eye_contact_probe on a real face (2026-09-24, ~95 frames per phase). Looking at
    // the camera or anywhere on the screen passed 100% of frames; looking away or eyes closed, 0%.
    //   head yaw      at the Mac |≤0.02|, looking away left 0.23–0.27
    //   pupil x       at the Mac |≤0.02|, looking away 0.32–0.45 (either side, head still or turned)
    //   eye openness  at the Mac 0.23–0.32 (lower toward the bottom of the screen), eyes closed 0.11
    //   pitch         0.12–0.25 in every phase: camera-relative, so it only rules out a head bowed
    //                 right down (a phone in the lap), not where on the screen someone looks
    // Pupil y isn't used: it sat at about -0.25 whatever the person looked at.
    static let maxHeadYaw: Float = 0.22
    static let maxHeadPitch: Float = 0.45
    static let minEyeOpenness: CGFloat = 0.17
    static let maxPupilX: CGFloat = 0.18
    /// Consecutive attentive frames needed, so a single lucky frame mid-glance doesn't count.
    static let requiredFrames = 2

    static func reading(for face: DetectedFace) -> Reading? {
        guard let landmarks = face.landmarks, let yaw = face.yaw, let pitch = face.pitch,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye
        else { return nil }
        let size = face.imageSize
        guard let leftOpen = LandmarkGeometry.eyeAspectRatio(of: leftEye, imageSize: size),
              let rightOpen = LandmarkGeometry.eyeAspectRatio(of: rightEye, imageSize: size),
              let left = pupilOffset(eye: leftEye, pupil: landmarks.leftPupil, imageSize: size),
              let right = pupilOffset(eye: rightEye, pupil: landmarks.rightPupil, imageSize: size)
        else { return nil }
        return Reading(
            yaw: yaw, pitch: pitch,
            eyeOpenness: (leftOpen + rightOpen) / 2,
            pupilX: (left.x + right.x) / 2, pupilY: (left.y + right.y) / 2
        )
    }

    static func isLooking(_ reading: Reading) -> Bool {
        abs(reading.yaw) <= maxHeadYaw
            && abs(reading.pitch) <= maxHeadPitch
            && reading.eyeOpenness >= minEyeOpenness
            && abs(reading.pupilX) <= maxPupilX
    }

    /// Where the pupil sits inside the eye outline's bounding box, centre = 0, edges = ±1.
    private static func pupilOffset(eye: VNFaceLandmarkRegion2D, pupil: VNFaceLandmarkRegion2D?,
                                    imageSize: CGSize) -> CGPoint? {
        guard let pupil, let point = LandmarkGeometry.imagePoints(of: pupil, imageSize: imageSize).first else {
            return nil
        }
        let outline = LandmarkGeometry.imagePoints(of: eye, imageSize: imageSize)
        guard let minX = outline.map(\.x).min(), let maxX = outline.map(\.x).max(),
              let minY = outline.map(\.y).min(), let maxY = outline.map(\.y).max(),
              maxX > minX, maxY > minY
        else { return nil }
        return CGPoint(
            x: (point.x - (minX + maxX) / 2) / ((maxX - minX) / 2),
            y: (point.y - (minY + maxY) / 2) / ((maxY - minY) / 2)
        )
    }
}
