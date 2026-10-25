import Foundation

struct PlannerOutput: Sendable, Equatable {
    /// Smoothed direction of the chosen gap, radians. Negative is left, 0 is straight ahead.
    var heading: Float = 0
    /// Best candidate this frame before hysteresis and smoothing (for the debug graph).
    var rawHeading: Float = 0
    /// 0 when the path ahead is clear, 1 when the user must stop.
    var urgency: Float = 0
    /// Free distance straight ahead, if the path ahead is visible.
    var straightFree: Float?
    var nearestObstacle: Float?
    var dropOffAhead: Float?
    var overheadAhead: Float?
    var pathVisible = false
    /// Every direction is blocked close by.
    var blocked = false
    var reason = ""

    static let idle = PlannerOutput(reason: "Idle")
}

struct GapCandidate: Sendable, Equatable {
    let angle: Float
    let freeDistance: Float
    let score: Float
}

/// Picks the clearest heading through the occupancy grid. Adapted from Shepherd's 16-column gap search,
/// but marches real corridors through a top-down grid instead of averaging image columns, and owns all
/// temporal smoothing now that there is no motor integrator.
final class GapPlanner {
    struct March: Equatable {
        var free: Float
        var seen: Bool
        var hit: CellState?
    }

    private var smoothed: Float = 0
    private var lastTarget: Float = 0
    private var committedSide = 0
    private var pendingSide = 0
    private var pendingSince: TimeInterval = 0
    private var lastTime: TimeInterval?

    func reset() {
        smoothed = 0
        lastTarget = 0
        committedSide = 0
        pendingSide = 0
        pendingSince = 0
        lastTime = nil
    }

    func plan(grid: OccupancyGrid, time: TimeInterval, goalHeading: Float?, tuning t: Tuning) -> (PlannerOutput, [GapCandidate]) {
        let dt = Float(lastTime.map { max(0, min(0.5, time - $0)) } ?? (1.0 / 30.0))
        lastTime = time

        let straight = Self.march(grid: grid, angle: 0, tuning: t) { $0.isBlocking }
        let span = t.headingSpanDegrees * .pi / 180
        let count = max(3, t.headingCount)
        let angles = (0..<count).map { -span + 2 * span * Float($0) / Float(count - 1) }
        let marches = angles.map { Self.march(grid: grid, angle: $0, tuning: t) { $0.isBlocking } }
        // A heading the camera has never seen is not a gap; it is just unknown.
        let frees = marches.map { $0.seen ? $0.free : 0 }
        let smoothedFrees = Self.smooth(frees)
        let pathVisible = straight.seen || marches.contains { $0.seen }

        var output = PlannerOutput()
        output.pathVisible = pathVisible

        guard pathVisible else {
            decay(dt: dt, tuning: t)
            output.heading = smoothed
            output.reason = "Path not visible"
            return (output, zip(angles, frees).map { GapCandidate(angle: $0, freeDistance: $1, score: 0) })
        }

        let urgency: Float
        if straight.seen {
            let x = (t.clearDistance - straight.free) / max(0.01, t.clearDistance - t.stopDistance)
            urgency = powf(max(0, min(1, x)), t.urgencyExponent)
            output.straightFree = straight.free
        } else {
            urgency = 0
        }

        let goal = goalHeading.map { max(-span, min(span, $0)) }
        var candidates: [GapCandidate] = []
        for (i, angle) in angles.enumerated() {
            var score = smoothedFrees[i]
            // Prefer straight when the way ahead is clear; when it is blocked, any real gap is worth turning for.
            score -= t.turnPenalty * (1 - urgency) * abs(angle) / span
            score -= t.switchPenalty * abs(angle - lastTarget) / (2 * span)
            if let goal {
                score -= t.goalWeight * (1 - urgency) * abs(angle - goal) / span
            }
            candidates.append(GapCandidate(angle: angle, freeDistance: frees[i], score: score))
        }
        let best = candidates.max { $0.score < $1.score }!

        // Hysteresis: the chosen side must hold for `hysteresisSeconds` before the guidance switches.
        let deadband = t.straightDeadbandDegrees * .pi / 180
        let side = Self.side(of: best.angle, deadband: deadband)
        if side == committedSide {
            pendingSide = side
        } else {
            if pendingSide != side {
                pendingSide = side
                pendingSince = time
            }
            if time - pendingSince >= t.hysteresisSeconds {
                committedSide = side
            }
        }

        let target: Float
        if side == committedSide {
            // Inside the deadband counts as straight ahead.
            target = side == 0 ? 0 : best.angle
        } else if committedSide == 0 {
            target = 0
        } else {
            target = candidates
                .filter { Self.side(of: $0.angle, deadband: deadband) == committedSide }
                .max { $0.score < $1.score }?.angle ?? 0
        }
        let alpha = 1 - powf(1 - max(0.001, min(1, t.headingSmoothing)), dt * 30)
        smoothed += alpha * (target - smoothed)
        lastTarget = target

        let drop = Self.march(grid: grid, angle: 0, tuning: t) { $0 == .dropOff }
        let overhead = Self.march(grid: grid, angle: 0, tuning: t) { $0 == .overhead }

        output.heading = smoothed
        output.rawHeading = best.angle
        output.urgency = urgency
        output.nearestObstacle = straight.hit != nil ? straight.free : nil
        output.dropOffAhead = drop.hit != nil ? drop.free : nil
        output.overheadAhead = overhead.hit != nil ? overhead.free : nil
        output.blocked = straight.seen && straight.free < t.stopDistance
            && (smoothedFrees.max() ?? 0) < t.stopDistance
        output.reason = String(
            format: "best %+.0f° free %.1fm, ahead %@, urgency %.2f",
            best.angle * 180 / .pi,
            best.freeDistance,
            straight.seen ? String(format: "%.1fm", straight.free) : "unseen",
            urgency
        )
        return (output, candidates)
    }

