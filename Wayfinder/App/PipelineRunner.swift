import Foundation
import simd

/// What the debug screens draw. Built on the pipeline queue at up to 15 Hz, only while debug is open.
struct DebugSnapshot: Sendable {
    let timestamp: TimeInterval
    let fps: Double
    let processingMs: Double
    let colorJPEG: Data?
    let depth: DepthImage
    let points: [PointSample]
    let grid: OccupancyGrid
    let candidates: [GapCandidate]
    let planner: PlannerOutput
    let corridor: [SIMD2<Float>]
    let headingPath: [SIMD2<Float>]
    let floorStatus: FloorEstimator.Status
    let cameraHeight: Float?
    let trackingNormal: Bool
    let isReplay: Bool
    /// Fingerprint of every planner output since the source started. Two replays of one recording must match.
    let plannerHash: UInt64
    let frameCount: Int
    let recordingFrames: Int?
    let classifiedBoxes: [ClassifiedBox]
}

/// Owns the pipeline queue: frame source in, perception, optional recording, results out.
/// Every method hops onto the queue, so callers on the main thread never block on processing.
final class PipelineRunner {
    struct Options {
        var tuning = Tuning()
        var wantsDebug = false
        var thermalThrottle = false
        var alignToNorth = false
    }

    /// Delivered on the pipeline queue.
    var onResult: (@Sendable (PerceptionResult, DebugSnapshot?) -> Void)?
    var onStatus: (@Sendable (FrameSourceStatus) -> Void)?

    let queue = DispatchQueue(label: "wayfinder.pipeline", qos: .userInteractive)
    private let perception = PerceptionPipeline()
    private let classifier: ObstacleClassifier = NullClassifier()
    private var source: FrameSource?
    private var recorder: SessionRecorder?
    private var options = Options()
    private var goalHeading: Float?
    private var isReplay = false

    private var lastDebugTime: TimeInterval = 0
    private var lastColorJPEG: Data?
    private var recentFrameTimes: [TimeInterval] = []
    private var plannerHash: UInt64 = 0xcbf2_9ce4_8422_2325
    private var frameCount = 0

    // MARK: - Control (call from any thread)

    func startLive(options: Options) {
        queue.async {
            self.stopSource()
            self.options = options
            self.isReplay = false
            let live = ARFrameSource(queue: self.queue)
            self.attach(live)
            self.applyCaptureSettings()
            live.start()
        }
    }

    func startReplay(directory: URL, options: Options) {
        queue.async {
            self.stopSource()
            self.options = options
            self.isReplay = true
            do {
                let replay = try ReplayFrameSource(directory: directory, queue: self.queue)
                self.attach(replay)
                replay.start()
            } catch {
                self.onStatus?(.failed("Could not open recording: \(error.localizedDescription)"))
            }
        }
    }

    func stop() {
        queue.async { self.stopSource() }
    }

    func update(_ change: @escaping @Sendable (inout Options) -> Void) {
        queue.async {
            change(&self.options)
            self.perception.tuning = self.options.tuning
            self.applyCaptureSettings()
        }
    }

    func setGoalHeading(_ heading: Float?) {
        queue.async { self.goalHeading = heading }
    }

    func startRecording(tag: String?, metadata: [String: String], completion: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            let recorder = try? SessionRecorder(tag: tag, metadata: metadata)
            self.recorder = recorder
            self.applyCaptureSettings()
            completion(recorder?.directory)
        }
    }

    func stopRecording(completion: @escaping @Sendable (Int) -> Void) {
        queue.async {
            let frames = self.recorder?.frameCount ?? 0
            self.recorder?.finishWrites()
            self.recorder = nil
            self.applyCaptureSettings()
            completion(frames)
        }
    }

    // MARK: - Pipeline queue

    private func attach(_ source: FrameSource) {
        self.source = source
        perception.reset()
        perception.tuning = options.tuning
        plannerHash = 0xcbf2_9ce4_8422_2325
        frameCount = 0
        recentFrameTimes.removeAll()
        lastColorJPEG = nil
        lastDebugTime = -.infinity
        source.onFrame = { [weak self] frame in self?.process(frame) }
        source.onStatus = { [weak self] status in self?.onStatus?(status) }
    }

    private func stopSource() {
        source?.stop()
        source?.onFrame = nil
        source?.onStatus = nil
        source = nil
    }

    private func applyCaptureSettings() {
        guard let live = source as? ARFrameSource else { return }
        var settings = ARFrameSource.Settings()
        settings.targetFPS = options.thermalThrottle ? 15 : options.tuning.targetFPS
        settings.useSmoothedDepth = options.tuning.useSmoothedDepth
        settings.alignToNorth = options.alignToNorth
        if options.wantsDebug && !options.thermalThrottle {
            settings.colorFPS = 10
        } else if recorder != nil {
            settings.colorFPS = 5
        } else {
            settings.colorFPS = 0
        }
        live.settings = settings
    }

    private func process(_ frame: FrameBundle) {
        let start = DispatchTime.now().uptimeNanoseconds
        recorder?.append(frame)
        if let jpeg = frame.colorJPEG { lastColorJPEG = jpeg }

        let wantsDebug = options.wantsDebug && frame.timestamp - lastDebugTime >= 1.0 / 15.0
        let result = perception.process(frame, goalHeading: goalHeading, wantDebug: wantsDebug)
        let boxes = classifier.classify(frame)

        frameCount += 1
        foldIntoHash(result.planner)
        recentFrameTimes.append(frame.timestamp)
        if recentFrameTimes.count > 30 { recentFrameTimes.removeFirst() }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        var snapshot: DebugSnapshot?
        if wantsDebug {
            lastDebugTime = frame.timestamp
            let span = (recentFrameTimes.last ?? 0) - (recentFrameTimes.first ?? 0)
            let fps = span > 0 ? Double(recentFrameTimes.count - 1) / span : 0
            snapshot = DebugSnapshot(
                timestamp: frame.timestamp,
                fps: fps,
                processingMs: elapsedMs,
                colorJPEG: lastColorJPEG,
                depth: frame.depth,
                points: result.points,
                grid: result.grid,
                candidates: result.candidates,
                planner: result.planner,
                corridor: result.corridor,
                headingPath: result.headingPath,
                floorStatus: result.floorStatus,
                cameraHeight: result.cameraHeight,
                trackingNormal: result.trackingNormal,
                isReplay: isReplay,
                plannerHash: plannerHash,
                frameCount: frameCount,
                recordingFrames: recorder?.frameCount,
                classifiedBoxes: boxes
            )
        }
        onResult?(result, snapshot)
    }

    /// FNV-1a over quantized planner outputs.
    private func foldIntoHash(_ p: PlannerOutput) {
        let values: [Int32] = [
            Int32((p.heading * 1000).rounded()),
            Int32((p.urgency * 1000).rounded()),
            Int32(((p.nearestObstacle ?? -1) * 100).rounded()),
            Int32(((p.dropOffAhead ?? -1) * 100).rounded()),
        ]
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { bytes in
                for byte in bytes {
                    plannerHash ^= UInt64(byte)
                    plannerHash = plannerHash &* 0x100_0000_01b3
                }
            }
        }
    }
}
