import Foundation
import simd

enum PointClass: UInt8, Sendable {
    case floor, obstacle, overhead, dropOff, ignored, lowConfidence
}

/// One sampled depth pixel, for the debug overlays.
struct PointSample: Sendable {
    /// Pixel in the native landscape depth image.
    let u: Float
    let v: Float
    let forward: Float
    let lateral: Float
    /// Meters above the floor.
    var height: Float
    var cls: PointClass
}

struct PerceptionResult: Sendable {
    let timestamp: TimeInterval
    let planner: PlannerOutput
    let candidates: [GapCandidate]
    let grid: OccupancyGrid
    let floorStatus: FloorEstimator.Status
    let cameraHeight: Float?
    /// Walking direction in world space (see `BodyFrame.yaw`), nil if the phone points up or down.
    let bodyYaw: Float?
    let trackingNormal: Bool
    // Debug only (empty unless requested):
    let points: [PointSample]
    /// Walking corridor on the floor, as a polygon in depth-image pixels.
    let corridor: [SIMD2<Float>]
    /// The chosen heading drawn along the floor, in depth-image pixels.
    let headingPath: [SIMD2<Float>]
    /// The route (or intended walking) direction along the floor, in depth-image pixels.
    let goalPath: [SIMD2<Float>]
    /// Corridor side profile used for stair detection: (forward, median height) per bin.
    let profile: [SIMD2<Float>]
    /// Confirmed obstacle names, drawn about 1 m above the floor at their tracked spot.
    let labelMarks: [LabelMark]
    /// An unnamed obstacle far enough ahead to ask Gemini about (identification only).
    let cloudRequest: CloudRequest?
}

struct CloudRequest: Sendable, Equatable {
    /// World x, z of the obstacle.
    let spot: SIMD2<Float>
    let distance: Float
}

/// A confirmed name for the camera overlay.
struct LabelMark: Sendable, Equatable {
    let text: String
    /// Depth-image pixel.
    let pixel: SIMD2<Float>
    /// This is the obstacle the planner is reacting to.
    let isNearest: Bool
}

/// Frame in, guidance out. Pure apart from its own state, so replaying the same frames gives the same output.
final class PerceptionPipeline {
    var tuning = Tuning()
    /// Name obstacles (Settings > Name obstacles). Off: no pole search and no labels, so output is as before.
    var identify = false
    private var floor = FloorEstimator()
    private var map = WorldMap(cellSize: Tuning().cellSize)
    private let planner = GapPlanner()
    /// World yaw the user was walking along while the path was clear. Passive mode leans back toward it.
    private var intendedYaw: Float?
    private var lastUrgency: Float = 0
    private var lastTime: TimeInterval?
    private var stairsSince: TimeInterval?
    private var lastStairs: StairInfo?
    private var visionTracks = LabelTracker(rules: Tuning().visionLabelRules, firstID: 1)
    private var poleTracks = LabelTracker(rules: Tuning().poleLabelRules, firstID: 1_000_000)
    private struct CloudSpot {
        let id: Int
        let position: SIMD2<Float>
        let name: CloudName
        let time: TimeInterval
    }
    private var cloudSpots: [CloudSpot] = []
    private var cloudAsked: [(spot: SIMD2<Float>, time: TimeInterval)] = []
    private var nextCloudID = 2_000_000

    private let maxDebugPoints = 4000

    func reset() {
        floor = FloorEstimator()
        map = WorldMap(cellSize: tuning.cellSize)
        planner.reset()
        intendedYaw = nil
        lastUrgency = 0
        lastTime = nil
        stairsSince = nil
        lastStairs = nil
        visionTracks.reset()
        poleTracks.reset()
        cloudSpots.removeAll()
        cloudAsked.removeAll()
        nextCloudID = 2_000_000
    }

    /// The runner sent `spot` to Gemini; do not ask about it again for `cloudRetrySeconds`.
    func noteCloudAsked(_ spot: SIMD2<Float>, time: TimeInterval) {
        cloudAsked.append((spot, time))
    }

