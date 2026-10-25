import ARKit
import CoreImage
import ImageIO

/// Live LiDAR capture. All delegate callbacks, and every property below, live on the pipeline queue.
final class ARFrameSource: NSObject, FrameSource, ARSessionDelegate {
    struct Settings {
        var targetFPS: Double = 30
        var useSmoothedDepth = false
        /// Color frames per second to encode as JPEG; 0 disables color capture.
        var colorFPS: Double = 0
        /// Color frames per second for the obstacle detector; 0 disables them.
        var detectorFPS: Double = 0
        /// `.gravityAndHeading` points -Z at true north, which Guided mode needs for its bearing.
        var alignToNorth = false
    }

    var onFrame: ((FrameBundle) -> Void)?
    var onStatus: ((FrameSourceStatus) -> Void)?
    /// Read on the pipeline queue for every frame; update it only from that queue.
    var settings = Settings()

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private let session = ARSession()
    private var lastEmit: TimeInterval = 0
    private var lastColor: TimeInterval = 0
    private var lastDetectorImage: TimeInterval = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(queue: DispatchQueue) {
        super.init()
        session.delegateQueue = queue
        session.delegate = self
    }

    func start() {
        guard Self.isSupported else {
            onStatus?(.failed("This phone has no LiDAR."))
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = settings.useSmoothedDepth ? [.smoothedSceneDepth] : [.sceneDepth]
        configuration.worldAlignment = settings.alignToNorth ? .gravityAndHeading : .gravity
        configuration.planeDetection = []
        configuration.isAutoFocusEnabled = true
        lastEmit = 0
        lastColor = 0
        lastDetectorImage = 0
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        onStatus?(.running)
    }

    func stop() {
        session.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let timestamp = frame.timestamp
        let interval = 1.0 / max(1, settings.targetFPS)
        // Small tolerance so 60 Hz delivery reliably yields every other frame at 30 fps.
        guard timestamp - lastEmit >= interval - 0.004 else { return }
        lastEmit = timestamp

        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depth = Self.copyDepth(sceneDepth.depthMap)
        let confidence = sceneDepth.confidenceMap.map(Self.copyConfidence)

        // ARKit intrinsics refer to the captured image; scale them to the depth map.
        let imageSize = frame.camera.imageResolution
        let sx = Float(depth.width) / Float(imageSize.width)
        let sy = Float(depth.height) / Float(imageSize.height)
        var intrinsics = frame.camera.intrinsics
        intrinsics[0][0] *= sx
        intrinsics[1][1] *= sy
        intrinsics[2][0] *= sx
        intrinsics[2][1] *= sy

        var jpeg: Data?
        if settings.colorFPS > 0, timestamp - lastColor >= 1.0 / settings.colorFPS {
            lastColor = timestamp
            jpeg = encodeJPEG(frame.capturedImage)
        }
        var detectorImage: ColorImage?
        if settings.detectorFPS > 0, timestamp - lastDetectorImage >= 1.0 / settings.detectorFPS {
            lastDetectorImage = timestamp
            // A copy, so the detector never holds one of ARKit's few capture buffers.
            detectorImage = makeImage(frame.capturedImage).map(ColorImage.init)
        }

        let bundle = FrameBundle(
            timestamp: timestamp,
            depth: depth,
            confidence: confidence,
            colorJPEG: jpeg,
            intrinsics: intrinsics,
            cameraTransform: frame.camera.transform,
            trackingNormal: frame.camera.trackingState == .normal,
            colorImage: detectorImage
        )
        onFrame?(bundle)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            onStatus?(.trackingNormal)
        case .notAvailable:
            onStatus?(.trackingLimited("not available"))
        case .limited(let reason):
            onStatus?(.trackingLimited(String(describing: reason)))
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onStatus?(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        onStatus?(.running)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onStatus?(.failed(error.localizedDescription))
    }

    // MARK: - Copying

    private static func copyDepth(_ buffer: CVPixelBuffer) -> DepthImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: .nan, count: width * height)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            values.withUnsafeMutableBytes { dst in
                for row in 0..<height {
                    memcpy(dst.baseAddress! + row * width * 4, base + row * bytesPerRow, width * 4)
                }
            }
        }
        return DepthImage(width: width, height: height, values: values)
    }

    private static func copyConfidence(_ buffer: CVPixelBuffer) -> ConfidenceImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var values = [UInt8](repeating: 0, count: width * height)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            values.withUnsafeMutableBytes { dst in
                for row in 0..<height {
                    memcpy(dst.baseAddress! + row * width, base + row * bytesPerRow, width)
                }
            }
        }
        return ConfidenceImage(width: width, height: height, values: values)
    }

    /// About 640x480 for the detector.
    private func makeImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 640.0 / max(1, image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    /// About 640x480, quality 0.5: enough to see what the camera sees, small enough to record.
    private func encodeJPEG(_ buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 640.0 / max(1, image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [quality: 0.5]
        )
    }
}
