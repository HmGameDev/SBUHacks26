import Foundation

struct CueLogEntry: Identifiable, Sendable {
    let id = UUID()
    let time: TimeInterval
    let tier: CueTier
    let text: String
    /// spoken, queued, preempted, expired, dropped, muted
    let outcome: String
    let detail: String
    var latencyMs: Double?
}

/// Decides what the user hears and feels. It is the only place cue policy lives, and it is pure:
/// callers pass the time in and get commands out, so tests can drive it without audio hardware.
///
/// Rules (foundation prompt section 6):
/// - Speak on change, not on every frame; repeat a still-true cue every `repeatInterval`.
/// - Stop and Overhead interrupt anything lower, mid-word.
/// - Lower tiers queue and expire (`queueExpiry`; status and guided cues get longer).
/// - Silence means clear.
final class CueArbiter {
    var verbosity: Verbosity = .normal
    private(set) var log: [CueLogEntry] = []
    private(set) var isSpeaking = false

    private struct Pending {
        let cue: Cue
        let expires: TimeInterval
        let reason: String
    }

    private var currentTier: CueTier?
    private var queue: [Pending] = []
    private var lastSafetyKey: String?
    private var lastSafetyTime: TimeInterval = -.infinity
    private var lastSteerKey: String?
    private var lastSteerTime: TimeInterval = -.infinity
    private var wasBlocked = false
    private var clearSince: TimeInterval?
    private var lastPulse: Double?
    private let maxLog = 300
    private let longExpiry: TimeInterval = 8

    func reset() -> [FeedbackCommand] {
        queue.removeAll()
        lastSafetyKey = nil
        lastSteerKey = nil
        lastSafetyTime = -.infinity
        lastSteerTime = -.infinity
        wasBlocked = false
        clearSince = nil
        let hadPulse = lastPulse != nil
        lastPulse = nil
        return hadPulse ? [.pulse(interval: nil)] : []
    }

    // MARK: - Inputs

    /// Call once per perception frame.
    func update(_ p: PlannerOutput, now: TimeInterval, tuning t: Tuning) -> [FeedbackCommand] {
        var commands: [FeedbackCommand] = []

        // Safety: drop-off, stop, overhead, in that order.
        var safety: (key: String, cue: Cue, why: String)?
        if let d = p.dropOffAhead, d <= t.dropAlertDistance {
            safety = ("step_down", Cue(tier: .stop, phrases: ["step_down"], haptic: .stopBuzz), String(format: "drop-off %.1fm", d))
        } else if p.blocked || (p.pathVisible && p.urgency >= t.stopUrgency) {
            safety = ("stop", Cue(tier: .stop, phrases: ["stop"], haptic: .stopBuzz), String(format: "urgency %.2f", p.urgency))
        } else if let d = p.overheadAhead, d <= t.overheadAlertDistance {
            safety = ("duck", Cue(tier: .overhead, phrases: ["duck"], haptic: .doubleTap), String(format: "overhead %.1fm", d))
        }

        if let safety {
            if safety.key != lastSafetyKey || now - lastSafetyTime >= t.repeatInterval {
                lastSafetyKey = safety.key
                lastSafetyTime = now
                commands += emit(safety.cue, now: now, tuning: t, reason: safety.why)
            }
        } else {
            lastSafetyKey = nil
        }

        // Steer: which way the gap is, when something is in the way.
        var steerKey: String?
        let deadband = t.straightDeadbandDegrees * .pi / 180
        if p.pathVisible, let nearest = p.nearestObstacle, nearest <= t.steerTriggerDistance, abs(p.heading) > deadband {
            let slight = abs(p.heading) < t.slightTurnDegrees * .pi / 180
            switch (p.heading < 0, slight) {
            case (true, true): steerKey = "slight_left"
            case (true, false): steerKey = "left"
            case (false, true): steerKey = "slight_right"
            case (false, false): steerKey = "right"
            }
        }
        if let key = steerKey, verbosity != .minimal, safety?.key != "step_down" {
            if key != lastSteerKey || now - lastSteerTime >= t.repeatInterval {
                lastSteerKey = key
                lastSteerTime = now
                var phrases = [key]
                if verbosity == .chatty, let nearest = p.nearestObstacle {
                    let meters = max(1, min(4, Int(nearest.rounded())))
                    phrases.append("dist_\(meters)")
                }
                let why = String(format: "heading %+.0f°, obstacle %.1fm", p.heading * 180 / .pi, p.nearestObstacle ?? 0)
                commands += emit(Cue(tier: .steer, phrases: phrases), now: now, tuning: t, reason: why)
            }
        } else if steerKey == nil {
            lastSteerKey = nil
        }

        // Clear: only after something was in the way, and only for chatty users.
        if safety != nil || steerKey != nil {
            wasBlocked = true
            clearSince = nil
        } else if wasBlocked {
            if clearSince == nil { clearSince = now }
            if let since = clearSince, now - since >= t.clearHoldSeconds {
                wasBlocked = false
                clearSince = nil
                if verbosity == .chatty {
                    commands += emit(Cue(tier: .clear, phrases: ["clear"]), now: now, tuning: t, reason: "path clear")
                }
            }
        }

        // Proximity pulse: faster as the obstacle ahead gets closer.
        var pulse: Double?
        if p.pathVisible, let nearest = p.nearestObstacle, nearest <= t.steerTriggerDistance {
            let u = Double(max(0, min(1, p.urgency)))
            pulse = t.pulseMaxInterval + (t.pulseMinInterval - t.pulseMaxInterval) * u
        }
        if Self.pulseChanged(from: lastPulse, to: pulse) {
            lastPulse = pulse
            commands.append(.pulse(interval: pulse))
        }
        return commands
    }