    private func decay(dt: Float, tuning t: Tuning) {
        let alpha = 1 - powf(1 - max(0.001, min(1, t.headingSmoothing)), dt * 30)
        smoothed -= alpha * smoothed
        lastTarget = 0
    }

    static func side(of angle: Float, deadband: Float) -> Int {
        angle < -deadband ? -1 : (angle > deadband ? 1 : 0)
    }

    /// Shepherd's [0.25, 0.5, 0.25] kernel, edges clamped.
    static func smooth(_ values: [Float]) -> [Float] {
        values.indices.map { i in
            let left = values[max(0, i - 1)]
            let right = values[min(values.count - 1, i + 1)]
            return 0.25 * left + 0.5 * values[i] + 0.25 * right
        }
    }

    /// Walks a corridor of `corridorWidth` along `angle` until a blocking cell, the edge of the grid,
    /// or too much unseen space after the floor was last seen.
    static func march(grid: OccupancyGrid, angle: Float, tuning t: Tuning, blocks: (CellState) -> Bool) -> March {
        let s = sinf(angle), c = cosf(angle)
        // Half-cell steps, so rounding can never skip a row or column of cells.
        let step = grid.cellSize / 2
        let half = t.corridorWidth / 2
        let offsetCount = Int((2 * half / step).rounded())
        let offsets = (0...offsetCount).map { -half + Float($0) * step }

        var seen = false
        var unknownRun: Float = 0
        var k = 0
        while true {
            let distance = t.minRange + Float(k) * step
            k += 1
            guard distance < grid.forwardRange else { break }
            guard grid.index(forward: distance * c, lateral: distance * s) != nil else {
                return March(free: distance, seen: seen, hit: nil)
            }
            var rowSeen = false
            for offset in offsets {
                let f = distance * c - offset * s
                let l = distance * s + offset * c
                guard let i = grid.index(forward: f, lateral: l) else { continue }
                let state = grid.cells[i].state
                if blocks(state) { return March(free: distance, seen: true, hit: state) }
                if state != .unknown { rowSeen = true }
            }
            if rowSeen {
                seen = true
                unknownRun = 0
            } else if seen {
                unknownRun += step
                if unknownRun > t.unknownRunLimit {
                    return March(free: distance - unknownRun, seen: true, hit: nil)
                }
            }
        }
        return March(free: grid.forwardRange, seen: seen, hit: nil)
    }
}
