import CoreGraphics
import simd
import XCTest
@testable import Scout

final class IdentificationTests: XCTestCase {
    let tuning = Tuning()

    // MARK: - Labels

    func testTiersDecideWhoHearsAName() {
        XCTAssertTrue(ObstacleLabel.person.isSpoken(at: .normal))
        XCTAssertTrue(ObstacleLabel.pole.isSpoken(at: .normal))
        XCTAssertFalse(ObstacleLabel.chair.isSpoken(at: .normal))
        XCTAssertTrue(ObstacleLabel.chair.isSpoken(at: .chatty))
        XCTAssertFalse(ObstacleLabel.person.isSpoken(at: .minimal))
    }

    func testEveryLabelHasAPhrase() throws {
        let url = try XCTUnwrap(Bundle(for: CueArbiter.self).url(forResource: "phrases", withExtension: "json"))
        let text = try String(contentsOf: url)
        for label in ObstacleLabel.allCases {
            XCTAssertTrue(text.contains("\"\(label.phrase)\""), "phrases.json is missing \(label.phrase)")
        }
        XCTAssertTrue(text.contains("\"on_left\"") && text.contains("\"on_right\""))
    }

    // MARK: - Vision boxes

    func testUprightBoxMapsToSensorOrientation() {
        // Upright (portrait) box, Vision convention: origin bottom-left.
        let upright = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let sensor = VisionClassifier.sensorRect(fromUpright: upright)
        XCTAssertEqual(sensor.minX, 0.4, accuracy: 1e-6)
        XCTAssertEqual(sensor.minY, 0.6, accuracy: 1e-6)
        XCTAssertEqual(sensor.width, 0.4, accuracy: 1e-6)
        XCTAssertEqual(sensor.height, 0.3, accuracy: 1e-6)
        // Round trip through the debug view's mapping: the box's upright top-left corner (0.1, 0.4 from the top)
        // must come back from the sensor corner that lands there.
        let mapper = PortraitMapper(depthWidth: 100, depthHeight: 100, in: CGSize(width: 100, height: 100))
        let corner = mapper.point(u: Float(sensor.minX) * 100, v: Float(sensor.maxY) * 100)
        XCTAssertEqual(corner.x, 10, accuracy: 1e-3)
        XCTAssertEqual(corner.y, 40, accuracy: 1e-3)
    }

    // MARK: - Fusion

    let intrinsics = simd_float3x3(columns: (
        SIMD3<Float>(100, 0, 0),
        SIMD3<Float>(0, 100, 0),
        SIMD3<Float>(128, 96, 1)
    ))

    func depth(_ value: (Int, Int) -> Float) -> DepthImage {
        var values = [Float](repeating: 0, count: 256 * 192)
        for v in 0..<192 { for u in 0..<256 { values[v * 256 + u] = value(u, v) } }
        return DepthImage(width: 256, height: 192, values: values)
    }

    func testFusionLandsOnTheObjectNotTheWallBehind() throws {
        // A person-shaped patch at 1.5 m covering most of the box, wall at 3 m around and between.
        let image = depth { u, v in (110..<146).contains(u) && (60..<140).contains(v) && u % 6 != 0 ? 1.5 : 3.0 }
        let box = ClassifiedBox(label: .person, confidence: 0.9, rect: CGRect(x: 100.0 / 256, y: 50.0 / 192, width: 56.0 / 256, height: 100.0 / 192))
        let detection = try XCTUnwrap(LabelFusion.fuse(
            [box], depth: image, intrinsics: intrinsics, cameraTransform: matrix_identity_float4x4, maxRange: 4
        ).first)
        let world = try XCTUnwrap(detection.world)
        XCTAssertEqual(world.z, -1.5, accuracy: 0.01, "camera looks down -Z")
    }

