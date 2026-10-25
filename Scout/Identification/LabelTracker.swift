import CoreGraphics
import Foundation
import simd

/// One classifier box placed in the world through the depth map.
struct Detection: Sendable, Equatable {
    let label: ObstacleLabel
    let confidence: Float
    /// Normalized to the depth map, origin top-left (see `ClassifiedBox.rect`).
    let rect: CGRect
    /// Front surface of the object in world space, or nil when the depth inside the box was unusable.
    let world: SIMD3<Float>?
}

enum LabelFusion {
    /// Places each box using the depth in the middle half of the box. It takes the 30th percentile rather than
    /// the median, so the point lands on the object in front and not on the wall behind or between its legs.
    static func fuse(
        _ boxes: [ClassifiedBox], depth: DepthImage, intrinsics: simd_float3x3, cameraTransform: simd_float4x4, maxRange: Float
    ) -> [Detection] {
        let w = Float(depth.width), h = Float(depth.height)
        guard depth.width > 0, depth.height > 0 else { return [] }
        func clampU(_ x: Float) -> Int { max(0, min(depth.width - 1, Int(x))) }
        func clampV(_ y: Float) -> Int { max(0, min(depth.height - 1, Int(y))) }

        return boxes.map { box in
            let r = box.rect
            let u0 = clampU(Float(r.minX + r.width / 4) * w)
            let u1 = max(u0, clampU(Float(r.maxX - r.width / 4) * w))
            let v0 = clampV(Float(r.minY + r.height / 4) * h)
            let v1 = max(v0, clampV(Float(r.maxY - r.height / 4) * h))
            var samples: [Float] = []
            for v in v0...v1 {
                for u in u0...u1 {
                    let d = depth.value(u, v)
                    if d.isFinite, d > 0.1, d <= maxRange { samples.append(d) }
                }
            }
            guard samples.count >= 5 else {
                return Detection(label: box.label, confidence: box.confidence, rect: r, world: nil)
            }
            samples.sort()
            let d = samples[Int(Float(samples.count - 1) * 0.3)]
            let camera = Geometry.unproject(u: Float(r.midX) * w, v: Float(r.midY) * h, depth: d, intrinsics: intrinsics)
            return Detection(
                label: box.label, confidence: box.confidence, rect: r, world: Geometry.transform(camera, by: cameraTransform)
            )
        }
    }
}

/// A named thing held at a world-fixed spot, so its name survives the wearer turning and the detector missing
/// a frame or two.
struct LabelTrack: Sendable, Identifiable, Equatable {
    let id: Int
    /// World x and z of the latest detection.
    var position: SIMD2<Float>
    let origin: SIMD2<Float>
    let born: TimeInterval
    var lastDetected: TimeInterval
    /// One entry per detector run, newest last: the label seen in that run, or nil.
    var votes: [ObstacleLabel?]
    /// Set once one label fills enough of the vote window; held until the track expires.
    var label: ObstacleLabel?
}

/// Associates detections across runs and only confirms a name that keeps coming back.
struct LabelTracker: Sendable {
    struct Rules: Sendable, Equatable {
        /// Runs remembered per track.
        var window: Int
        /// Runs in the window that must agree on a label.
        var needed: Int
        /// A track with no detection for this long is dropped.
        var hold: TimeInterval
        var matchRadius: Float
        /// A track this young cannot be confirmed yet.
        var minAge: TimeInterval = 0
        /// When set, a track that wanders farther than this from where it started loses its label (poles stand still).
        var staticRadius: Float?
    }

    var rules: Rules
    private(set) var tracks: [LabelTrack] = []
    private let firstID: Int
    private var nextID: Int

    init(rules: Rules, firstID: Int) {
        self.rules = rules
        self.firstID = firstID
        nextID = firstID
    }

    var confirmed: [LabelTrack] { tracks.filter { $0.label != nil } }

    mutating func reset() {
        tracks.removeAll()
        nextID = firstID
    }

