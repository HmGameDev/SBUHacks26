import Foundation
import Observation

/// Connects the arbiter's decisions to the speaker and the vibration motor, and measures how long a cue
/// took from the frame that triggered it. Use from the main thread.
@Observable
final class FeedbackEngine {
    @ObservationIgnored let arbiter = CueArbiter()
    @ObservationIgnored let speech = SpeechChannel()
    @ObservationIgnored let haptics = HapticChannel()
    @ObservationIgnored var tuning: () -> Tuning = { Tuning() }
    @ObservationIgnored var preferences: () -> Preferences = { Preferences() } {
        didSet {
            let read = preferences
            speech.preferences = read
            haptics.strength = { read().hapticStrength }
        }
    }

    /// Bumped whenever the cue log changes, so debug views refresh.
    private(set) var logVersion = 0
    /// When true (replay with sound off), cues are decided and logged but not played.
    var muted = false

    var verbosity: Verbosity {
        get { arbiter.verbosity }
        set { arbiter.verbosity = newValue; logVersion += 1 }
    }

    var log: [CueLogEntry] { arbiter.log }
    var missingClips: [String] { speech.missingClips }

    init() {
        speech.onFinished = { [weak self] in
            self?.speechFinished()
        }
    }

    func start() {
        speech.configureSession()
        haptics.start()
    }

    func stop() {
        execute(arbiter.reset(), triggeredAt: nil)
        speech.stop()
        _ = arbiter.speechFinished(now: Self.now)
        haptics.setPulse(interval: nil)
    }

    /// One call per perception frame. `frameTimestamp` is on the uptime clock for live frames.
    func update(_ planner: PlannerOutput, frameTimestamp: TimeInterval?) {
        execute(arbiter.update(planner, now: Self.now, tuning: tuning()), triggeredAt: frameTimestamp)
    }

    func say(_ phrase: String, tier: CueTier = .status, haptic: HapticEvent? = .lightTap, reason: String = "") {
        let cue = Cue(tier: tier, phrases: [phrase], haptic: haptic)
        execute(arbiter.submit(cue, now: Self.now, tuning: tuning(), reason: reason), triggeredAt: nil)
    }

    func sayText(_ text: String, tier: CueTier = .guided, haptic: HapticEvent? = .lightTap, reason: String = "") {
        let cue = Cue(tier: tier, text: text, haptic: haptic)
        execute(arbiter.submit(cue, now: Self.now, tuning: tuning(), reason: reason), triggeredAt: nil)
    }

    /// Debug: play a cue by hand regardless of state.
    func test(_ phrase: String) {
        let tier: CueTier
        switch phrase {
        case "stop", "step_down", "stairs_up", "stairs_down": tier = .stop
        case "left", "right", "slight_left", "slight_right": tier = .steer
        default: tier = .status
        }
        say(phrase, tier: tier, haptic: nil, reason: "manual test")
    }

    // MARK: - Settings previews (play right away, cutting off whatever is playing)

    /// Bundled phrases in order, e.g. ["left", "dist_2"].
    func preview(phrases: [String]) {
        speech.play(Cue(tier: .status, phrases: phrases), interrupt: true)
    }

    /// Free text; `cloud` uses the live ElevenLabs voice when one is configured.
    func preview(text: String, cloud: Bool = false) {
        speech.play(Cue(tier: .guided, text: text), interrupt: true, allowCloud: cloud)
    }

    func preview(haptic: HapticEvent) {
        haptics.play(haptic)
    }

    /// The proximity pulse speeding up as an obstacle gets closer, over about two seconds.
    func previewPulse() {
        let t = tuning()
        for step in 0...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.5) { [weak self] in
                let u = Double(step) / 4
                self?.haptics.setPulse(interval: t.pulseMaxInterval + (t.pulseMinInterval - t.pulseMaxInterval) * u)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.haptics.setPulse(interval: nil) }
    }

    private func execute(_ commands: [FeedbackCommand], triggeredAt frameTimestamp: TimeInterval?) {
        guard !commands.isEmpty else { return }
        for command in commands {
            switch command {
            case .speak(let cue, let interrupt):
                if let frameTimestamp {
                    arbiter.annotateLatency((Self.now - frameTimestamp) * 1000)
                }
                if muted {
                    // Nothing plays, so finish right away and let the queue drain.
                    DispatchQueue.main.async { [weak self] in self?.speechFinished() }
                } else {
                    // Only directions may wait on the network; every safety and steering cue is a bundled clip.
                    let allowCloud = cue.phrases.isEmpty && cue.tier <= .guided
                    speech.play(cue, interrupt: interrupt, allowCloud: allowCloud)
                }
            case .haptic(let event):
                if !muted { haptics.play(event) }
            case .pulse(let interval):
                haptics.setPulse(interval: muted ? nil : interval)
            }
        }
        logVersion += 1
    }

    private func speechFinished() {
        execute(arbiter.speechFinished(now: Self.now), triggeredAt: nil)
        logVersion += 1
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
