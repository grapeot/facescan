import ARKit
import AVFoundation
import Combine
import CoreImage
import Foundation
import simd
import UIKit

final class FaceScanSession: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var keyframeCount = 0
    @Published private(set) var depthMissingCount = 0
    @Published private(set) var depthTotalCount = 0
    @Published private(set) var statusLine = "idle"
    @Published private(set) var runId = ""

    let arSession = ARSession()
    let sessionQueue = DispatchQueue(label: "facescan.session")

    private let ioQueue = DispatchQueue(label: "facescan.io")
    private let counterLock = NSLock()
    private let ciContext = CIContext(options: nil)
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private var didStart = false
    private var recording = false
    private var worldTrackingEnabled = false
    private var didDegradeWorldTracking = false
    private var lastKeptPose: simd_float4x4?
    private var frames: [FrameRecord] = []
    private var scanDir: URL?
    private var activeRunId = ""
    private var heartbeatsEnabled = false
    private var persistedState = "idle"
    private var depthMissing = 0
    private var depthTotal = 0
    private var probeTracked = 0
    private var probeDepthReceived = 0
    private var probeFirstTrackedAt: CFTimeInterval = 0
    private var heartbeatTimer: Timer?

    // TrueDepth delivers depth at a lower rate than the camera feed, so
    // `capturedDepthData` is nil on most render frames. That sparsity is normal
    // and must NOT be mistaken for "world tracking gives no depth". Only degrade
    // when a tracked face has been seen for a while yet no depth arrived at all.
    private let degradeMinTrackedFrames = 20
    private let degradeProbeSeconds: CFTimeInterval = 3.0

    override init() {
        super.init()
        arSession.delegateQueue = sessionQueue
        arSession.delegate = self
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            runConfiguration(reset: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.runConfiguration(reset: true)
                    } else {
                        self.statusLine = "camera denied"
                    }
                }
            }
        default:
            statusLine = "camera denied"
        }
        ioQueue.async { [weak self] in
            self?.writeStatus(state: "idle")
        }
    }

    func startRecording(runId raw: String?) {
        start()
        let resolved = RunIdentifier.resolve(raw)
        sessionQueue.sync {
            recording = false
        }
        ioQueue.sync {
            heartbeatsEnabled = false
            if persistedState == "recording" {
                finishRecordingLocked()
            }
        }
        let dir = documentsURL().appendingPathComponent("scan_\(resolved)", isDirectory: true)
        var created = false
        ioQueue.sync {
            if fileManager.fileExists(atPath: dir.path) {
                try? fileManager.removeItem(at: dir)
            }
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                created = true
            } catch {
                created = false
            }
            guard created else { return }
            scanDir = dir
            activeRunId = resolved
            frames = []
            counterLock.lock()
            depthMissing = 0
            depthTotal = 0
            counterLock.unlock()
            heartbeatsEnabled = true
            writeStatus(state: "recording")
        }
        guard created else {
            statusLine = "cannot create scan directory"
            return
        }
        sessionQueue.sync {
            lastKeptPose = nil
            recording = true
        }
        DispatchQueue.main.async {
            self.runId = resolved
            self.isRecording = true
            self.keyframeCount = 0
            self.depthMissingCount = 0
            self.depthTotalCount = 0
            self.statusLine = "recording"
            self.armHeartbeat()
        }
    }

    func stopRecording() {
        sessionQueue.sync {
            recording = false
        }
        DispatchQueue.main.async {
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
        }
        ioQueue.sync {
            heartbeatsEnabled = false
            finishRecordingLocked()
        }
        DispatchQueue.main.async {
            self.isRecording = false
            self.keyframeCount = self.framesCount()
            self.statusLine = "stopped"
        }
    }

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "facescan" else { return }
        let action = (url.host ?? url.lastPathComponent).lowercased()
        switch action {
        case "record":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "run_id" })?
                .value
            startRecording(runId: query)
        case "stop":
            stopRecording()
        default:
            break
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let missing = frame.capturedDepthData == nil
        let faceTracked = frame.anchors.contains { ($0 as? ARFaceAnchor)?.isTracked == true }
        if worldTrackingEnabled && !didDegradeWorldTracking && faceTracked {
            probeTracked += 1
            if !missing { probeDepthReceived += 1 }
            if probeFirstTrackedAt == 0 { probeFirstTrackedAt = frame.timestamp }
            let elapsed = frame.timestamp - probeFirstTrackedAt
            if probeTracked >= degradeMinTrackedFrames,
               elapsed >= degradeProbeSeconds,
               probeDepthReceived == 0 {
                didDegradeWorldTracking = true
                worldTrackingEnabled = false
                lastKeptPose = nil
                DispatchQueue.main.async { [weak self] in
                    self?.applyDegradedConfiguration()
                }
            }
        }
        guard recording else { return }
        counterLock.lock()
        depthTotal += 1
        if missing { depthMissing += 1 }
        let total = depthTotal
        let missingCount = depthMissing
        counterLock.unlock()
        DispatchQueue.main.async {
            self.depthTotalCount = total
            self.depthMissingCount = missingCount
        }
        guard let depth = frame.capturedDepthData, faceTracked else { return }
        let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first
        let pose = frame.camera.transform
        // Select keyframes by how much new surface we have seen. When the user
        // rotates their head instead of moving the phone, the camera barely
        // moves but the face does; keying off camera motion alone would throw
        // away the entire scan. Prefer face-anchor motion when it is available.
        let selectionPose = faceAnchor?.transform ?? pose
        if let last = lastKeptPose, !shouldKeep(pose: selectionPose, last: last) {
            return
        }
        lastKeptPose = selectionPose
        accept(frame: frame, depth: depth, pose: pose, facePose: faceAnchor?.transform)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let degrade = worldTrackingEnabled && !didDegradeWorldTracking
        if degrade {
            didDegradeWorldTracking = true
            worldTrackingEnabled = false
            lastKeptPose = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if degrade {
                self.applyDegradedConfiguration()
            } else {
                self.statusLine = "session failed"
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {}

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.runConfiguration(reset: false)
        }
    }

    private func runConfiguration(reset: Bool) {
        arSession.delegateQueue = sessionQueue
        arSession.delegate = self
        guard ARFaceTrackingConfiguration.isSupported else {
            statusLine = "face tracking unsupported"
            return
        }
        let enableWorld = sessionQueue.sync { () -> Bool in
            let enabled = !didDegradeWorldTracking && ARFaceTrackingConfiguration.supportsWorldTracking
            worldTrackingEnabled = enabled
            if reset {
                probeTracked = 0
                probeDepthReceived = 0
                probeFirstTrackedAt = 0
                lastKeptPose = nil
            }
            return enabled
        }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isWorldTrackingEnabled = enableWorld
        var options: ARSession.RunOptions = []
        if reset {
            options = [.resetTracking, .removeExistingAnchors]
        }
        arSession.run(config, options: options)
        if !isRecording {
            statusLine = enableWorld ? "idle" : "idle, no world tracking"
        }
    }

    private func applyDegradedConfiguration() {
        statusLine = isRecording ? "recording, world tracking off" : "world tracking off"
        guard ARFaceTrackingConfiguration.isSupported else { return }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isWorldTrackingEnabled = false
        arSession.delegateQueue = sessionQueue
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func shouldKeep(pose: simd_float4x4, last: simd_float4x4) -> Bool {
        let delta = pose.columns.3 - last.columns.3
        let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
        let relative = simd_mul(simd_inverse(last), pose)
        let trace = relative.columns.0.x + relative.columns.1.y + relative.columns.2.z
        let cosine = min(1, max(-1, (trace - 1) / 2))
        let angle = acos(cosine)
        return distance > ScanContract.translationThreshold || angle > ScanContract.rotationThreshold
    }

    private func accept(frame: ARFrame, depth: AVDepthData, pose: simd_float4x4, facePose: simd_float4x4?) {
        let copied: (bytes: Data, width: Int, height: Int)
        do {
            copied = try DepthBin.tightFloat32(from: depth)
        } catch {
            return
        }
        guard copied.bytes.count == copied.width * copied.height * 4 else { return }
        let intrinsics = intrinsics(for: depth, frame: frame, width: copied.width, height: copied.height)
        let timestamp = frame.timestamp
        let colorWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let colorHeight = CVPixelBufferGetHeight(frame.capturedImage)
        let confidence = depth.depthDataQuality == .low ? 0.5 : 1.0
        let retained = frame
        ioQueue.async { [weak self] in
            self?.writeKeyframe(
                depthBytes: copied.bytes,
                width: copied.width,
                height: copied.height,
                intrinsics: intrinsics,
                pose: MatrixCodec.rowMajor(pose),
                facePose: facePose.map { MatrixCodec.rowMajor($0) },
                timestamp: timestamp,
                colorWidth: colorWidth,
                colorHeight: colorHeight,
                confidence: confidence,
                frame: retained
            )
        }
    }

    private func intrinsics(for depth: AVDepthData, frame: ARFrame, width: Int, height: Int) -> [Double] {
        if let calib = depth.cameraCalibrationData ?? depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).cameraCalibrationData {
            let ref = calib.intrinsicMatrixReferenceDimensions
            if ref.width > 0, ref.height > 0 {
                return MatrixCodec.scaleToDepth(calib.intrinsicMatrix, reference: ref, depthWidth: width, depthHeight: height)
            }
        }
        return MatrixCodec.scaleToDepth(
            frame.camera.intrinsics,
            reference: frame.camera.imageResolution,
            depthWidth: width,
            depthHeight: height
        )
    }

    private func writeKeyframe(
        depthBytes: Data,
        width: Int,
        height: Int,
        intrinsics: [Double],
        pose: [Double],
        facePose: [Double]?,
        timestamp: Double,
        colorWidth: Int,
        colorHeight: Int,
        confidence: Double,
        frame: ARFrame
    ) {
        guard heartbeatsEnabled, let dir = scanDir else { return }
        guard depthBytes.count == width * height * 4, pose.count == 16, intrinsics.count == 9 else { return }
        guard let jpeg = encodeJPEG(frame.capturedImage) else { return }
        let index = frames.count
        let depthName = String(format: "depth_%04d.bin", index)
        let colorName = String(format: "color_%04d.jpg", index)
        let depthURL = dir.appendingPathComponent(depthName)
        let colorURL = dir.appendingPathComponent(colorName)
        do {
            try depthBytes.write(to: depthURL, options: .atomic)
            try jpeg.write(to: colorURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: depthURL)
            try? fileManager.removeItem(at: colorURL)
            return
        }
        let written = (try? Data(contentsOf: depthURL))?.count ?? -1
        guard written == width * height * 4 else {
            try? fileManager.removeItem(at: depthURL)
            try? fileManager.removeItem(at: colorURL)
            return
        }
        frames.append(
            FrameRecord(
                index: index,
                timestamp: timestamp,
                pose: pose,
                intrinsics: intrinsics,
                depthWidth: width,
                depthHeight: height,
                colorWidth: colorWidth,
                colorHeight: colorHeight,
                depthFile: depthName,
                colorFile: colorName,
                confidence: confidence,
                facePose: facePose
            )
        )
        let count = frames.count
        DispatchQueue.main.async {
            self.keyframeCount = count
        }
    }

    private func encodeJPEG(_ buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, !extent.isEmpty else { return nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let data = ciContext.jpegRepresentation(of: image, colorSpace: srgb, options: [:]) {
            return data
        }
        guard let cg = ciContext.createCGImage(image, from: extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    private func finishRecordingLocked() {
        let dir = scanDir
        let run = activeRunId
        if let dir {
            let meta = ScanMetaDocument(
                schemaVersion: ScanContract.schemaVersion,
                runId: run,
                deviceModel: DeviceModel.identifier,
                worldTrackingEnabled: worldTrackingEnabled,
                frames: frames
            )
            if let data = try? encoder.encode(meta) {
                try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            }
        }
        writeStatus(state: "stopped")
    }

    private func writeStatus(state: String) {
        if state == "idle" && (persistedState == "recording" || persistedState == "stopped") {
            return
        }
        if state == "recording" && !heartbeatsEnabled {
            return
        }
        counterLock.lock()
        let missing = depthMissing
        let total = depthTotal
        counterLock.unlock()
        let doc = StatusDocument(
            schemaVersion: ScanContract.schemaVersion,
            runId: activeRunId,
            state: state,
            keyframes: frames.count,
            depthMissing: missing,
            depthTotal: total,
            updatedAt: Date().timeIntervalSince1970
        )
        guard let data = try? encoder.encode(doc) else { return }
        let url = documentsURL().appendingPathComponent("status.json")
        try? data.write(to: url, options: .atomic)
        persistedState = state
    }

    private func armHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.ioQueue.async {
                guard let self, self.heartbeatsEnabled else { return }
                self.writeStatus(state: "recording")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func framesCount() -> Int {
        ioQueue.sync { frames.count }
    }

    private func documentsURL() -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
