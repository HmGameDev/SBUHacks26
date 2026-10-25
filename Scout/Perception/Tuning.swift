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
    var dropThreshold: Float = -0.15
    var floorBand: Float = 0.08
    var overheadStart: Float = 1.2
    var obstacleTop: Float = 2.0

    // Grid
    var cellSize: Float = 0.1
    var gridHalfWidth: Float = 2.0
    var minPointsPerCell: Int = 3
    /// Frames of evidence before a cell counts as blocked (the remembered map's confirm threshold).
    var persistenceFrames: Int = 2
    /// How long the map remembers a cell the camera no longer sees.
    var memorySeconds: Double = 8
    /// Dark or shiny floors often return nothing, so guessing drop-offs from missing floor is off by default.
    var inferDropFromMissingFloor = false
    var inferredDropMaxDistance: Float = 2.0
    var inferredDropRows: Int = 3

    // Planner
    var corridorWidth: Float = 0.7
    /// Extra width on each side for the clearance check, so paths hugging a wall score lower.
    var clearanceMargin: Float = 0.3
    var clearanceWeight: Float = 0.5
    /// Pull toward the direction the user was walking before the obstacle (passive mode).
    var intentWeight: Float = 0.5
    var intentTimeConstant: Double = 3
    /// Drop-off cells needed side by side before the path counts as blocked by a drop.
    var dropMinCells: Int = 3
    /// Overhead detection is unreliable on a chest mount, so it does not block paths unless turned on.
    var overheadBlocks = false
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
    var dropAlertDistance: Float = 1.2
    /// A drop-off must be seen this long before "Step down" is spoken.
    var dropConfirmSeconds: Double = 0.3
    var stairAlertDistance: Float = 2.5
    var stairConfirmSeconds: Double = 0.6
    var repeatInterval: Double = 2.5
    var queueExpiry: Double = 1.5
    var clearHoldSeconds: Double = 1.0
    var pulseMaxInterval: Double = 1.0
    var pulseMinInterval: Double = 0.12

    // Identification (only runs with Settings > Name obstacles on)
    /// Detector runs per second, and the rate when the phone is warm.
    var detectorHz: Double = 5
    var detectorHzWarm: Double = 2
    var detectorMinConfidence: Float = 0.5
    /// The bundled Open Images detector scores lower than Apple's people and dog detectors.
    var objectMinConfidence: Float = 0.35
    /// A name is confirmed once it shows up in `labelVotesNeeded` of the last `labelVoteWindow` runs.
    var labelVoteWindow: Int = 5
    var labelVotesNeeded: Int = 3
    var labelHoldSeconds: Double = 1.5
    var labelMatchRadius: Float = 0.6
    /// Names are only spoken for obstacles this close.
    var labelMaxDistance: Float = 3.0
    /// The same object is named again only after this long, or after it left the path for 3 s.
    var labelRepeatSeconds: Double = 10
    var sideMentionDistance: Float = 2.0
    var sideMentionInterval: Double = 4
    /// Gemini is only asked about unnamed obstacles farther than this, one request every `cloudMinInterval`.
    var cloudMinDistance: Float = 2.5
    var cloudMinInterval: Double = 2
    /// A spot already asked about is not asked again for this long; an answer is kept this long.
    var cloudRetrySeconds: Double = 15
    var cloudHoldSeconds: Double = 30
    // Poles from geometry (PoleDetector); votes are per frame.
    var poleMaxCells: Int = 3
    var poleMinTop: Float = 1.2
    var poleMaxBase: Float = 0.6
    var poleSideCells: Int = 2
    var poleVoteWindow: Int = 20
    var poleVotesNeeded: Int = 12
    var poleMinAge: Double = 0.6
    /// Long enough to keep the name while walking up to the pole, when the floor beside it drops out of view.
    var poleHoldSeconds: Double = 4
    var poleMatchRadius: Float = 0.4
    var poleStaticRadius: Float = 0.3

    static let defaults = Tuning()
}

@Observable
final class TuningStore {
    // Bump the version whenever a field is added: the synthesized decoder rejects data missing a field.
    // v4: identification settings.
    private static let key = "scout.tuning.v4"

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
