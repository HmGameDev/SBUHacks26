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
        didSet { updateDebugWanted() }
    }
    /// The home screen is showing the live camera view.
    var cameraPreviewVisible = false {
        didSet { updateDebugWanted() }
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
    private(set) var navigationProgress: GuidedNavigator.Progress?
    private(set) var searchResults: [GuidedNavigator.Place] = []
    private(set) var isSearching = false
    private(set) var searchMessage: String?

    let tuningStore = TuningStore()
    let preferencesStore = PreferencesStore()
    let feedback = FeedbackEngine()
    let speechInput = SpeechInput()
    @ObservationIgnored let navigator = GuidedNavigator()
    @ObservationIgnored private let runner = PipelineRunner()
    @ObservationIgnored private var lastAnnouncement: [String: TimeInterval] = [:]
    @ObservationIgnored private var previousBrightness: CGFloat?
    @ObservationIgnored private var sampleCounter = 0
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    /// A place picked from the search results, routed to as soon as guidance starts.
    @ObservationIgnored private var pendingPlace: GuidedNavigator.Place?
    @ObservationIgnored private var hasTrackedNormally = false

    private static let verbosityKey = "scout.verbosity"
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
        feedback.preferences = { [weak self] in self?.preferencesStore.preferences ?? Preferences() }
        speechInput.onSessionReleased = { [weak self] in self?.feedback.speech.configureSession() }

        runner.onResult = { @Sendable [weak self] result, snapshot in
            Task { @MainActor in self?.handle(result, snapshot: snapshot) }
        }
        runner.onStatus = { @Sendable [weak self] status in
            Task { @MainActor in self?.handleSourceStatus(status) }
        }

        navigator.onSpeakText = { [weak self] text in self?.feedback.sayText(text) }
        navigator.onSpeakPhrase = { [weak self] phrase in self?.feedback.say(phrase, tier: .guided) }
        navigator.onStateChange = { [weak self] state in self?.navigationState = state }
        navigator.onProgress = { [weak self] progress in self?.navigationProgress = progress }

        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyThermalState(ProcessInfo.processInfo.thermalState) }
        }
        refreshRecordings()
        observeTuning()
        observeNameObstacles()
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
            if let place = pendingPlace {
                pendingPlace = nil
                navigator.start(place: place)
            } else if query.isEmpty {
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

    // MARK: - Destination search

    /// Search for places and read the top results aloud. The user picks one, or says Go for the first.
    func searchDestination(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        destination = query
        isSearching = true
        searchMessage = "Searching for \(query)…"
        searchResults = []
        feedback.start()
        Task { @MainActor in
            do {
                let places = try await navigator.search(query)
                isSearching = false
                searchResults = places
                if let first = places.first {
                    searchMessage = places.count == 1 ? "1 place found" : "\(places.count) places found"
                    let more = places.count > 1 ? " \(places.count - 1) more on screen." : ""
                    feedback.sayText("Top result: \(first.spoken).\(more) Tap a place to go.", tier: .status)
                } else {
                    searchMessage = "Nothing found for \(query)"
                    feedback.sayText("I couldn't find \(query). Try another name.", tier: .status)
                }
            } catch {
                isSearching = false
                searchMessage = "Search failed. Check the internet connection."
                feedback.sayText("Search failed. Check the internet connection.", tier: .status)
            }
        }
    }

    /// Say the destination: listen, then search for what was heard.
    func dictateDestination() {
        if speechInput.isListening {
            speechInput.stop()
            return
        }
        // Quiet first, so the microphone does not hear the app. Stopping through the engine keeps the
        // cue arbiter in step; the next frame brings the proximity pulse back.
        feedback.stop()
        feedback.haptics.play(.doubleTap)
        speechInput.start { [weak self] text in
            guard let self else { return }
            if text.isEmpty {
                if let problem = self.speechInput.problem {
                    self.searchMessage = problem
                    self.feedback.sayText(problem, tier: .status)
                } else {
                    self.feedback.sayText("I didn't hear a place. Tap the microphone and try again.", tier: .status)
                }
            } else {
                self.searchDestination(text)
            }
        }
    }

    /// Route to a picked search result, starting guidance if it is not running.
    func go(to place: GuidedNavigator.Place) {
        destination = place.name
        searchResults = []
        searchMessage = nil
        if runState == .live && mode == .guided {
            navigator.start(place: place)
        } else {
            if isRunning { stop(announce: false) }
            mode = .guided
            pendingPlace = place
            start()
        }
    }

    /// End the route but keep obstacle guidance running.
    func stopNavigation() {
        guard navigationState.isActive || navigationProgress != nil else {
            feedback.sayText("No route is running.", tier: .status)
            return
        }
        navigator.stop()
        runner.setGoalHeading(nil)
        searchResults = []
        // Switch modes without restarting the camera, so the user is never left without obstacle warnings.
        mode = .passive
        feedback.sayText(isRunning ? "Navigation stopped. Obstacle warnings are still on." : "Navigation stopped.", tier: .status)
    }

    /// Repeat the next turn and how far is left.
    func repeatDirections() {
        guard let progress = navigationProgress else {
            feedback.sayText(navigationState.isActive ? "Still finding the route." : "No route is running.", tier: .status)
            return
        }
        var sentence = progress.nextInstruction
        if let turn = progress.distanceToNextTurn { sentence += " in \(GuidedNavigator.spokenDistance(turn))" }
        sentence += "."
        if let remaining = progress.remaining { sentence += " \(GuidedNavigator.spokenDistance(remaining)) to go." }
        feedback.sayText(sentence, tier: .guided)
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

    private var wantsDebug: Bool { debugVisible || cameraPreviewVisible }

    private func updateDebugWanted() {
        let wanted = wantsDebug
        runner.update { $0.wantsDebug = wanted }
        updateBrightness()
    }

    private func currentOptions() -> PipelineRunner.Options {
        var options = PipelineRunner.Options()
        options.tuning = tuningStore.tuning
        options.wantsDebug = wantsDebug
        options.thermalThrottle = thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        options.alignToNorth = mode == .guided
        options.identify = preferencesStore.preferences.nameObstacles
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

    private func observeNameObstacles() {
        withObservationTracking {
            _ = preferencesStore.preferences.nameObstacles
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let identify = self.preferencesStore.preferences.nameObstacles
                self.runner.update { $0.identify = identify }
                self.observeNameObstacles()
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
        if runState == .live && !wantsDebug {
            if previousBrightness == nil { previousBrightness = screen.brightness }
            screen.brightness = 0.05
        } else if let previous = previousBrightness {
            screen.brightness = previous
            previousBrightness = nil
        }
    }
}