    /// Drops tracks not detected within `hold`. Also clears everything if time runs backward (a new replay).
    mutating func expire(time: TimeInterval) {
        tracks.removeAll { time - $0.lastDetected > rules.hold || time < $0.lastDetected }
    }

    /// One detector run. Detections without a world position are ignored.
    mutating func ingest(_ detections: [Detection], time: TimeInterval) {
        expire(time: time)
        var matched: [Int: ObstacleLabel] = [:]
        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            guard let world = detection.world else { continue }
            let spot = SIMD2(world.x, world.z)
            var best: (index: Int, distance: Float)?
            for (i, track) in tracks.enumerated() where matched[track.id] == nil {
                let distance = simd_distance(track.position, spot)
                if distance < rules.matchRadius, distance < (best?.distance ?? .infinity) { best = (i, distance) }
            }
            if let best {
                tracks[best.index].position = spot
                tracks[best.index].lastDetected = time
                matched[tracks[best.index].id] = detection.label
            } else {
                let track = LabelTrack(
                    id: nextID, position: spot, origin: spot, born: time, lastDetected: time, votes: [], label: nil
                )
                nextID += 1
                tracks.append(track)
                matched[track.id] = detection.label
            }
        }
        for i in tracks.indices {
            tracks[i].votes.append(matched[tracks[i].id])
            if tracks[i].votes.count > rules.window { tracks[i].votes.removeFirst(tracks[i].votes.count - rules.window) }
            updateLabel(&tracks[i], time: time)
        }
    }

    private func updateLabel(_ track: inout LabelTrack, time: TimeInterval) {
        if let radius = rules.staticRadius, simd_distance(track.position, track.origin) > radius {
            track.label = nil
            return
        }
        guard time - track.born >= rules.minAge else { return }
        var counts: [ObstacleLabel: Int] = [:]
        for case let label? in track.votes { counts[label, default: 0] += 1 }
        // Ties go to the more significant label, then to a fixed order, so replays stay deterministic.
        if let top = counts.max(by: { a, b in
            a.value != b.value ? a.value < b.value
                : a.key.tier != b.key.tier ? a.key.tier < b.key.tier : a.key.rawValue > b.key.rawValue
        }), top.value >= rules.needed {
            track.label = top.key
        }
    }
}

extension Tuning {
    var visionLabelRules: LabelTracker.Rules {
        LabelTracker.Rules(window: labelVoteWindow, needed: labelVotesNeeded, hold: labelHoldSeconds, matchRadius: labelMatchRadius)
    }

    var poleLabelRules: LabelTracker.Rules {
        LabelTracker.Rules(
            window: poleVoteWindow, needed: poleVotesNeeded, hold: poleHoldSeconds, matchRadius: poleMatchRadius,
            minAge: poleMinAge, staticRadius: poleStaticRadius
        )
    }
}

/// A Hazard-tier obstacle just outside the walking corridor (Chatty's "Person on your left").
struct SideLabel: Sendable, Equatable {
    let label: ObstacleLabel
    let track: Int
    let onLeft: Bool
    let distance: Float
}

/// Which confirmed labels matter right now. A label counts only while LiDAR still sees an obstacle under it.
enum LabelQuery {
    struct Result: Equatable {
        var nearest: LabelTrack?
        var side: [SideLabel] = []
    }

