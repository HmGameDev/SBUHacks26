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
    var stairs: StairInfo?
    /// Route direction (Guided mode) or the direction the user was walking (passive), relative to straight.
    var goalHeading: Float?
    var intentHeading: Float?
    var pathVisible = false
    /// Every direction is blocked close by.
    var blocked = false
    var reason = ""
    /// Identification: the confirmed name of the obstacle the planner is reacting to, and its track id.
    var nearestLabel: ObstacleLabel?
    var nearestLabelTrack: Int?
    /// Identification: a Gemini name for the obstacle in the path when the phone could not name it.
    /// `nearestLabelTrack` then holds the cloud spot's id.
    var nearestCloudName: String?
    var nearestCloudHazard = false
    /// Identification: named hazards just outside the walking corridor, nearest first.
    var sideLabels: [SideLabel] = []
    /// Identification: a confirmed doorway ahead (depth only).
    var doorway: DoorwayInfo?

    static let idle = PlannerOutput(reason: "Idle")
}

struct GapCandidate: Sendable, Equatable {
    let angle: Float
    let freeDistance: Float
    /// Free distance of the wider clearance corridor along the same heading.
    var clearDistance: Float = 0
    let score: Float
}

extension Tuning {
    /// How many cells of a kind must sit side by side across the corridor before they block it.
    /// 0 means the kind never blocks.
    func blockRequirement(_ state: CellState) -> Int {
        switch state {
        case .obstacle: 1
        case .dropOff: max(1, dropMinCells)
        case .overhead: overheadBlocks ? 1 : 0
        case .free, .unknown: 0
        }
    }
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

    func plan(
        grid: OccupancyGrid, time: TimeInterval, goalHeading: Float?, intentHeading: Float? = nil, tuning t: Tuning
    ) -> (PlannerOutput, [GapCandidate]) {
        let dt = Float(lastTime.map { max(0, min(0.5, time - $0)) } ?? (1.0 / 30.0))
        lastTime = time

        let blocking: (CellState) -> Int = { t.blockRequirement($0) }
        let wide = t.corridorWidth + 2 * max(0, t.clearanceMargin)
        let straight = Self.march(grid: grid, angle: 0, tuning: t, required: blocking)
        let span = t.headingSpanDegrees * .pi / 180
        let count = max(3, t.headingCount)
        let angles = (0..<count).map { -span + 2 * span * Float($0) / Float(count - 1) }
        let marches = angles.map { Self.march(grid: grid, angle: $0, tuning: t, required: blocking) }
        let wideMarches = angles.map { Self.march(grid: grid, angle: $0, tuning: t, width: wide, required: blocking) }
        // A heading the camera has never seen (and the map does not remember) is not a gap; it is just unknown.
        let frees = marches.map { $0.seen ? $0.free : 0 }
        let wideFrees = zip(wideMarches, frees).map { march, free in march.seen ? min(march.free, free) : 0 }
        let smoothedFrees = Self.smooth(frees)
        let pathVisible = straight.seen || marches.contains { $0.seen }

        var output = PlannerOutput()
        output.pathVisible = pathVisible
        output.goalHeading = goalHeading
        output.intentHeading = goalHeading == nil ? intentHeading : nil

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
        let intent = goalHeading == nil ? intentHeading.map { max(-span, min(span, $0)) } : nil
        let smoothedWide = Self.smooth(wideFrees)
        var candidates: [GapCandidate] = []
        for (i, angle) in angles.enumerated() {
            var score = smoothedFrees[i]
            // A path that only fits by brushing a wall or a box is worse than one with room on both sides.
            score -= t.clearanceWeight * max(0, smoothedFrees[i] - smoothedWide[i])
            // Prefer straight when the way ahead is clear; when it is blocked, any real gap is worth turning for.
            score -= t.turnPenalty * (1 - urgency) * abs(angle) / span
            score -= t.switchPenalty * abs(angle - lastTarget) / (2 * span)
            // The user knows where they are going: lean toward the route, or toward the way they were walking.
            if let goal {
                score -= t.goalWeight * (1 - urgency) * abs(angle - goal) / span
            } else if let intent {
                score -= t.intentWeight * (1 - urgency) * abs(angle - intent) / span
            }
            candidates.append(GapCandidate(angle: angle, freeDistance: frees[i], clearDistance: wideFrees[i], score: score))
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

        let drop = Self.march(grid: grid, angle: 0, tuning: t) { $0 == .dropOff ? max(1, t.dropMinCells) : 0 }
        let overhead = Self.march(grid: grid, angle: 0, tuning: t) { $0 == .overhead ? 1 : 0 }

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

    /// Walks a corridor (default `corridorWidth`) along `angle` until it is blocked, reaches the edge of the
    /// grid, or crosses too much unseen space after the floor was last seen. `required` says how many distinct
    /// cells of a state must sit across the corridor at one distance to block it (0: never blocks).
    static func march(
        grid: OccupancyGrid, angle: Float, tuning t: Tuning, width: Float? = nil, required: (CellState) -> Int
    ) -> March {
        let s = sinf(angle), c = cosf(angle)
        // Half-cell steps, so rounding can never skip a row or column of cells.
        let step = grid.cellSize / 2
        let half = (width ?? t.corridorWidth) / 2
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
            var visited: [Int] = []
            var counts = [Int](repeating: 0, count: 5)
            for offset in offsets {
                let f = distance * c - offset * s
                let l = distance * s + offset * c
                guard let i = grid.index(forward: f, lateral: l), !visited.contains(i) else { continue }
                visited.append(i)
                let state = grid.cells[i].state
                if state != .unknown { rowSeen = true }
                let need = required(state)
                guard need > 0 else { continue }
                counts[Int(state.rawValue)] += 1
                if counts[Int(state.rawValue)] >= need { return March(free: distance, seen: true, hit: state) }
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