    func testFusionWithoutDepthGivesNoPosition() {
        let image = depth { _, _ in .nan }
        let box = ClassifiedBox(label: .dog, confidence: 0.9, rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        let detections = LabelFusion.fuse([box], depth: image, intrinsics: intrinsics, cameraTransform: matrix_identity_float4x4, maxRange: 4)
        XCTAssertNil(detections.first?.world)
    }

    // MARK: - Tracking

    func detection(_ label: ObstacleLabel, x: Float, z: Float, confidence: Float = 0.9) -> Detection {
        Detection(label: label, confidence: confidence, rect: .zero, world: SIMD3(x, 0, z))
    }

    func testANameNeedsThreeOfFiveRuns() {
        var tracker = LabelTracker(rules: tuning.visionLabelRules, firstID: 1)
        tracker.ingest([detection(.person, x: 0, z: -2)], time: 0)
        tracker.ingest([], time: 0.2)
        tracker.ingest([detection(.person, x: 0.1, z: -1.9)], time: 0.4)
        XCTAssertTrue(tracker.confirmed.isEmpty)
        tracker.ingest([detection(.person, x: 0.2, z: -1.8)], time: 0.6)
        XCTAssertEqual(tracker.confirmed.map(\.label), [.person])
        XCTAssertEqual(tracker.tracks.count, 1, "a walking person stays one track")
    }

    func testTracksExpireWithoutDetections() {
        var tracker = LabelTracker(rules: tuning.visionLabelRules, firstID: 1)
        for i in 0..<3 { tracker.ingest([detection(.person, x: 0, z: -2)], time: Double(i) * 0.2) }
        XCTAssertFalse(tracker.confirmed.isEmpty)
        tracker.expire(time: 0.4 + tuning.labelHoldSeconds + 0.01)
        XCTAssertTrue(tracker.tracks.isEmpty)
    }

    func testFarApartDetectionsAreSeparateTracks() {
        var tracker = LabelTracker(rules: tuning.visionLabelRules, firstID: 1)
        tracker.ingest([detection(.person, x: -1, z: -2), detection(.person, x: 1, z: -2)], time: 0)
        XCTAssertEqual(Set(tracker.tracks.map(\.id)), [1, 2])
    }

    func testAPoleThatMovesIsNotAPole() {
        var tracker = LabelTracker(rules: tuning.poleLabelRules, firstID: 1_000_000)
        var time = 0.0
        for _ in 0..<30 {
            tracker.ingest([detection(.pole, x: 0, z: -2)], time: time)
            time += 1.0 / 30
        }
        XCTAssertEqual(tracker.confirmed.count, 1)
        // Now it walks away, a few centimeters per frame.
        for i in 0..<30 {
            tracker.ingest([detection(.pole, x: Float(i) * 0.03, z: -2)], time: time)
            time += 1.0 / 30
        }
        XCTAssertTrue(tracker.confirmed.isEmpty)
    }

    func testAPoleNeedsTime() {
        var tracker = LabelTracker(rules: tuning.poleLabelRules, firstID: 1_000_000)
        for i in 0..<15 { tracker.ingest([detection(.pole, x: 0, z: -2)], time: Double(i) / 30) }
        XCTAssertTrue(tracker.confirmed.isEmpty, "younger than poleMinAge")
        for i in 15..<20 { tracker.ingest([detection(.pole, x: 0, z: -2)], time: Double(i) / 30) }
        XCTAssertEqual(tracker.confirmed.count, 1)
    }

    // MARK: - Grid

    /// A grid of free floor out to 4 m, as a body frame at the origin facing -Z sees it.
    func floorGrid() -> OccupancyGrid {
        var grid = OccupancyGrid(tuning: tuning)
        for i in grid.cells.indices {
            grid.cells[i].state = .free
            grid.cells[i].hits = 5
        }
        return grid
    }

    func setObstacle(_ grid: inout OccupancyGrid, forward: Float, lateral: Float, top: Float) {
        let i = grid.index(forward: forward, lateral: lateral)!
        grid.cells[i].state = .obstacle
        grid.cells[i].minHeight = 0.1
        grid.cells[i].maxHeight = top
    }

    func testThinTallObstacleIsAPole() {
        var grid = floorGrid()
        setObstacle(&grid, forward: 2.05, lateral: 0.05, top: 1.6)
        setObstacle(&grid, forward: 2.15, lateral: 0.05, top: 1.6)
        let poles = PoleDetector.detect(grid, tuning: tuning)
        XCTAssertEqual(poles.count, 1)
        XCTAssertEqual(poles.first?.forward ?? 0, 2.1, accuracy: 0.01)
        XCTAssertEqual(poles.first?.lateral ?? 0, 0.05, accuracy: 0.01)
    }

    func testShortThinObstacleIsNotAPole() {
        var grid = floorGrid()
        setObstacle(&grid, forward: 2.05, lateral: 0.05, top: 0.9)
        XCTAssertTrue(PoleDetector.detect(grid, tuning: tuning).isEmpty)
    }

    func testWallIsNotAPole() {
        var grid = floorGrid()
        for k in 0..<12 { setObstacle(&grid, forward: 2.05, lateral: -0.55 + Float(k) * 0.1, top: 2.0) }
        XCTAssertTrue(PoleDetector.detect(grid, tuning: tuning).isEmpty)
    }

    func testPostAgainstSomethingIsNotAPole() {
        var grid = floorGrid()
        setObstacle(&grid, forward: 2.05, lateral: 0.05, top: 1.6)
        // Something blocking two cells to its right, not touching it.
        setObstacle(&grid, forward: 2.05, lateral: 0.25, top: 0.5)
        XCTAssertTrue(PoleDetector.detect(grid, tuning: tuning).isEmpty)
    }

    // MARK: - Query

    let body = BodyFrame(cameraTransform: matrix_identity_float4x4)!

    func track(_ label: ObstacleLabel, id: Int, forward: Float, lateral: Float) -> LabelTrack {
        // Identity camera: forward is -Z, right is +X.
        let spot = SIMD2<Float>(lateral, -forward)
        return LabelTrack(id: id, position: spot, origin: spot, born: 0, lastDetected: 0, votes: [label], label: label)
    }

    func testNamesTheObstacleThePlannerSees() {
        var grid = floorGrid()
        setObstacle(&grid, forward: 1.55, lateral: 0.05, top: 1.7)
        var planner = PlannerOutput()
        planner.nearestObstacle = 1.5
        let result = LabelQuery.evaluate([track(.person, id: 1, forward: 1.55, lateral: 0.05)], body: body, grid: grid, planner: planner, tuning: tuning)
        XCTAssertEqual(result.nearest?.label, .person)
    }

    func testNoNameWithoutLiDARUnderIt() {
        let grid = floorGrid()
        var planner = PlannerOutput()
        planner.nearestObstacle = 1.5
        let result = LabelQuery.evaluate([track(.person, id: 1, forward: 1.55, lateral: 0.05)], body: body, grid: grid, planner: planner, tuning: tuning)
        XCTAssertNil(result.nearest, "a box with nothing solid under it is never named")
    }

    func testNoNameForSomethingFartherThanTheObstacle() {
        var grid = floorGrid()
        setObstacle(&grid, forward: 1.05, lateral: 0.05, top: 0.8)
        setObstacle(&grid, forward: 2.55, lateral: 0.05, top: 1.7)
        var planner = PlannerOutput()
        planner.nearestObstacle = 1.0
        let result = LabelQuery.evaluate([track(.person, id: 1, forward: 2.55, lateral: 0.05)], body: body, grid: grid, planner: planner, tuning: tuning)
        XCTAssertNil(result.nearest, "the box ahead is in the way, not the person behind it")
    }

    func testHazardBesideThePathIsASideLabel() {
        var grid = floorGrid()
        setObstacle(&grid, forward: 1.25, lateral: -0.85, top: 1.7)
        setObstacle(&grid, forward: 1.25, lateral: 0.85, top: 0.8)
        let tracks = [track(.person, id: 1, forward: 1.25, lateral: -0.85), track(.chair, id: 2, forward: 1.25, lateral: 0.85)]
        let result = LabelQuery.evaluate(tracks, body: body, grid: grid, planner: PlannerOutput(), tuning: tuning)
        XCTAssertEqual(result.side, [SideLabel(label: .person, track: 1, onLeft: true, distance: 1.25)], "chairs are not side mentions")
    }
}