    /// Gemini's answer for a spot, or nil when it could not tell.
    func ingestCloud(_ name: CloudName?, at spot: SIMD2<Float>, time: TimeInterval) {
        guard let name else { return }
        cloudSpots.append(CloudSpot(id: nextCloudID, position: spot, name: name, time: time))
        nextCloudID += 1
    }

    /// One detector run, already placed in the world by `LabelFusion`.
    func ingest(_ detections: [Detection], time: TimeInterval) {
        visionTracks.rules = tuning.visionLabelRules
        visionTracks.ingest(detections, time: time)
    }

    func process(_ frame: FrameBundle, goalHeading: Float?, wantDebug: Bool) -> PerceptionResult {
        let t = tuning
        let cameraY = frame.cameraTransform.columns.3.y

        guard let body = BodyFrame(cameraTransform: frame.cameraTransform) else {
            var output = PlannerOutput()
            output.reason = "Phone is pointing straight up or down"
            return PerceptionResult(
                timestamp: frame.timestamp, planner: output, candidates: [], grid: OccupancyGrid(tuning: t),
                floorStatus: floor.status, cameraHeight: floor.cameraHeight(cameraY: cameraY), bodyYaw: nil,
                trackingNormal: frame.trackingNormal, points: [], corridor: [], headingPath: [], goalPath: [], profile: [],
                labelMarks: [], cloudRequest: nil
            )
        }

        // 1. Sample depth pixels into world space and the body frame.
        let depth = frame.depth
        let confidence = frame.confidence
        let stride = max(1, t.sampleStride)
        var points: [PointSample] = []
        var worldY: [Float] = []
        var lowConfidence: [PointSample] = []
        var floorCandidates: [Float] = []
        var worldKeys: [Int64] = []
        if map.cellSize != t.cellSize { map = WorldMap(cellSize: t.cellSize) }
        points.reserveCapacity((depth.width / stride) * (depth.height / stride))
        worldY.reserveCapacity(points.capacity)

        func worldPoint(_ u: Int, _ v: Int, _ d: Float) -> SIMD3<Float> {
            Geometry.transform(Geometry.unproject(u: Float(u), v: Float(v), depth: d, intrinsics: frame.intrinsics), by: frame.cameraTransform)
        }
        // Floor candidates must lie on a horizontal surface, so the base of a wall or a box can never be
        // mistaken for the floor during calibration.
        func isHorizontalSurface(_ u: Int, _ v: Int, _ p: SIMD3<Float>) -> Bool {
            // Neighbors a few pixels away, so centimeter-level depth noise does not tip the normal.
            let u2 = u + 3 * stride, v2 = v + 3 * stride
            guard u2 < depth.width, v2 < depth.height else { return false }
            let du = depth.value(u2, v), dv = depth.value(u, v2)
            guard du.isFinite, dv.isFinite, du > 0.1, dv > 0.1 else { return false }
            let normal = simd_cross(worldPoint(u2, v, du) - p, worldPoint(u, v2, dv) - p)
            let length = simd_length(normal)
            return length > 0 && abs(normal.y) / length > 0.85
        }
        let expectedFloorY = floor.floorY ?? (cameraY - t.defaultCameraHeight)

        for v in Swift.stride(from: 0, to: depth.height, by: stride) {
            for u in Swift.stride(from: 0, to: depth.width, by: stride) {
                let d = depth.value(u, v)
                guard d.isFinite, d > 0.1, d <= t.maxRange + 1 else { continue }
                if let confidence {
                    let level = confidence.value(u, v)
                    if level == 0 || (level == 1 && d > t.mediumConfidenceMaxRange) {
                        if wantDebug {
                            lowConfidence.append(PointSample(u: Float(u), v: Float(v), forward: 0, lateral: 0, height: 0, cls: .lowConfidence))
                        }
                        continue
                    }
                }
                let world = worldPoint(u, v, d)
                let (f, l) = body.local(world)
                if f > 0.5, f < t.maxRange, abs(l) < 1.0,
                   abs(world.y - expectedFloorY) < 0.6,
                   isHorizontalSurface(u, v, world) {
                    floorCandidates.append(world.y)
                }
                points.append(PointSample(u: Float(u), v: Float(v), forward: f, lateral: l, height: 0, cls: .ignored))
                worldY.append(world.y)
                worldKeys.append(map.key(x: world.x, z: world.z))
            }
        }

        // 2. Floor.
        floor.update(candidateYs: floorCandidates, cameraY: cameraY, time: frame.timestamp, tuning: t)
        let floorY = floor.floorY ?? (cameraY - t.defaultCameraHeight)

        // 3. Height bands into this frame's body grid (debug stats) and the remembered world map.
        var grid = OccupancyGrid(tuning: t)
        var accumulator = GridAccumulator(count: grid.cells.count)
        var worldCounts = WorldAccumulator()
        var cellIndex = [Int](repeating: -1, count: points.count)
        let half = t.corridorWidth / 2
        // Corridor side profiles for stair detection: all points (debug), and the left and right halves.
        var profileForward: [Float] = [], profileHeight: [Float] = []
        var leftForward: [Float] = [], leftHeight: [Float] = []
        var rightForward: [Float] = [], rightHeight: [Float] = []
        for i in points.indices {
            let height = worldY[i] - floorY
            let band = HeightBand.classify(height, tuning: t)
            points[i].height = height
            switch band {
            case .drop: points[i].cls = .dropOff
            case .floor: points[i].cls = .floor
            case .low, .high: points[i].cls = .obstacle
            case .ignore: points[i].cls = .ignored
            }
            if let index = grid.index(forward: points[i].forward, lateral: points[i].lateral) {
                accumulator.add(index: index, height: height, band: band)
                cellIndex[i] = index
                worldCounts.add(key: worldKeys[i], band: band)
            }
            if abs(points[i].lateral) <= half, height > -0.9, height < 1.0 {
                profileForward.append(points[i].forward)
                profileHeight.append(height)
                if points[i].lateral < 0 {
                    leftForward.append(points[i].forward)
                    leftHeight.append(height)
                } else {
                    rightForward.append(points[i].forward)
                    rightHeight.append(height)
                }
            }
        }

        map.update(observed: worldCounts.rawStates(minPoints: t.minPointsPerCell), time: frame.timestamp, tuning: t)
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let i = grid.index(col: col, row: row)
                let c = grid.center(col: col, row: row)
                let world = body.world(forward: c.forward, lateral: c.lateral, y: 0)
                grid.cells[i].state = map.state(key: map.key(x: world.x, z: world.z), time: frame.timestamp, tuning: t)
                grid.cells[i].hits = accumulator.hits(i)
                grid.cells[i].minHeight = accumulator.minHeight[i]
                grid.cells[i].maxHeight = accumulator.maxHeight[i]
            }
        }
        grid.inferDropsFromMissingFloor(tuning: t)

        // 4. Stairs, from the corridor's side profile.
        let profileStart = max(0.3, t.minRange)
        let profile = StairDetector.profile(forward: profileForward, height: profileHeight, from: profileStart, to: t.maxRange)
        let stairs = StairDetector.detect(
            left: StairDetector.plateaus(
                StairDetector.profile(forward: leftForward, height: leftHeight, from: profileStart, to: t.maxRange),
                start: profileStart
            ),
            right: StairDetector.plateaus(
                StairDetector.profile(forward: rightForward, height: rightHeight, from: profileStart, to: t.maxRange),
                start: profileStart
            )
        )
        if let stairs, stairs.direction == lastStairs?.direction {
            stairsSince = stairsSince ?? frame.timestamp
        } else {
            stairsSince = stairs == nil ? nil : frame.timestamp
        }
        lastStairs = stairs

        // 5. Intended direction: follow the walking direction while the path is clear, hold it while avoiding.
        let dt = max(0, min(0.5, frame.timestamp - (lastTime ?? frame.timestamp)))
        lastTime = frame.timestamp
        let yaw = body.yaw
        if let intended = intendedYaw {
            let offset = Self.wrap(yaw - intended)
            if abs(offset) > .pi / 3 {
                intendedYaw = yaw // a deliberate turn, not an avoidance
            } else if lastUrgency < 0.2 {
                let alpha = Float(1 - exp(-dt / max(0.1, t.intentTimeConstant)))
                intendedYaw = Self.wrap(intended + alpha * offset)
            }
        } else {
            intendedYaw = yaw
        }
        let intentHeading = intendedYaw.map { Self.wrap($0 - yaw) }

        // 6. Plan.
        let (planned, candidates) = planner.plan(
            grid: grid, time: frame.timestamp, goalHeading: goalHeading, intentHeading: intentHeading, tuning: t
        )
        var output = planned
        lastUrgency = output.urgency
        if let stairs, let since = stairsSince, frame.timestamp - since >= t.stairConfirmSeconds {
            output.stairs = stairs
        }

        // 6b. Identification: name the obstacle the planner is reacting to, and hazards beside the path.
        var named: [LabelTrack] = []
        var cloudRequest: CloudRequest?
        if identify {
            poleTracks.rules = t.poleLabelRules
            let poles = PoleDetector.detect(grid, tuning: t).map { pole in
                Detection(
                    label: .pole, confidence: 1, rect: .zero,
                    world: body.world(forward: pole.forward, lateral: pole.lateral, y: floorY + 1.0)
                )
            }
            poleTracks.ingest(poles, time: frame.timestamp)
            visionTracks.rules = t.visionLabelRules
            visionTracks.expire(time: frame.timestamp)
            // A person standing side-on looks like a pole to the grid. Wherever Vision saw something lately, it wins.
            let recent = visionTracks.tracks.filter { frame.timestamp - $0.lastDetected <= 1 }
            let poleNames = poleTracks.confirmed.filter { pole in
                !recent.contains { simd_distance($0.position, pole.position) < 0.6 }
            }
            named = visionTracks.confirmed + poleNames
            let labels = LabelQuery.evaluate(named, body: body, grid: grid, planner: output, tuning: t)
            output.nearestLabel = labels.nearest?.label
            output.nearestLabelTrack = labels.nearest?.id
            output.sideLabels = labels.side

            // Gemini names, only for what the phone could not name.
            let now = frame.timestamp
            cloudSpots.removeAll { now - $0.time > t.cloudHoldSeconds || now < $0.time }
            cloudAsked.removeAll { now - $0.time > t.cloudRetrySeconds || now < $0.time }
            let cloudInPath = cloudSpots.compactMap { spot in
                LabelQuery.inPath(spot.position, body: body, grid: grid, planner: output, tuning: t).map { (spot: spot, forward: $0) }
            }
            if labels.nearest == nil, let spot = cloudInPath.min(by: { $0.forward < $1.forward })?.spot {
                output.nearestCloudName = spot.name.name
                output.nearestCloudHazard = spot.name.hazard
                output.nearestLabelTrack = spot.id
            }
            // Ask early, while the obstacle is still far enough away for the answer to arrive in time.
            if let ahead = output.nearestObstacle, ahead > t.cloudMinDistance, ahead < t.maxRange - 0.2 {
                let world = body.world(forward: ahead, lateral: 0, y: 0)
                let spot = SIMD2(world.x, world.z)
                let known = named.contains { simd_distance($0.position, spot) < 0.8 }
                    || visionTracks.tracks.contains { simd_distance($0.position, spot) < 0.8 }
                    || cloudSpots.contains { simd_distance($0.position, spot) < 0.8 }
                    || cloudAsked.contains { simd_distance($0.spot, spot) < 1.0 }
                if !known { cloudRequest = CloudRequest(spot: spot, distance: ahead) }
            }
        }

        // 7. Debug geometry.
        var debugPoints: [PointSample] = []
        var corridor: [SIMD2<Float>] = []
        var headingPath: [SIMD2<Float>] = []
        var goalPath: [SIMD2<Float>] = []
        var profilePoints: [SIMD2<Float>] = []
        var labelMarks: [LabelMark] = []
        if wantDebug {
            for i in points.indices where points[i].cls == .obstacle {
                let index = cellIndex[i]
                if index >= 0, grid.cells[index].state == .overhead { points[i].cls = .overhead }
            }
            let all = points + lowConfidence
            let keepEvery = max(1, all.count / maxDebugPoints)
            debugPoints = Swift.stride(from: 0, to: all.count, by: keepEvery).map { all[$0] }

            let worldToCamera = frame.cameraTransform.inverse
            let half = t.corridorWidth / 2
            let distances = Array(Swift.stride(from: Float(0.5), through: t.maxRange, by: 0.25))
            let left = distances.compactMap {
                Geometry.project(world: body.world(forward: $0, lateral: -half, y: floorY), worldToCamera: worldToCamera, intrinsics: frame.intrinsics)
            }
            let right = distances.compactMap {
                Geometry.project(world: body.world(forward: $0, lateral: half, y: floorY), worldToCamera: worldToCamera, intrinsics: frame.intrinsics)
            }
            corridor = left + right.reversed()

            let length = min(t.maxRange, max(0.75, output.straightFree ?? t.maxRange))
            headingPath = Swift.stride(from: Float(0.5), through: length, by: 0.25).compactMap { d in
                let world = body.world(forward: d * cosf(output.heading), lateral: d * sinf(output.heading), y: floorY + 0.02)
                return Geometry.project(world: world, worldToCamera: worldToCamera, intrinsics: frame.intrinsics)
            }
            if let goal = output.goalHeading ?? output.intentHeading {
                goalPath = Swift.stride(from: Float(0.5), through: t.maxRange, by: 0.25).compactMap { d in
                    let world = body.world(forward: d * cosf(goal), lateral: d * sinf(goal), y: floorY + 0.01)
                    return Geometry.project(world: world, worldToCamera: worldToCamera, intrinsics: frame.intrinsics)
                }
            }
            profilePoints = profile.enumerated().compactMap { i, h in
                h.map { SIMD2(profileStart + (Float(i) + 0.5) * StairDetector.binSize, $0) }
            }
            let marks: [(id: Int, text: String, spot: SIMD2<Float>)] =
                named.compactMap { track in track.label.map { (track.id, $0.rawValue, track.position) } }
                + cloudSpots.map { ($0.id, $0.name.name.lowercased(), $0.position) }
            labelMarks = marks.compactMap { mark in
                let world = SIMD3(mark.spot.x, floorY + 1.0, mark.spot.y)
                return Geometry.project(world: world, worldToCamera: worldToCamera, intrinsics: frame.intrinsics).map {
                    LabelMark(text: mark.text, pixel: $0, isNearest: mark.id == output.nearestLabelTrack)
                }
            }
        }

        return PerceptionResult(
            timestamp: frame.timestamp,
            planner: output,
            candidates: candidates,
            grid: grid,
            floorStatus: floor.status,
            cameraHeight: cameraY - floorY,
            bodyYaw: body.yaw,
            trackingNormal: frame.trackingNormal,
            points: debugPoints,
            corridor: corridor,
            headingPath: headingPath,
            goalPath: goalPath,
            profile: profilePoints,
            labelMarks: labelMarks,
            cloudRequest: cloudRequest
        )
    }

    /// Wraps an angle to -pi...pi.
    static func wrap(_ angle: Float) -> Float {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }
}
