import AVFoundation
import Observation
import UIKit

struct PlannerSample: Identifiable, Sendable {
    let id: Int
    let time: TimeInterval
    let heading: Float
    let rawHeading: Float
    let urgency: Float
    let nearest: Float?
}

/// App state and the glue between the pipeline, feedback, navigation, and the UI.
/// Owns no perception logic of its own.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Mode: String, CaseIterable, Identifiable {
        case passive, guided
        var id: String { rawValue }
        var title: String { self == .passive ? "Passive" : "Guided" }
    }

    enum RunState: Equatable {
        case idle
        case live
        case replay(String)
    }

    var mode: Mode = .passive
    private(set) var runState: RunState = .idle
    var destination = ""
    var verbosity: Verbosity = .normal {
        didSet {
            feedback.verbosity = verbosity
            UserDefaults.standard.set(verbosity.rawValue, forKey: Self.verbosityKey)
        }
    }
    var debugVisible = false {
        didSet {
            let wanted = debugVisible
            runner.update { $0.wantsDebug = wanted }
            updateBrightness()
        }
    }
    var muteReplay = false {
        didSet { if isReplaying { feedback.muted = muteReplay } }
    }

    private(set) var snapshot: DebugSnapshot?
    private(set) var history: [PlannerSample] = []
    private(set) var statusMessage = "Ready"
    private(set) var lastPlanner = PlannerOutput.idle
    private(set) var floorStatus: FloorEstimator.Status = .calibrating(progress: 0)
    private(set) var trackingMessage: String?
    private(set) var recordingURL: URL?
    private(set) var recordings: [Recording] = []
    private(set) var lastReplaySummary: String?
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var batteryLevel: Float = -1
    private(set) var navigationState: GuidedNavigator.State = .idle

    let tuningStore = TuningStore()
    let feedback = FeedbackEngine()
    @ObservationIgnored let navigator = GuidedNavigator()
    @ObservationIgnored private let runner = PipelineRunner()
    @ObservationIgnored private var lastAnnouncement: [String: TimeInterval] = [:]
    @ObservationIgnored private var previousBrightness: CGFloat?
    @ObservationIgnored private var sampleCounter = 0
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var hasTrackedNormally = false

    private static let verbosityKey = "wayfinder.verbosity"
    private let historyLength = 300

    var isRunning: Bool { runState != .idle }
    var isReplaying: Bool {
        if case .replay = runState { return true }
        return false
    }
    var lidarSupported: Bool { ARFrameSource.isSupported }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.verbosityKey), let stored = Verbosity(rawValue: raw) {
            verbosity = stored
        }
        feedback.verbosity = verbosity
        feedback.tuning = { [weak self] in self?.tuningStore.tuning ?? Tuning() }

        runner.onResult = { @Sendable [weak self] result, snapshot in
            Task { @MainActor in self?.handle(result, snapshot: snapshot) }
        }
        runner.onStatus = { @Sendable [weak self] status in
            Task { @MainActor in self?.handleSourceStatus(status) }
        }

        navigator.onSpeakText = { [weak self] text in self?.feedback.sayText(text) }
        navigator.onSpeakPhrase = { [weak self] phrase in self?.feedback.say(phrase, tier: .guided) }
        navigator.onStateChange = { [weak self] state in self?.navigationState = state }

        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyThermalState(ProcessInfo.processInfo.thermalState) }
        }
        refreshRecordings()
        observeTuning()
    }

    // MARK: - Start and stop

    func toggle() {
        isRunning ? stop(announce: true) : start()
    }

    func start() {
        guard !isRunning else { return }
        guard lidarSupported else {
            statusMessage = "This phone has no LiDAR."
            feedback.say("no_lidar")
            return
        }
        feedback.muted = false
        feedback.start()
        resetSessionState()
        runState = .live
        statusMessage = "Calibrating"
        UIApplication.shared.isIdleTimerDisabled = true
        updateBrightness()
        runner.startLive(options: currentOptions())

        feedback.say(mode == .passive ? "passive_on" : "guided_on")
        feedback.say("calibrating")
        if feedback.speech.outputVolume < 0.7 {
            feedback.say("volume_low")
        }
        if mode == .guided {
            let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                feedback.sayText("No destination set. Guiding around obstacles only.", tier: .status)
            } else {
                navigator.start(query: query)
            }
        }
        checkBattery()
    }

    func stop(announce: Bool) {
        guard isRunning else { return }
        if recordingURL != nil { toggleRecording() }
        runner.stop()
        navigator.stop()
        feedback.stop()
        if announce { feedback.say("stopped") }
        runState = .idle
        statusMessage = "Stopped"
        UIApplication.shared.isIdleTimerDisabled = false
        updateBrightness()
    }

    func startReplay(_ recording: Recording) {
        if isRunning { stop(announce: false) }
        feedback.start()
        feedback.muted = muteReplay
        resetSessionState()
        runState = .replay(recording.name)
        statusMessage = "Replaying \(recording.name)"
        lastReplaySummary = nil
        runner.startReplay(directory: recording.url, options: currentOptions())
    }

    // MARK: - Commands (also used by Siri intents)

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        let wasRunning = runState == .live
        if wasRunning { stop(announce: false) }
        mode = newMode
        if wasRunning { start() }
    }

    func navigate(to place: String) {
        destination = place
        if runState == .live && mode == .guided {
            navigator.start(query: place)
        } else {
            if isRunning { stop(announce: false) }
            mode = .guided
            start()
        }
    }

    func quieter() {
        verbosity = verbosity.quieter
        feedback.say("quieter")
    }

    func moreDetail() {
        verbosity = verbosity.louder
        feedback.say("more_detail")
    }

    func toggleRecording() {
        if recordingURL != nil {
            recordingURL = nil
            runner.stopRecording { @Sendable [weak self] frames in
                Task { @MainActor in
                    self?.statusMessage = "Saved \(frames) frames"
                    self?.refreshRecordings()
                }
            }
        } else {
            let metadata = [
                "device": UIDevice.current.name,
                "system": UIDevice.current.systemVersion,
                "mode": mode.rawValue,
                "tuning": tuningStore.exportJSON(),
            ]
            runner.startRecording(tag: mode.rawValue, metadata: metadata) { @Sendable [weak self] url in
                Task { @MainActor in self?.recordingURL = url }
            }
        }
    }

    func refreshRecordings() {
        recordings = SessionRecorder.list()
    }

    func deleteRecording(_ recording: Recording) {
        SessionRecorder.delete(recording)
        refreshRecordings()
    }

    // MARK: - Pipeline results

    private func handle(_ result: PerceptionResult, snapshot: DebugSnapshot?) {
        guard isRunning else { return }
        lastPlanner = result.planner
        updateFloorStatus(result.floorStatus)

        if mode == .guided {
            navigator.updateBodyYaw(result.bodyYaw)
            runner.setGoalHeading(navigator.relativeGoalHeading)
        }

        // Hold cues during the first calibration so the user is not steered by a guessed floor.
        if case .calibrating = result.floorStatus {
        } else {
            feedback.update(result.planner, frameTimestamp: isReplaying ? nil : result.timestamp)
        }

        sampleCounter += 1
        history.append(PlannerSample(
            id: sampleCounter, time: result.timestamp, heading: result.planner.heading,
            rawHeading: result.planner.rawHeading, urgency: result.planner.urgency,
            nearest: result.planner.nearestObstacle
        ))
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
        if sampleCounter % 1800 == 0 { checkBattery() }
        if let snapshot { self.snapshot = snapshot }
    }

    private func handleSourceStatus(_ status: FrameSourceStatus) {
        switch status {
        case .running:
            trackingMessage = nil
        case .trackingNormal:
            trackingMessage = nil
            hasTrackedNormally = true
        case .trackingLimited(let reason):
            trackingMessage = "Tracking limited: \(reason)"
            // Every session starts limited while ARKit initializes; only a loss after that is news.
            if runState == .live && hasTrackedNormally { announce("tracking_lost", every: 10) }
        case .interrupted:
            trackingMessage = "Camera interrupted"
        case .failed(let message):
            statusMessage = message
            stop(announce: true)
        case .finished:
            let hash = snapshot.map { String(format: "%016llx", $0.plannerHash) } ?? "n/a"
            lastReplaySummary = "Replay finished. Planner hash \(hash)"
            statusMessage = lastReplaySummary ?? ""
            runner.stop()
            feedback.stop()
            runState = .idle
        }
    }

    private func updateFloorStatus(_ status: FloorEstimator.Status) {
        let previous = floorStatus
        floorStatus = status
        guard status != previous else { return }
        switch status {
        case .ready:
            statusMessage = isReplaying ? statusMessage : "Guiding"
            if case .calibrating = previous { feedback.say("ready") }
        case .cannotSeeFloor:
            statusMessage = "Can't see the floor"
            announce("tilt_down", every: 10)
        case .calibrating:
            break
        }
    }

    // MARK: - Housekeeping

    private func resetSessionState() {
        history.removeAll()
        snapshot = nil
        floorStatus = .calibrating(progress: 0)
        lastAnnouncement.removeAll()
        hasTrackedNormally = false
    }

    private func currentOptions() -> PipelineRunner.Options {
        var options = PipelineRunner.Options()
        options.tuning = tuningStore.tuning
        options.wantsDebug = debugVisible
        options.thermalThrottle = thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        options.alignToNorth = mode == .guided
        return options
    }

    private func observeTuning() {
        withObservationTracking {
            _ = tuningStore.tuning
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let tuning = self.tuningStore.tuning
                self.runner.update { $0.tuning = tuning }
                self.observeTuning()
            }
        }
    }

    private func applyThermalState(_ state: ProcessInfo.ThermalState) {
        thermalState = state
        switch state {
        case .critical:
            if isRunning {
                // Stop first: stopping clears the speech queue, which would swallow the warning.
                stop(announce: false)
                announce("too_hot", every: 0)
            }
        case .serious:
            runner.update { $0.thermalThrottle = true }
            if isRunning { announce("warm", every: 60) }
        default:
            runner.update { $0.thermalThrottle = false }
        }
    }

    private func checkBattery() {
        batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel >= 0, batteryLevel < 0.15, isRunning {
            announce("battery_low", every: 600)
        }
    }

    /// Say a status phrase at most once per `interval` seconds.
    private func announce(_ phrase: String, every interval: TimeInterval) {
        let now = FeedbackEngine.now
        if let last = lastAnnouncement[phrase], now - last < interval { return }
        lastAnnouncement[phrase] = now
        feedback.say(phrase)
    }

    /// The screen faces the user's chest while walking, so keep it dark unless someone is debugging.
    private func updateBrightness() {
        let screen = UIScreen.main
        if runState == .live && !debugVisible {
            if previousBrightness == nil { previousBrightness = screen.brightness }
            screen.brightness = 0.05
        } else if let previous = previousBrightness {
            screen.brightness = previous
            previousBrightness = nil
        }
    }
}
