import XCTest
@testable import Wayfinder

final class PlannerTests: XCTestCase {
    var tuning = Tuning()
    var edge: Float { tuning.gridHalfWidth }

    /// Every cell seen as floor.
    func openGrid() -> OccupancyGrid {
        var grid = OccupancyGrid(tuning: tuning)
        for i in grid.cells.indices { grid.cells[i].state = .free }
        return grid
    }

    func fill(_ grid: inout OccupancyGrid, forward: ClosedRange<Float>, lateral: ClosedRange<Float>, with state: CellState) {
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let c = grid.center(col: col, row: row)
                if forward.contains(c.forward) && lateral.contains(c.lateral) {
                    grid.cells[grid.index(col: col, row: row)].state = state
                }
            }
        }
    }

    /// Runs the planner for `seconds` at 30 fps on a fixed grid.
    func run(_ planner: GapPlanner, grid: OccupancyGrid, seconds: Double, start: TimeInterval = 0) -> PlannerOutput {
        var output = PlannerOutput()
        var t = start
        while t <= start + seconds {
            output = planner.plan(grid: grid, time: t, goalHeading: nil, tuning: tuning).0
            t += 1.0 / 30.0
        }
        return output
    }

    func testOpenPathGoesStraightWithNoUrgency() {
        let output = run(GapPlanner(), grid: openGrid(), seconds: 1)
        XCTAssertTrue(output.pathVisible)
        XCTAssertEqual(output.urgency, 0, accuracy: 0.001)
        XCTAssertEqual(output.heading, 0, accuracy: 0.05)
        XCTAssertNil(output.nearestObstacle)
    }

    func testWallLeftOfCenterSteersRight() {
        var grid = openGrid()
        fill(&grid, forward: 1.4...1.6, lateral: -edge...0.4, with: .obstacle)
        let output = run(GapPlanner(), grid: grid, seconds: 2)
        XCTAssertGreaterThan(output.heading, 0.1, "should steer right, around the wall's open end")
        XCTAssertEqual(output.nearestObstacle ?? 0, 1.4, accuracy: 0.15)
        XCTAssertGreaterThan(output.urgency, 0.3)
    }

    func testCloseWallEverywhereIsBlocked() {
        var grid = openGrid()
        fill(&grid, forward: 0.4...0.5, lateral: -edge...edge, with: .obstacle)
        let output = run(GapPlanner(), grid: grid, seconds: 0.5)
        XCTAssertTrue(output.blocked)
        XCTAssertEqual(output.urgency, 1, accuracy: 0.001)
    }

    func testDropOffAndOverheadAreReported() {
        var grid = openGrid()
        fill(&grid, forward: 1.2...1.4, lateral: -0.5...0.5, with: .dropOff)
        var output = run(GapPlanner(), grid: grid, seconds: 0.2)
        XCTAssertEqual(output.dropOffAhead ?? 0, 1.2, accuracy: 0.15)

        grid = openGrid()
        fill(&grid, forward: 1.8...1.9, lateral: -0.5...0.5, with: .overhead)
        output = run(GapPlanner(), grid: grid, seconds: 0.2)
        XCTAssertEqual(output.overheadAhead ?? 0, 1.8, accuracy: 0.15)
    }

    func testUnseenDirectionsAreNotTreatedAsGaps() {
        // Only a narrow strip straight ahead was seen; the planner must not steer into the unknown.
        var grid = OccupancyGrid(tuning: tuning)
        fill(&grid, forward: 0...4, lateral: -0.4...0.4, with: .free)
        let output = run(GapPlanner(), grid: grid, seconds: 1)
        XCTAssertEqual(output.heading, 0, accuracy: 0.1)
    }

    func testHysteresisPreventsFlipping() {
        var leftGap = openGrid()
        fill(&leftGap, forward: 1.0...1.2, lateral: -0.3...edge, with: .obstacle)
        var rightGap = openGrid()
        fill(&rightGap, forward: 1.0...1.2, lateral: -edge...0.3, with: .obstacle)

        let planner = GapPlanner()
        let settled = run(planner, grid: leftGap, seconds: 1.5)
        XCTAssertLessThan(settled.heading, 0, "settles left")

        // Alternate the gap side every 100 ms, faster than the 300 ms hysteresis.
        var t = 1.6
        var output = settled
        for i in 0..<12 {
            output = run(planner, grid: i % 2 == 0 ? rightGap : leftGap, seconds: 0.1, start: t)
            t += 0.133
        }
        XCTAssertLessThan(output.heading, 0, "should not have flipped to the right")
    }

    func testInferredDropFromMissingFloor() {
        tuning.inferDropFromMissingFloor = true
        var grid = OccupancyGrid(tuning: tuning)
        fill(&grid, forward: 0.3...1.0, lateral: -edge...edge, with: .free)
        // 1.0 to 1.6 m: no returns at all (a step edge), then floor again.
        fill(&grid, forward: 1.6...4.0, lateral: -edge...edge, with: .free)
        grid.inferDropsFromMissingFloor(tuning: tuning)
        let output = run(GapPlanner(), grid: grid, seconds: 0.2)
        XCTAssertNotNil(output.dropOffAhead)
        XCTAssertEqual(output.dropOffAhead ?? 0, 1.0, accuracy: 0.15)
    }

    func testWorldMapNeedsTwoFramesAndRemembers() {
        var map = WorldMap(cellSize: tuning.cellSize)
        let key = map.key(x: 1.05, z: -2.05)
        map.update(observed: [key: .obstacle], time: 0, tuning: tuning)
        XCTAssertEqual(map.state(key: key, time: 0, tuning: tuning), .free, "one frame is not enough")
        map.update(observed: [key: .obstacle], time: 0.033, tuning: tuning)
        XCTAssertEqual(map.state(key: key, time: 0.033, tuning: tuning), .obstacle, "two frames confirm")
        // Out of view: remembered until memorySeconds pass.
        XCTAssertEqual(map.state(key: key, time: 5, tuning: tuning), .obstacle)
        XCTAssertEqual(map.state(key: key, time: tuning.memorySeconds + 1, tuning: tuning), .unknown)
        // Seen clear again: it clears.
        map.update(observed: [key: .free], time: 0.1, tuning: tuning)
        XCTAssertEqual(map.state(key: key, time: 0.1, tuning: tuning), .free)
    }

    func testStrayPointsLeaveACellUnknown() {
        XCTAssertEqual(CellState.classify(floor: 5, low: 1, high: 0, drop: 0, minPoints: 3), .unknown)
        XCTAssertEqual(CellState.classify(floor: 5, low: 0, high: 0, drop: 0, minPoints: 3), .free)
        XCTAssertEqual(CellState.classify(floor: 0, low: 3, high: 0, drop: 0, minPoints: 3), .obstacle)
    }

    func testSingleDropCellDoesNotBlock() {
        var grid = openGrid()
        fill(&grid, forward: 1.2...1.3, lateral: 0.0...0.1, with: .dropOff)
        let output = run(GapPlanner(), grid: grid, seconds: 0.5)
        XCTAssertNil(output.dropOffAhead)
        XCTAssertNil(output.nearestObstacle)
    }

    func testOverheadDoesNotBlockByDefault() {
        var grid = openGrid()
        fill(&grid, forward: 1.0...1.1, lateral: -edge...edge, with: .overhead)
        let output = run(GapPlanner(), grid: grid, seconds: 0.5)
        XCTAssertNil(output.nearestObstacle)
        XCTAssertEqual(output.urgency, 0, accuracy: 0.001)
    }

    func testPrefersPathWithRoomOverPathAlongAWall() {
        // Box ahead. The left gap runs along a wall; the right gap is open. Go right.
        var grid = openGrid()
        fill(&grid, forward: 1.0...1.2, lateral: -0.4...0.4, with: .obstacle)
        fill(&grid, forward: 0.3...4.0, lateral: -edge...(-0.9), with: .obstacle)
        let output = run(GapPlanner(), grid: grid, seconds: 2)
        XCTAssertGreaterThan(output.heading, 0.1)
    }

    func testIntentBreaksATie() {
        // Symmetric box: with the user's walking direction to the right, choose right.
        var grid = openGrid()
        fill(&grid, forward: 1.2...1.4, lateral: -0.5...0.5, with: .obstacle)
        let planner = GapPlanner()
        var output = PlannerOutput()
        var t = 0.0
        while t <= 2 {
            output = planner.plan(grid: grid, time: t, goalHeading: nil, intentHeading: 0.3, tuning: tuning).0
            t += 1.0 / 30.0
        }
        XCTAssertGreaterThan(output.heading, 0.3)
    }

    func testStairsUpAreDetected() {
        // Floor to 1.5 m, then 17 cm risers with 28 cm treads.
        var profile: [Float?] = []
        var d: Float = 0.3
        while d < 3.5 {
            let height: Float = d < 1.5 ? 0 : 0.17 * Float(Int((d - 1.5) / 0.28) + 1)
            profile.append(height)
            d += StairDetector.binSize
        }
        let stairs = StairDetector.detect(StairDetector.plateaus(profile, start: 0.3))
        XCTAssertEqual(stairs?.direction, .up)
        XCTAssertEqual(stairs?.distance ?? 0, 1.5, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(stairs?.steps ?? 0, 3)
    }

    func testStairsDownAreDetectedButACurbIsNot() {
        func profile(steps: Int) -> [Float?] {
            var values: [Float?] = []
            var d: Float = 0.3
            while d < 3.5 {
                let level = d < 1.2 ? 0 : min(steps, Int((d - 1.2) / 0.3) + 1)
                values.append(-0.17 * Float(level))
                d += StairDetector.binSize
            }
            return values
        }
        XCTAssertEqual(StairDetector.detect(StairDetector.plateaus(profile(steps: 5), start: 0.3))?.direction, .down)
        XCTAssertNil(StairDetector.detect(StairDetector.plateaus(profile(steps: 1), start: 0.3)), "one step is a curb")
    }

    func testTwoStepsAreNotStairs() {
        var profile: [Float?] = []
        var d: Float = 0.3
        while d < 3.5 {
            let level = d < 1.2 ? 0 : min(2, Int((d - 1.2) / 0.3) + 1)
            profile.append(-0.17 * Float(level))
            d += StairDetector.binSize
        }
        XCTAssertNil(StairDetector.detect(StairDetector.plateaus(profile, start: 0.3)), "a double curb is not a staircase")
    }

    func testUnevenPavementIsNotStairs() {
        // Flat patches of different lengths, each a few centimeters up or down from the last.
        let patches: [(length: Float, height: Float)] = [
            (0.9, 0), (0.35, 0.07), (0.5, 0.13), (0.25, 0.05), (0.6, 0.12), (0.4, 0.2), (0.3, 0.1),
        ]
        var profile: [Float?] = []
        for patch in patches {
            profile += [Float?](repeating: patch.height, count: Int((patch.length / StairDetector.binSize).rounded()))
        }
        XCTAssertNil(StairDetector.detect(StairDetector.plateaus(profile, start: 0.3)))
    }

    func testIrregularRisersAreNotStairs() {
        // Three rises, but 11, 20 and 12 cm: rubble or a broken curb, not built stairs.
        let patches: [(length: Float, height: Float)] = [(1.0, 0), (0.3, 0.11), (0.3, 0.31), (0.3, 0.43), (0.6, 0.43)]
        var profile: [Float?] = []
        for patch in patches {
            profile += [Float?](repeating: patch.height, count: Int((patch.length / StairDetector.binSize).rounded()))
        }
        XCTAssertNil(StairDetector.detect(StairDetector.plateaus(profile, start: 0.3)))
    }

    func testBothCorridorHalvesMustAgree() {
        var stairs: [Float?] = []
        var d: Float = 0.3
        while d < 3.5 {
            stairs.append(d < 1.5 ? 0 : 0.17 * Float(Int((d - 1.5) / 0.28) + 1))
            d += StairDetector.binSize
        }
        let flat = [Float?](repeating: 0, count: stairs.count)
        let seen = StairDetector.plateaus(stairs, start: 0.3)
        XCTAssertNotNil(StairDetector.detect(left: seen, right: seen))
        XCTAssertNil(StairDetector.detect(left: seen, right: StairDetector.plateaus(flat, start: 0.3)))
    }

    func testFlatFloorHasNoStairs() {
        let profile = [Float?](repeating: 0.01, count: 60)
        XCTAssertNil(StairDetector.detect(StairDetector.plateaus(profile, start: 0.3)))
    }

    func testCenteredBoxSteersAroundIt() {
        // A 1 m wide box 1.2 m ahead: only wide headings clear it, and the planner must take one.
        var grid = openGrid()
        fill(&grid, forward: 1.2...1.4, lateral: -0.5...0.5, with: .obstacle)
        let output = run(GapPlanner(), grid: grid, seconds: 2)
        XCTAssertGreaterThan(abs(output.heading), 0.4)
    }

    func testHeightBands() {
        XCTAssertEqual(HeightBand.classify(-0.3, tuning: tuning), .drop)
        XCTAssertEqual(HeightBand.classify(0.0, tuning: tuning), .floor)
        XCTAssertEqual(HeightBand.classify(0.5, tuning: tuning), .low)
        XCTAssertEqual(HeightBand.classify(1.5, tuning: tuning), .high)
        XCTAssertEqual(HeightBand.classify(2.5, tuning: tuning), .ignore)
    }
}
