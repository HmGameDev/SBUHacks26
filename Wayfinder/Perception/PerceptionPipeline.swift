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
}

/// Frame in, guidance out. Pure apart from its own state, so replaying the same frames gives the same output.
final class PerceptionPipeline {
    var tuning = Tuning()
    private var floor = FloorEstimator()
    private var tracker = GridTracker()
    private let planner = GapPlanner()

    private let maxDebugPoints = 4000

    func reset() {
        floor = FloorEstimator()
        tracker.reset()
        planner.reset()
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
                trackingNormal: frame.trackingNormal, points: [], corridor: [], headingPath: []
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
            }
        }

        // 2. Floor.
        floor.update(candidateYs: floorCandidates, cameraY: cameraY, time: frame.timestamp, tuning: t)
        let floorY = floor.floorY ?? (cameraY - t.defaultCameraHeight)

        // 3. Height bands into the grid.
        var grid = OccupancyGrid(tuning: t)
        var accumulator = GridAccumulator(count: grid.cells.count)
        var cellIndex = [Int](repeating: -1, count: points.count)
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
            }
        }

        let states = tracker.update(raw: accumulator.rawStates(minPoints: t.minPointsPerCell), tuning: t)
        for i in grid.cells.indices {
            grid.cells[i].state = states[i]
            grid.cells[i].hits = accumulator.hits(i)
            grid.cells[i].minHeight = accumulator.minHeight[i]
            grid.cells[i].maxHeight = accumulator.maxHeight[i]
        }
        grid.inferDropsFromMissingFloor(tuning: t)

        // 4. Plan.
        let (output, candidates) = planner.plan(grid: grid, time: frame.timestamp, goalHeading: goalHeading, tuning: t)

        // 5. Debug geometry.
        var debugPoints: [PointSample] = []
        var corridor: [SIMD2<Float>] = []
        var headingPath: [SIMD2<Float>] = []
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
            headingPath: headingPath
        )
    }
}