    /// - Parameter tracks: confirmed tracks, Vision before geometry, so Vision wins a near tie.
    static func evaluate(
        _ tracks: [LabelTrack], body: BodyFrame, grid: OccupancyGrid, planner p: PlannerOutput, tuning t: Tuning
    ) -> Result {
        let half = t.corridorWidth / 2
        var result = Result()
        var nearestForward: Float = .infinity

        // The named obstacle must be the one the planner is reacting to: in the corridor, at the distance of
        // the obstacle straight ahead.
        for track in tracks {
            guard let f = inPath(track.position, body: body, grid: grid, planner: p, tuning: t) else { continue }
            if f < nearestForward - 0.3 {
                result.nearest = track
                nearestForward = f
            }
        }

        for track in tracks {
            guard let label = track.label, label.tier == .hazard, track.id != result.nearest?.id else { continue }
            let (f, l) = body.local(SIMD3(track.position.x, 0, track.position.y))
            guard f > t.minRange, f <= t.sideMentionDistance, abs(l) > half + 0.1, abs(l) <= 1.5,
                  hasSupport(grid: grid, forward: f, lateral: l) else { continue }
            result.side.append(SideLabel(label: label, track: track.id, onLeft: l < 0, distance: f))
        }
        result.side.sort { $0.distance < $1.distance }
        return result
    }

    /// The forward distance of a world spot (x, z) if it is the obstacle the planner is reacting to: in the
    /// corridor, within `labelMaxDistance`, at the distance of the obstacle straight ahead, with LiDAR under it.
    static func inPath(
        _ spot: SIMD2<Float>, body: BodyFrame, grid: OccupancyGrid, planner p: PlannerOutput, tuning t: Tuning
    ) -> Float? {
        guard let ahead = p.nearestObstacle else { return nil }
        let (f, l) = body.local(SIMD3(spot.x, 0, spot.y))
        guard f <= t.labelMaxDistance, f >= ahead - 0.3, f <= ahead + 0.7, abs(l) <= t.corridorWidth / 2 + 0.2,
              hasSupport(grid: grid, forward: f, lateral: l) else { return nil }
        return f
    }

    /// One line for the debug view: what is being named, or why the closest confirmed name is not.
    static func status(
        nearest: LabelTrack?, named: [LabelTrack], candidates: Int,
        body: BodyFrame, grid: OccupancyGrid, planner p: PlannerOutput, tuning t: Tuning
    ) -> String {
        func tierNote(_ label: ObstacleLabel) -> String { label.tier == .hazard ? "" : ", Chatty only" }
        if let track = nearest, let label = track.label {
            let f = body.local(SIMD3(track.position.x, 0, track.position.y)).forward
            return String(format: "Naming %@ at %.1f m%@", label.rawValue, f, tierNote(label))
        }
        let placed = named.compactMap { track -> (track: LabelTrack, label: ObstacleLabel, f: Float, l: Float)? in
            guard let label = track.label else { return nil }
            let (f, l) = body.local(SIMD3(track.position.x, 0, track.position.y))
            return f > 0 ? (track, label, f, l) : nil
        }
        guard let closest = placed.min(by: { $0.f < $1.f }) else {
            return candidates == 0 ? "No detections placed in the world" : "Seen \(candidates), none confirmed yet"
        }
        let what = String(format: "%@ at %.1f m", closest.label.rawValue, closest.f)
        guard let ahead = p.nearestObstacle else { return "\(what): nothing straight ahead" }
        if closest.f > t.labelMaxDistance { return String(format: "%@: farther than %.1f m", what, t.labelMaxDistance) }
        if abs(closest.l) > t.corridorWidth / 2 + 0.2 { return String(format: "%@: %.1f m to the side", what, closest.l) }
        if closest.f < ahead - 0.3 || closest.f > ahead + 0.7 {
            return String(format: "%@: obstacle ahead is at %.1f m", what, ahead)
        }
        return "\(what): no depth under it"
    }

    /// An obstacle cell within 0.3 m of the spot.
    static func hasSupport(grid: OccupancyGrid, forward: Float, lateral: Float, radius: Float = 0.3) -> Bool {
        let steps = Int((radius / grid.cellSize).rounded())
        for dr in -steps...steps {
            for dc in -steps...steps {
                let f = forward + Float(dr) * grid.cellSize
                let l = lateral + Float(dc) * grid.cellSize
                guard let i = grid.index(forward: f, lateral: l) else { continue }
                let state = grid.cells[i].state
                if state == .obstacle || state == .overhead { return true }
            }
        }
        return false
    }
}
