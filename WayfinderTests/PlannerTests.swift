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
        var grid = OccupancyGrid(tuning: tuning)
        fill(&grid, forward: 0.3...1.0, lateral: -edge...edge, with: .free)
        // 1.0 to 1.6 m: no returns at all (a step edge), then floor again.
        fill(&grid, forward: 1.6...4.0, lateral: -edge...edge, with: .free)
        grid.inferDropsFromMissingFloor(tuning: tuning)
        let output = run(GapPlanner(), grid: grid, seconds: 0.2)
        XCTAssertNotNil(output.dropOffAhead)
        XCTAssertEqual(output.dropOffAhead ?? 0, 1.0, accuracy: 0.15)
    }

    func testGridTrackerNeedsTwoOfThreeFrames() {
        var tracker = GridTracker()
        let blocked: [CellState] = [.obstacle]
        let clear: [CellState] = [.free]
        XCTAssertEqual(tracker.update(raw: blocked, tuning: tuning), [.obstacle], "first frame: one of one")
        tracker.reset()
        _ = tracker.update(raw: clear, tuning: tuning)
        _ = tracker.update(raw: clear, tuning: tuning)
        XCTAssertEqual(tracker.update(raw: blocked, tuning: tuning), [.free], "one noisy frame is ignored")
        XCTAssertEqual(tracker.update(raw: blocked, tuning: tuning), [.obstacle], "two of three confirms")
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
