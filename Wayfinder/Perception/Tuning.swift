import Foundation
import Observation

/// Every tunable number in one place. The debug Tuning screen edits these live; they persist in UserDefaults.
/// Distances in meters, angles in degrees, times in seconds.
struct Tuning: Codable, Equatable, Sendable {
    // Capture
    var targetFPS: Double = 30
    var sampleStride: Int = 2
    var useSmoothedDepth = false
    var mediumConfidenceMaxRange: Float = 2.5
    var minRange: Float = 0.3
    var maxRange: Float = 4.0

    // Floor
    var defaultCameraHeight: Float = 1.3
    var floorTimeConstant: Double = 2.0
    var stepThreshold: Float = 0.15

    // Height bands, relative to the floor
    var dropThreshold: Float = -0.12
    var floorBand: Float = 0.08
    var overheadStart: Float = 1.2
    var obstacleTop: Float = 2.0

    // Grid
    var cellSize: Float = 0.1
    var gridHalfWidth: Float = 2.0
    var minPointsPerCell: Int = 3
    var persistenceFrames: Int = 2
    var inferDropFromMissingFloor = true
    var inferredDropMaxDistance: Float = 2.0
    var inferredDropRows: Int = 3

    // Planner
    var corridorWidth: Float = 0.7
    var headingCount: Int = 16
    var headingSpanDegrees: Float = 40
    var unknownRunLimit: Float = 0.6
    var clearDistance: Float = 3.0
    var stopDistance: Float = 0.6
    var urgencyExponent: Float = 0.6
    var turnPenalty: Float = 0.6
    var switchPenalty: Float = 0.8
    var goalWeight: Float = 1.0
    var headingSmoothing: Float = 0.15
    var hysteresisSeconds: Double = 0.3
    var straightDeadbandDegrees: Float = 6

    // Cues
    var steerTriggerDistance: Float = 2.5
    var slightTurnDegrees: Float = 15
    var stopUrgency: Float = 0.9
    var dropAlertDistance: Float = 1.5
    var overheadAlertDistance: Float = 2.0
    var repeatInterval: Double = 2.5
    var queueExpiry: Double = 1.5
    var clearHoldSeconds: Double = 1.0
    var pulseMaxInterval: Double = 1.0
    var pulseMinInterval: Double = 0.12

    static let defaults = Tuning()
}

@Observable
final class TuningStore {
    private static let key = "wayfinder.tuning.v1"

    var tuning: Tuning {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Tuning.self, from: data) {
            tuning = stored
        } else {
            tuning = Tuning()
        }
    }

    func reset() {
        tuning = Tuning()
    }

    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(tuning)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tuning) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
