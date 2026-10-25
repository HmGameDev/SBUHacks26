import Foundation

struct StairInfo: Sendable, Equatable {
    enum Direction: String, Sendable {
        case up, down
    }

    let direction: Direction
    /// Forward distance to the first step edge, meters.
    let distance: Float
    let steps: Int
}

/// Finds stairs in the walking corridor's side profile: a run of flat treads, each about one riser
/// (11 to 21 cm) above or below the last. One step on its own is a curb, which the drop-off check handles.
///
/// Uneven pavement also makes flat patches at slightly different heights, so real stairs must pass
/// several checks: at least three steps, risers and treads that match each other, and the same steps
/// seen by both the left and right halves of the walking corridor.
enum StairDetector {
    struct Plateau: Equatable {
        let start: Float
        let end: Float
        let height: Float
        var length: Float { end - start }
    }

    static let binSize: Float = 0.05
    static let minRise: Float = 0.11
    static let maxRise: Float = 0.21
    static let flatTolerance: Float = 0.04
    static let minTread: Float = 0.18
    static let maxTread: Float = 0.6
    static let minSteps = 3
    /// How far any riser may differ from the average riser, and any tread from the average tread.
    static let riseTolerance: Float = 0.04
    static let treadTolerance: Float = 0.12
    /// Left and right halves must put the first step within this distance of each other.
    static let sideAgreement: Float = 0.3

    /// Median height above the floor in each forward bin, from points inside the walking corridor.
    static func profile(forward: [Float], height: [Float], from start: Float, to end: Float) -> [Float?] {
        let count = max(0, Int(((end - start) / binSize).rounded(.up)))
        var bins = [[Float]](repeating: [], count: count)
        for (f, h) in zip(forward, height) {
            let i = Int(((f - start) / binSize).rounded(.down))
            guard i >= 0, i < count else { continue }
            bins[i].append(h)
        }
        return bins.map { values in
            guard values.count >= 2 else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// Joins neighboring bins of about the same height into flat stretches. Short gaps (risers facing away,
    /// dropouts) are bridged; stretches shorter than a tread are dropped.
    static func plateaus(_ profile: [Float?], start: Float) -> [Plateau] {
        var result: [Plateau] = []
        var first = -1, last = -1
        var sum: Float = 0, n: Float = 0
        func close() {
            guard first >= 0 else { return }
            let plateau = Plateau(start: start + Float(first) * binSize, end: start + Float(last + 1) * binSize, height: sum / n)
            if plateau.length >= minTread { result.append(plateau) }
            first = -1
            sum = 0
            n = 0
        }
        for (i, value) in profile.enumerated() {
            guard let h = value else {
                if first >= 0, i - last > 3 { close() }
                continue
            }
            if first >= 0, abs(h - sum / n) <= flatTolerance {
                last = i
                sum += h
                n += 1
            } else {
                close()
                first = i
                last = i
                sum = h
                n = 1
            }
        }
        close()
        return result
    }

    static func detect(_ plateaus: [Plateau]) -> StairInfo? {
        // Start from the floor the user stands on.
        guard let base = plateaus.firstIndex(where: { abs($0.height) <= 0.06 }) else { return nil }
        for direction in [StairInfo.Direction.up, .down] {
            var rises: [Float] = []
            var treads: [Float] = []
            var i = base
            while i + 1 < plateaus.count {
                let rise = plateaus[i + 1].height - plateaus[i].height
                let signed = direction == .up ? rise : -rise
                guard signed >= minRise, signed <= maxRise else { break }
                // Every tread except the last visible one must be stair-sized.
                if i > base {
                    guard plateaus[i].length <= maxTread else { break }
                    treads.append(plateaus[i].length)
                }
                rises.append(signed)
                i += 1
            }
            guard rises.count >= minSteps, isRegular(rises, tolerance: riseTolerance),
                  isRegular(treads, tolerance: treadTolerance) else { continue }
            return StairInfo(direction: direction, distance: plateaus[base + 1].start, steps: rises.count)
        }
        return nil
    }

    /// Stairs only when both halves of the corridor see the same stairs.
    static func detect(left: [Plateau], right: [Plateau]) -> StairInfo? {
        guard let a = detect(left), let b = detect(right), a.direction == b.direction,
              abs(a.distance - b.distance) <= sideAgreement else { return nil }
        return StairInfo(direction: a.direction, distance: min(a.distance, b.distance), steps: min(a.steps, b.steps))
    }

    private static func isRegular(_ values: [Float], tolerance: Float) -> Bool {
        guard !values.isEmpty else { return true }
        let mean = values.reduce(0, +) / Float(values.count)
        return values.allSatisfy { abs($0 - mean) <= tolerance }
    }
}
