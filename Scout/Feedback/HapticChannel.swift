import CoreHaptics
import Foundation

/// Phone vibration. The whole phone shakes against the sternum, so vibration says how urgent, never which way.
/// Use from the main thread.
final class HapticChannel {
    private var engine: CHHapticEngine?
    private var pulseTimer: Timer?
    /// 0...1 from Preferences; scales every vibration.
    var strength: () -> Float = { 1 }

    var isAvailable: Bool { engine != nil }

    func start() {
        guard engine == nil, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = false
            engine.playsHapticsOnly = true
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            engine.stoppedHandler = { [weak engine] _ in try? engine?.start() }
            try engine.start()
            self.engine = engine
        } catch {
            engine = nil
        }
    }

    func stop() {
        setPulse(interval: nil)
        engine?.stop()
        engine = nil
    }

    func play(_ event: HapticEvent) {
        switch event {
        case .stopBuzz:
            playPattern([continuous(at: 0, duration: 0.6, intensity: 1, sharpness: 0.6)])
        case .doubleTap:
            playPattern([transient(at: 0, intensity: 1, sharpness: 1), transient(at: 0.12, intensity: 1, sharpness: 1)])
        case .lightTap:
            playPattern([transient(at: 0, intensity: 0.5, sharpness: 0.3)])
        }
    }

    /// Repeating tap every `interval` seconds; nil stops it.
    /// A new interval keeps the rhythm: the next tap lands one new interval after the last one, so frequent
    /// updates while approaching an obstacle never add extra taps.
    func setPulse(interval: Double?) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        guard let interval else { return }
        let sinceLast = ProcessInfo.processInfo.systemUptime - lastTap
        let firstDelay = max(0, interval - sinceLast)
        let timer = Timer(fire: Date(timeIntervalSinceNow: firstDelay), interval: interval, repeats: true) { [weak self] _ in
            self?.pulseTap()
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private var lastTap: TimeInterval = -.infinity

    private func pulseTap() {
        lastTap = ProcessInfo.processInfo.systemUptime
        playPattern([transient(at: 0, intensity: 0.8, sharpness: 0.7)])
    }

    private func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * max(0, min(1, strength()))),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }

    private func continuous(at time: TimeInterval, duration: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * max(0, min(1, strength()))),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time,
            duration: duration
        )
    }

    private func playPattern(_ events: [CHHapticEvent]) {
        guard let engine else { return }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // A dropped tap is not worth crashing guidance over.
        }
    }
}
