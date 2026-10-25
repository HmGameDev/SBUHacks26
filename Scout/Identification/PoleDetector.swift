import Foundation

/// Poles, posts and sign poles from the depth grid alone. The detectors on the phone have no pole class, and
/// poles are among the most common things a cane user walks into.
///
/// A pole is a small group of obstacle cells seen this frame: at most `poleMaxCells` across and deep, rising
/// to `poleMinTop` or higher from near the ground, with open floor on both sides and nothing else blocking
/// beside it. A wall's edge or a door frame fails the open-floor check; a chair or trash can is too short.
/// A person standing side-on can pass, which is why `PerceptionPipeline` drops a pole wherever Vision has
/// recently seen something. The ray-cast simulation behind these numbers is described in the PR.
enum PoleDetector {
    struct Pole: Equatable {
        let forward: Float
        let lateral: Float
    }

    static func detect(_ grid: OccupancyGrid, tuning t: Tuning) -> [Pole] {
        let maxCells = max(1, t.poleMaxCells)
        let sideCells = max(1, t.poleSideCells)
        func candidate(_ i: Int) -> Bool { grid.cells[i].state == .obstacle && grid.cells[i].hits > 0 }

        var visited = [Bool](repeating: false, count: grid.cells.count)
        var poles: [Pole] = []
        for start in grid.cells.indices where !visited[start] && candidate(start) {
            // Flood fill the group (4-neighbors).
            var stack = [start]
            var members: [Int] = []
            visited[start] = true
            while let i = stack.popLast() {
                members.append(i)
                let row = i / grid.cols, col = i % grid.cols
                for (r, c) in [(row + 1, col), (row - 1, col), (row, col + 1), (row, col - 1)] {
                    guard r >= 0, r < grid.rows, c >= 0, c < grid.cols else { continue }
                    let j = grid.index(col: c, row: r)
                    if !visited[j] && candidate(j) {
                        visited[j] = true
                        stack.append(j)
                    }
                }
            }

            let rows = members.map { $0 / grid.cols }
            let cols = members.map { $0 % grid.cols }
            let minRow = rows.min()!, maxRow = rows.max()!, minCol = cols.min()!, maxCol = cols.max()!
            guard maxCol - minCol + 1 <= maxCells, maxRow - minRow + 1 <= maxCells else { continue }
            let top = members.map { grid.cells[$0].maxHeight }.max()!
            let base = members.map { grid.cells[$0].minHeight }.min()!
            guard top >= t.poleMinTop, base <= t.poleMaxBase else { continue }
            guard openFloor(grid, rows: minRow...maxRow, edge: minCol, step: -1, cells: sideCells),
                  openFloor(grid, rows: minRow...maxRow, edge: maxCol, step: 1, cells: sideCells) else { continue }

            let center = grid.center(col: 0, row: 0)
            let forward = center.forward + Float(rows.reduce(0, +)) / Float(rows.count) * grid.cellSize
            let lateral = center.lateral + Float(cols.reduce(0, +)) / Float(cols.count) * grid.cellSize
            poles.append(Pole(forward: forward, lateral: lateral))
        }
        return poles
    }

    /// Beside the group, on one side: nothing blocking, and floor seen at least once.
    private static func openFloor(_ grid: OccupancyGrid, rows: ClosedRange<Int>, edge: Int, step: Int, cells: Int) -> Bool {
        var sawFloor = false
        for row in rows {
            for k in 1...cells {
                let col = edge + step * k
                guard col >= 0, col < grid.cols else { continue }
                let state = grid.cells[grid.index(col: col, row: row)].state
                if state.isBlocking { return false }
                if state == .free { sawFloor = true }
            }
        }
        return sawFloor
    }
}
