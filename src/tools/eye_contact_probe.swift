//
//  eye_contact_probe.swift
//  Mac ID tools
//
//  Calibration for "Require eye contact". Speaks a short sequence of instructions (look at the camera,
//  at the screen, away, eyes closed), measures what Vision reports in each, and writes per-phase
//  statistics to eye_contact_probe.json next to this file. No images are kept or written: only
//  head angles, eye openness and pupil offsets.
//
//      swiftc -O src/tools/eye_contact_probe.swift -o /tmp/eye_contact_probe && /tmp/eye_contact_probe
//
//  The same measurements are what EyeContact.swift computes in the app, so thresholds chosen from
//  this output carry over directly.
//

import AVFoundation
import Foundation
import Vision

struct Sample: Codable {
    var yaw: Double
    var pitch: Double
    var roll: Double
    var earLeft: Double
    var earRight: Double
    var pupilX: Double      // -1 … 1 across the eye opening, averaged over both eyes (image space)
    var pupilY: Double      // -1 … 1 down the eye opening (image space, +down)
    var faceWidth: Double   // fraction of frame width
}

struct Phase {
    let key: String
    let say: String
}

let phases: [Phase] = [
    Phase(key: "camera", say: "Look straight at the camera, at the top of the screen."),
    Phase(key: "screen_middle", say: "Now look at the middle of the screen."),
    Phase(key: "screen_bottom", say: "Now look at the bottom of the screen."),
    Phase(key: "away_left", say: "Now look away to your left, off the screen."),
    Phase(key: "away_right", say: "Now look away to your right."),
    Phase(key: "eyes_closed", say: "Now close your eyes, and keep them closed until you hear done."),
    Phase(key: "camera_again", say: "Open your eyes and look straight at the camera again."),
]
let settleSeconds = 1.2
let recordSeconds = 3.5

func speak(_ text: String) {
    print("\n>>> \(text)")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    task.arguments = [text]
    try? task.run()
    task.waitUntilExit()
}

final class Probe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "probe.camera")
    private let lock = NSLock()
    private var recording: String?
    private(set) var samples: [String: [Sample]] = [:]
    private var frames = 0

    func start() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera found"]) }
        session.sessionPreset = .hd1280x720
        session.addInput(try AVCaptureDeviceInput(device: device))
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.startRunning()
    }

    func record(_ key: String?) {
        lock.lock(); recording = key; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); let key = recording; lock.unlock()
        guard let key, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer))

        // Same chain as FaceDetector: rectangles (for yaw/pitch), then landmarks on those faces.
        let rects = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([rects])) != nil, let faces = rects.results, !faces.isEmpty else { return }
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = faces
        guard (try? handler.perform([landmarksRequest])) != nil,
              let face = (landmarksRequest.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let lm = face.landmarks else { return }
        let pose = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        let size = CGSize(width: width, height: height)

        func points(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (r?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: height - $0.y) }
        }
        func ear(_ eye: [CGPoint]) -> Double? {
            guard let x0 = eye.map(\.x).min(), let x1 = eye.map(\.x).max(),
                  let y0 = eye.map(\.y).min(), let y1 = eye.map(\.y).max(), x1 > x0 else { return nil }
            return Double((y1 - y0) / (x1 - x0))
        }
        func offset(eye: [CGPoint], pupil: [CGPoint]) -> (Double, Double)? {
            guard let p = pupil.first, let x0 = eye.map(\.x).min(), let x1 = eye.map(\.x).max(),
                  let y0 = eye.map(\.y).min(), let y1 = eye.map(\.y).max(), x1 > x0, y1 > y0 else { return nil }
            return (Double((p.x - (x0 + x1) / 2) / ((x1 - x0) / 2)), Double((p.y - (y0 + y1) / 2) / ((y1 - y0) / 2)))
        }
        let leftEye = points(lm.leftEye), rightEye = points(lm.rightEye)
        guard let earL = ear(leftEye), let earR = ear(rightEye),
              let oL = offset(eye: leftEye, pupil: points(lm.leftPupil)),
              let oR = offset(eye: rightEye, pupil: points(lm.rightPupil)) else { return }

        let sample = Sample(
            yaw: pose?.yaw?.doubleValue ?? .nan, pitch: pose?.pitch?.doubleValue ?? .nan,
            roll: pose?.roll?.doubleValue ?? .nan,
            earLeft: earL, earRight: earR,
            pupilX: (oL.0 + oR.0) / 2, pupilY: (oL.1 + oR.1) / 2,
            faceWidth: Double(face.boundingBox.width))
        lock.lock(); samples[key, default: []].append(sample); lock.unlock()
    }
}

func stats(_ values: [Double]) -> [String: Double] {
    let v = values.filter { !$0.isNaN }.sorted()
    guard !v.isEmpty else { return [:] }
    func q(_ p: Double) -> Double { v[min(v.count - 1, max(0, Int((Double(v.count - 1) * p).rounded())))] }
    return ["p10": q(0.1), "median": q(0.5), "p90": q(0.9)]
}

let probe = Probe()
let semaphore = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { _ in semaphore.signal() }
semaphore.wait()
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    print("Camera access was denied. Allow it for your terminal app in System Settings → Privacy & Security → Camera, then run this again.")
    exit(1)
}
do { try probe.start() } catch { print("Couldn't start the camera: \(error.localizedDescription)"); exit(1) }

speak("Eye contact calibration. Sit where you normally sit, facing your Mac. It takes about thirty seconds.")
Thread.sleep(forTimeInterval: 0.8)
for phase in phases {
    speak(phase.say)
    Thread.sleep(forTimeInterval: settleSeconds)
    probe.record(phase.key)
    Thread.sleep(forTimeInterval: recordSeconds)
    probe.record(nil)
}
speak("Done. Thank you.")
probe.session.stopRunning()

var report: [String: Any] = [:]
for phase in phases {
    let s = probe.samples[phase.key] ?? []
    report[phase.key] = [
        "frames": s.count,
        "yaw": stats(s.map(\.yaw)), "pitch": stats(s.map(\.pitch)), "roll": stats(s.map(\.roll)),
        "ear": stats(s.map { ($0.earLeft + $0.earRight) / 2 }),
        "pupilX": stats(s.map(\.pupilX)), "pupilY": stats(s.map(\.pupilY)),
        "faceWidth": stats(s.map(\.faceWidth)),
    ]
}
let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("eye_contact_probe.json")
let data = try JSONSerialization.data(withJSONObject: ["phases": report, "raw": probe.samples.mapValues { $0.map { ["yaw": $0.yaw, "pitch": $0.pitch, "ear": ($0.earLeft + $0.earRight) / 2, "px": $0.pupilX, "py": $0.pupilY] } }], options: [.prettyPrinted, .sortedKeys])
try data.write(to: out)
print("\nSaved to \(out.path)")
for phase in phases {
    let s = probe.samples[phase.key] ?? []
    let m = { (f: (Sample) -> Double) in stats(s.map(f))["median"].map { String(format: "%+.2f", $0) } ?? "  —  " }
    print(String(format: "%-14@ %3d frames  yaw %@  pitch %@  eyes %@  pupil x %@  y %@", phase.key as NSString, s.count,
                 m(\.yaw), m(\.pitch), m { ($0.earLeft + $0.earRight) / 2 }, m(\.pupilX), m(\.pupilY)))
}
