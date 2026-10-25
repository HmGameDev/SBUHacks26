import Foundation

/// World-fixed memory of what the camera has seen, so a wall stays known after the user turns away from it.
/// The portrait camera only sees about 48 degrees across; without memory the planner happily steers toward
/// the side of a hallway it has stopped looking at.
///
/// Each cell collects evidence frame by frame: a blocked observation adds one, a clear one removes one.
/// A cell counts as blocked once its evidence reaches `persistenceFrames`, which also filters one-frame
/// depth noise. Cells nobody has seen for `memorySeconds` are forgotten, so people who walked away and
/// drift in the ARKit pose do not build up.
struct WorldMap: Sendable {
    struct Cell: Sendable, Equatable {
        var evidence: Int8 = 0
        var kind: CellState = .obstacle
        var lastSeen: TimeInterval
    }

    let cellSize: Float
    private(set) var cells: [Int64: Cell] = [:]
    private var lastPrune: TimeInterval = -.infinity
    private static let maxEvidence: Int8 = 4

    init(cellSize: Float) {
        self.cellSize = max(0.01, cellSize)
    }

    mutating func reset() {
        cells.removeAll()
        lastPrune = -.infinity
    }

    /// World x, z (meters) to a cell key.
    func key(x: Float, z: Float) -> Int64 {
        let ix = Int32(clamping: Int((x / cellSize).rounded(.down)))
        let iz = Int32(clamping: Int((z / cellSize).rounded(.down)))
        return (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
    }

    /// Fold in one frame of observations. Unknown observations change nothing.
    mutating func update(observed: [Int64: CellState], time: TimeInterval, tuning t: Tuning) {
        for (key, raw) in observed where raw != .unknown {
            var cell = cells[key] ?? Cell(lastSeen: time)
            if raw.isBlocking {
                cell.evidence = min(Self.maxEvidence, cell.evidence + 1)
                cell.kind = raw
            } else {
                cell.evidence = max(0, cell.evidence - 1)
            }
            cell.lastSeen = time
            cells[key] = cell
        }
        if time - lastPrune >= 1 || time < lastPrune {
            lastPrune = time
            let memory = t.memorySeconds
            cells = cells.filter { time - $0.value.lastSeen <= memory && $0.value.lastSeen <= time }
        }
    }

    func state(key: Int64, time: TimeInterval, tuning t: Tuning) -> CellState {
        guard let cell = cells[key], time - cell.lastSeen <= t.memorySeconds else { return .unknown }
        return Int(cell.evidence) >= max(1, t.persistenceFrames) ? cell.kind : .free
    }
}

/// Per-frame point counts keyed by world cell.
struct WorldAccumulator {
    struct Counts {
        var floor: UInt16 = 0
        var low: UInt16 = 0
        var high: UInt16 = 0
        var drop: UInt16 = 0
    }

    private(set) var counts: [Int64: Counts] = [:]

    mutating func add(key: Int64, band: HeightBand) {
        switch band {
        case .drop: counts[key, default: Counts()].drop &+= 1
        case .floor: counts[key, default: Counts()].floor &+= 1
        case .low: counts[key, default: Counts()].low &+= 1
        case .high: counts[key, default: Counts()].high &+= 1
        case .ignore: break
        }
    }

    func rawStates(minPoints: Int) -> [Int64: CellState] {
        counts.mapValues {
            CellState.classify(floor: $0.floor, low: $0.low, high: $0.high, drop: $0.drop, minPoints: minPoints)
        }
    }
}
