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
/// - Obstacle names ride on Stop and steer cues and never add an interruption of their own. Chatty's
///   side mentions ("Person on your left") play only when nothing else is being said.
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
    private var dropSince: TimeInterval?
    /// Track id to when its name was last spoken, and when it was last the obstacle in the path.
    private var labelSpoken: [Int: TimeInterval] = [:]
    private var labelInPath: [Int: TimeInterval] = [:]
    private var lastSideMention: TimeInterval = -.infinity
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
        dropSince = nil
        labelSpoken.removeAll()
        labelInPath.removeAll()
        lastSideMention = -.infinity
        let hadPulse = lastPulse != nil
        lastPulse = nil
        return hadPulse ? [.pulse(interval: nil)] : []
    }

    // MARK: - Inputs

    /// Call once per perception frame.
    func update(_ p: PlannerOutput, now: TimeInterval, tuning t: Tuning) -> [FeedbackCommand] {
        var commands: [FeedbackCommand] = []

        // A drop-off must persist briefly before it is spoken; single-frame holes in the depth map are common.
        var confirmedDrop: Float?
        if let d = p.dropOffAhead, d <= t.dropAlertDistance {
            if dropSince == nil { dropSince = now }
            if let since = dropSince, now - since >= t.dropConfirmSeconds { confirmedDrop = d }
        } else {
            dropSince = nil
        }

        var name = obstacleName(p, now: now, tuning: t)

        // Safety: stairs, drop-off, stop, in that order. Overhead is not spoken: on a chest mount it is
        // wrong too often to be worth interrupting for.
        var safety: (key: String, cue: Cue, why: String)?
        if let stairs = p.stairs, stairs.distance <= t.stairAlertDistance {
            let key = stairs.direction == .up ? "stairs_up" : "stairs_down"
            var phrases = [key]
            if verbosity == .chatty { phrases.append("dist_\(max(1, min(4, Int(stairs.distance.rounded()))))") }
            safety = (key, Cue(tier: .stop, phrases: phrases, haptic: .doubleTap),
                      String(format: "%ld steps %@ at %.1fm", stairs.steps, stairs.direction.rawValue, stairs.distance))
        } else if let d = confirmedDrop {
            safety = ("step_down", Cue(tier: .stop, phrases: ["step_down"], haptic: .stopBuzz), String(format: "drop-off %.1fm", d))
        } else if p.blocked || (p.pathVisible && p.urgency >= t.stopUrgency) {
            // The name follows Stop as a second clip, so the time to the first sound does not change.
            safety = ("stop", Cue(tier: .stop, phrases: ["stop"] + (name.map { [$0.phrase] } ?? []), haptic: .stopBuzz),
                      String(format: "urgency %.2f", p.urgency))
        }

        if let safety {
            if safety.key != lastSafetyKey || now - lastSafetyTime >= t.repeatInterval {
                lastSafetyKey = safety.key
                lastSafetyTime = now
                commands += emit(safety.cue, now: now, tuning: t, reason: safety.why)
                if safety.key == "stop", name != nil {
                    markNamed(name, now: now)
                    name = nil // said once; a steer cue in the same frame does not repeat it
                }
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
        // No steering around stairs or a step: the user decides whether to take them.
        let steerAllowed = safety == nil || safety?.key == "stop"
        if let key = steerKey, verbosity != .minimal, steerAllowed {
            if key != lastSteerKey || now - lastSteerTime >= t.repeatInterval {
                lastSteerKey = key
                lastSteerTime = now
                // What it is, then which way to go.
                var phrases = (name.map { [$0.phrase] } ?? []) + [key]
                if verbosity == .chatty, let nearest = p.nearestObstacle {
                    let meters = max(1, min(4, Int(nearest.rounded())))
                    phrases.append("dist_\(meters)")
                }
                let why = String(format: "heading %+.0f°, obstacle %.1fm", p.heading * 180 / .pi, p.nearestObstacle ?? 0)
                commands += emit(Cue(tier: .steer, phrases: phrases), now: now, tuning: t, reason: why)
                markNamed(name, now: now)
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

        // Chatty: a named hazard beside the path, only when nothing else is being said.
        if verbosity == .chatty, safety == nil, steerKey == nil, !isSpeaking, now - lastSideMention >= t.sideMentionInterval,
           let side = p.sideLabels.first(where: { labelSpoken[$0.track].map { now - $0 >= t.labelRepeatSeconds } ?? true }) {
            lastSideMention = now
            labelSpoken[side.track] = now
            let cue = Cue(tier: .status, phrases: [side.label.phrase, side.onLeft ? "on_left" : "on_right"])
            commands += emit(cue, now: now, tuning: t, reason: String(format: "%@ beside path at %.1fm", side.label.rawValue, side.distance))
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

    /// The name to add to this frame's Stop or steer cue, if any: spoken at this verbosity, and not already said
    /// for this object in the last `labelRepeatSeconds` unless it left the path for 3 s and came back.
    /// A phone label plays its bundled clip; a Gemini name is spoken with the iPhone voice.
    private func obstacleName(_ p: PlannerOutput, now: TimeInterval, tuning t: Tuning) -> (track: Int, phrase: String)? {
        guard let track = p.nearestLabelTrack else { return nil }
        let phrase: String
        let tier: LabelTier
        if let label = p.nearestLabel {
            phrase = label.phrase
            tier = label.tier
        } else if let name = p.nearestCloudName {
            phrase = CuePhrases.sayPrefix + name
            tier = p.nearestCloudHazard ? .hazard : .common
        } else {
            return nil
        }
        let returning = labelInPath[track].map { now - $0 >= 3 } ?? true
        labelInPath[track] = now
        if labelInPath.count > 64 {
            labelInPath = labelInPath.filter { now - $0.value < 60 }
            labelSpoken = labelSpoken.filter { now - $0.value < 60 }
        }
        guard tier.isSpoken(at: verbosity) else { return nil }
        if let spoken = labelSpoken[track], now - spoken < t.labelRepeatSeconds, !returning { return nil }
        return (track, phrase)
    }

    /// Call after emitting a cue that carried `name`. A dropped cue still counts; the name comes back with the
    /// next repeat of the cue only after `labelRepeatSeconds`, which is the price of never stuttering.
    private func markNamed(_ name: (track: Int, phrase: String)?, now: TimeInterval) {
        guard let name else { return }
        labelSpoken[name.track] = now
    }

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
