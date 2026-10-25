import Foundation

enum CellState: UInt8, Sendable {
    case unknown, free, obstacle, dropOff, overhead

    var isBlocking: Bool { self == .obstacle || self == .dropOff || self == .overhead }

    /// One cell's point counts for one frame. A few stray points above or below the floor are not enough to
    /// call the cell blocked, and not enough to call it free either, so it stays unknown for this frame.
    static func classify(floor: UInt16, low: UInt16, high: UInt16, drop: UInt16, minPoints: Int) -> CellState {
        let need = UInt16(max(1, minPoints))
        if low >= need { return .obstacle }
        if high >= need { return .overhead }
        if drop >= need { return .dropOff }
        if low > 0 || high > 0 || drop > 0 { return .unknown }
        return floor > 0 ? .free : .unknown
    }
}

struct GridCell: Sendable {
    var state: CellState = .unknown
    var minHeight: Float = .infinity
    var maxHeight: Float = -.infinity
    var hits: UInt16 = 0
    /// True when the drop-off came from missing floor rather than points below the floor.
    var inferred = false
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
        floor.indices.map { i in
            CellState.classify(floor: floor[i], low: low[i], high: high[i], drop: drop[i], minPoints: minPoints)
        }
    }

    func hits(_ i: Int) -> UInt16 { floor[i] &+ low[i] &+ high[i] &+ drop[i] }
}
