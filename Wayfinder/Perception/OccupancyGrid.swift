import Foundation

enum CellState: UInt8, Sendable {
    case unknown, free, obstacle, dropOff, overhead

    var isBlocking: Bool { self == .obstacle || self == .dropOff || self == .overhead }
}

/// Reserved for obstacle identification (section 8 of the foundation prompt). Never populated yet.
enum ObstacleLabel: String, Sendable, CaseIterable {
    case unknown, person, pole, vehicle, bicycle, furniture, door
}

struct GridCell: Sendable {
    var state: CellState = .unknown
    var minHeight: Float = .infinity
    var maxHeight: Float = -.infinity
    var hits: UInt16 = 0
    /// True when the drop-off came from missing floor rather than points below the floor.
    var inferred = false
    var label: ObstacleLabel?
}

/// Where a point sits relative to the floor.
enum HeightBand: Sendable {
    case drop, floor, low, high, ignore

    static func classify(_ height: Float, tuning t: Tuning) -> HeightBand {
        if height < t.dropThreshold { return .drop }
        if height < t.floorBand { return .floor }
        if height < t.overheadStart { return .low }
        if height < t.obstacleTop { return .high }
        return .ignore
    }
}

/// Top-down grid in the body frame: rows run forward from the wearer, columns run left to right.
struct OccupancyGrid: Sendable {
    let cellSize: Float
    let halfWidth: Float
    let forwardRange: Float
    let cols: Int
    let rows: Int
    var cells: [GridCell]

    init(cellSize: Float, halfWidth: Float, forwardRange: Float) {
        self.cellSize = cellSize
        self.halfWidth = halfWidth
        self.forwardRange = forwardRange
        cols = max(1, Int((2 * halfWidth / cellSize).rounded()))
        rows = max(1, Int((forwardRange / cellSize).rounded()))
        cells = Array(repeating: GridCell(), count: cols * rows)
    }

    init(tuning t: Tuning) {
        self.init(cellSize: t.cellSize, halfWidth: t.gridHalfWidth, forwardRange: t.maxRange)
    }

    @inline(__always)
    func index(forward: Float, lateral: Float) -> Int? {
        guard forward >= 0, lateral >= -halfWidth else { return nil }
        let col = Int((lateral + halfWidth) / cellSize)
        let row = Int(forward / cellSize)
        guard col < cols, row < rows else { return nil }
        return row * cols + col
    }

    func index(col: Int, row: Int) -> Int { row * cols + col }

    /// Cell center in body coordinates.
    func center(col: Int, row: Int) -> (forward: Float, lateral: Float) {
        ((Float(row) + 0.5) * cellSize, (Float(col) + 0.5) * cellSize - halfWidth)
    }

    func state(forward: Float, lateral: Float) -> CellState? {
        index(forward: forward, lateral: lateral).map { cells[$0].state }
    }

    /// LiDAR often returns nothing past a step edge. If the floor is visible in the walking corridor and
    /// then disappears for several rows within reach, mark the gap as a suspected drop-off.
    mutating func inferDropsFromMissingFloor(tuning t: Tuning) {
        guard t.inferDropFromMissingFloor else { return }
        let half = t.corridorWidth / 2
        let colRange = (0..<cols).filter { abs(center(col: $0, row: 0).lateral) <= half }
        guard !colRange.isEmpty else { return }
        let firstRow = Int(t.minRange / cellSize)
        let lastRow = min(rows - 1, Int(t.inferredDropMaxDistance / cellSize))
        guard firstRow <= lastRow else { return }

        var seenFloor = false
        var run: [Int] = []
        for row in firstRow...lastRow {
            let states = colRange.map { cells[index(col: $0, row: row)].state }
            if states.allSatisfy({ $0 == .unknown }) {
                if seenFloor { run.append(row) }
                continue
            }
            if run.count >= t.inferredDropRows { break }
            run.removeAll()
            // Something solid in the corridor already stops the user; no need to guess further.
            if states.contains(where: { $0.isBlocking }) { return }
            if states.contains(.free) { seenFloor = true }
        }
        guard run.count >= t.inferredDropRows else { return }
        for row in run {
            for col in colRange {
                let i = index(col: col, row: row)
                cells[i].state = .dropOff
                cells[i].inferred = true
            }
        }
    }
}

/// Per-frame point counts per cell, turned into raw cell states.
struct GridAccumulator {
    private(set) var floor: [UInt16]
    private(set) var low: [UInt16]
    private(set) var high: [UInt16]
    private(set) var drop: [UInt16]
    private(set) var minHeight: [Float]
    private(set) var maxHeight: [Float]

    init(count: Int) {
        floor = Array(repeating: 0, count: count)
        low = floor
        high = floor
        drop = floor
        minHeight = Array(repeating: .infinity, count: count)
        maxHeight = Array(repeating: -.infinity, count: count)
    }

    mutating func add(index i: Int, height: Float, band: HeightBand) {
        switch band {
        case .drop: drop[i] &+= 1
        case .floor: floor[i] &+= 1
        case .low: low[i] &+= 1
        case .high: high[i] &+= 1
        case .ignore: return
        }
        minHeight[i] = min(minHeight[i], height)
        maxHeight[i] = max(maxHeight[i], height)
    }

    func rawStates(minPoints: Int) -> [CellState] {
        let need = UInt16(max(1, minPoints))
        return floor.indices.map { i in
            if low[i] >= need { return .obstacle }
            if high[i] >= need { return .overhead }
            if drop[i] >= need { return .dropOff }
            if floor[i] > 0 || low[i] > 0 || high[i] > 0 || drop[i] > 0 { return .free }
            return .unknown
        }
    }

    func hits(_ i: Int) -> UInt16 { floor[i] &+ low[i] &+ high[i] &+ drop[i] }
}

/// A blocking cell must be seen in `persistenceFrames` of the last three frames, which removes
/// single-frame depth noise at the cost of one frame of delay.
struct GridTracker {
    private var history: [[CellState]] = []

    mutating func reset() { history.removeAll() }

    mutating func update(raw: [CellState], tuning t: Tuning) -> [CellState] {
        if let last = history.last, last.count != raw.count { history.removeAll() }
        history.append(raw)
        if history.count > 3 { history.removeFirst() }
        let need = max(1, min(t.persistenceFrames, history.count))

        var out = raw
        for i in raw.indices {
            var obstacle = 0, drop = 0, overhead = 0
            for frame in history {
                switch frame[i] {
                case .obstacle: obstacle += 1
                case .dropOff: drop += 1
                case .overhead: overhead += 1
                default: break
                }
            }
            if obstacle + drop + overhead >= need {
                if obstacle >= drop && obstacle >= overhead {
                    out[i] = .obstacle
                } else if drop >= overhead {
                    out[i] = .dropOff
                } else {
                    out[i] = .overhead
                }
            } else if raw[i].isBlocking {
                out[i] = .free // seen, but not confirmed yet
            }
        }
        return out
    }
}