    /// Status and guided cues from elsewhere in the app.
    func submit(_ cue: Cue, now: TimeInterval, tuning t: Tuning, reason: String = "") -> [FeedbackCommand] {
        emit(cue, now: now, tuning: t, reason: reason)
    }

    /// The speech channel finished (or was told to stop by the arbiter).
    func speechFinished(now: TimeInterval) -> [FeedbackCommand] {
        isSpeaking = false
        currentTier = nil
        return dequeue(now: now)
    }

    func annotateLatency(_ ms: Double) {
        guard let index = log.lastIndex(where: { $0.outcome == "spoken" }) else { return }
        log[index].latencyMs = ms
    }

    // MARK: - Policy

    private func emit(_ cue: Cue, now: TimeInterval, tuning t: Tuning, reason: String) -> [FeedbackCommand] {
        var commands: [FeedbackCommand] = []
        if let haptic = cue.haptic { commands.append(.haptic(haptic)) }

        if !isSpeaking {
            commands.append(.speak(cue, interrupt: false))
            begin(cue, now: now, outcome: "spoken", reason: reason)
            return commands
        }

        let current = currentTier ?? .status
        if cue.tier.isSafety && cue.tier > current {
            commands.append(.speak(cue, interrupt: true))
            record(Cue(tier: current, text: "(current cue)"), now: now, outcome: "preempted", reason: "by \(cue.tier)")
            begin(cue, now: now, outcome: "spoken", reason: reason)
            return commands
        }

        if cue.tier.isSafety && cue.tier == current {
            // Already saying a cue of this tier; repeating it now would only stutter.
            record(cue, now: now, outcome: "dropped", reason: "same tier already playing")
            return commands
        }

        // Newer information replaces older queued cues of the same tier.
        queue.removeAll { $0.cue.tier == cue.tier }
        let lifetime = cue.tier <= .guided ? longExpiry : t.queueExpiry
        queue.append(Pending(cue: cue, expires: now + lifetime, reason: reason))
        record(cue, now: now, outcome: "queued", reason: reason)
        return commands
    }

    private func dequeue(now: TimeInterval) -> [FeedbackCommand] {
        let expired = queue.filter { $0.expires < now }
        for item in expired { record(item.cue, now: now, outcome: "expired", reason: item.reason) }
        queue.removeAll { $0.expires < now }
        guard let next = queue.enumerated().max(by: { a, b in
            // Highest tier first; within a tier, oldest first.
            a.element.cue.tier == b.element.cue.tier ? a.offset > b.offset : a.element.cue.tier < b.element.cue.tier
        }) else { return [] }
        queue.remove(at: next.offset)
        begin(next.element.cue, now: now, outcome: "spoken", reason: next.element.reason + " (from queue)")
        return [.speak(next.element.cue, interrupt: false)]
    }

    private func begin(_ cue: Cue, now: TimeInterval, outcome: String, reason: String) {
        isSpeaking = true
        currentTier = cue.tier
        record(cue, now: now, outcome: outcome, reason: reason)
    }

    private func record(_ cue: Cue, now: TimeInterval, outcome: String, reason: String) {
        log.append(CueLogEntry(time: now, tier: cue.tier, text: cue.text, outcome: outcome, detail: reason))
        if log.count > maxLog { log.removeFirst(log.count - maxLog) }
    }

    private static func pulseChanged(from old: Double?, to new: Double?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a - b) / a > 0.1
        default: return true
        }
    }
}
