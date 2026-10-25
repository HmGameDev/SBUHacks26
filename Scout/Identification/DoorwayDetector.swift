import Foundation

/// A confirmed doorway ahead, in the wearer's body frame at the time of the frame.
struct DoorwayInfo: Sendable, Equatable {
    let track: Int
    let forward: Float
    /// Negative is left.
    let lateral: Float
}

/// Doorways from the depth grid alone: an opening `doorwayMinWidth` to `doorwayMaxWidth` wide, with at least
/// `doorwayWallLength` of tall wall on both sides at the same distance, and nothing blocking in the opening.
/// The phone's detector only knows doors, and an open doorway is the thing an indoor walker is looking for.
/// Two tall things with a gap between them (a person beside a wall, two bookcases) can pass, so a doorway is
/// only ever announced, never steered toward or treated as an obstacle. Not yet checked on a phone.
enum DoorwayDetector {
    struct Doorway: Equatable {
        let forward: Float
        let lateral: Float
        let width: Float
    }

    static func detect(_ grid: OccupancyGrid, tuning t: Tuning) -> [Doorway] {
        let cell = grid.cellSize
        let wallCells = max(1, Int((t.doorwayWallLength / cell).rounded()))
        let minGap = max(1, Int((t.doorwayMinWidth / cell).rounded()))
        let maxGap = max(minGap, Int((t.doorwayMaxWidth / cell).rounded()))
        let firstRow = max(1, Int(t.doorwayMinDistance / cell))
        let lastRow = min(grid.rows - 2, Int(t.doorwayMaxDistance / cell))
        guard firstRow <= lastRow else { return [] }

        // Wall: a tall obstacle in this row or the next one either way, so a wall seen at an angle still counts.
        func wall(_ col: Int, _ row: Int) -> Bool {
            (row - 1...row + 1).contains { r in
                let c = grid.cells[grid.index(col: col, row: r)]
                return c.state == .obstacle && c.maxHeight >= t.doorwayWallTop
            }
        }
        // Opening: nothing blocking across it, and floor seen somewhere in it.
        func open(_ cols: Range<Int>, _ row: Int) -> Bool {
            var sawFloor = false
            for r in row - 1...row + 1 {
                for col in cols {
                    let state = grid.cells[grid.index(col: col, row: r)].state
                    if state.isBlocking { return false }
                    if state == .free { sawFloor = true }
                }
            }
            return sawFloor
        }

        var found: [Doorway] = []
        for row in firstRow...lastRow {
            var col = 0
            while col < grid.cols {
                guard wall(col, row) else { col += 1; continue }
                var leftEnd = col
                while leftEnd + 1 < grid.cols, wall(leftEnd + 1, row) { leftEnd += 1 }
                var rightStart = leftEnd + 1
                while rightStart < grid.cols, !wall(rightStart, row) { rightStart += 1 }
                let gap = rightStart - leftEnd - 1
                if rightStart < grid.cols, leftEnd - col + 1 >= wallCells, gap >= minGap, gap <= maxGap {
                    var rightEnd = rightStart
                    while rightEnd + 1 < grid.cols, wall(rightEnd + 1, row) { rightEnd += 1 }
                    if rightEnd - rightStart + 1 >= wallCells, open(leftEnd + 1..<rightStart, row) {
                        let origin = grid.center(col: 0, row: row)
                        let middle = Float(leftEnd + 1 + rightStart - 1) / 2
                        found.append(Doorway(forward: origin.forward, lateral: origin.lateral + middle * cell, width: Float(gap) * cell))
                    }
                }
                col = rightStart
            }
        }

        // The same opening shows up on neighboring rows; keep the nearest row of each.
        var merged: [Doorway] = []
        for door in found where !merged.contains(where: {
            abs($0.lateral - door.lateral) < 0.4 && abs($0.forward - door.forward) < 0.5
        }) {
            merged.append(door)
        }
        return merged
    }
}
