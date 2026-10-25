import Foundation

/// Finds the floor height in world coordinates. Calibrates over the first two seconds while the user
/// stands still, then follows slow changes (ramps, slopes) without treating a step as the new floor.
struct FloorEstimator: Sendable {
    enum Status: Equatable, Sendable {
        case calibrating(progress: Float)
        case ready
        case cannotSeeFloor
    }

    private(set) var floorY: Float?
    private(set) var isCalibrated = false
    private(set) var status: Status = .calibrating(progress: 0)

    var calibrationDuration: TimeInterval = 2.0
    var minimumPoints = 40

    private var samples: [Float] = []
    private var windowStart: TimeInterval?
    private var lastUpdate: TimeInterval?

    /// - Parameter candidateYs: world Y of points ahead of the user and well below the camera.
    mutating func update(candidateYs: [Float], cameraY: Float, time: TimeInterval, tuning: Tuning) {
        if !isCalibrated {
            calibrate(candidateYs: candidateYs, cameraY: cameraY, time: time, tuning: tuning)
            return
        }
        guard let current = floorY else { return }
        let dt = max(0, time - (lastUpdate ?? time))
        lastUpdate = time
        // Only points near the current floor: a step down or a curb must not drag the floor with it.
        let near = candidateYs.filter { abs($0 - current) <= tuning.stepThreshold }
        guard near.count >= minimumPoints, let target = Self.percentile(near, 0.5) else { return }
        let alpha = Float(1 - exp(-dt / max(0.1, tuning.floorTimeConstant)))
        floorY = current + alpha * (target - current)
    }

    func cameraHeight(cameraY: Float) -> Float? {
        floorY.map { cameraY - $0 }
    }

    private mutating func calibrate(candidateYs: [Float], cameraY: Float, time: TimeInterval, tuning: Tuning) {
        if floorY == nil { floorY = cameraY - tuning.defaultCameraHeight }
        if windowStart == nil { windowStart = time }
        if candidateYs.count >= minimumPoints, let low = Self.percentile(candidateYs, 0.1) {
            samples.append(low)
        }
        let elapsed = time - (windowStart ?? time)
        guard elapsed >= calibrationDuration else {
            if status != .cannotSeeFloor {
                status = .calibrating(progress: Float(min(1, elapsed / calibrationDuration)))
            }
            return
        }
        if samples.count >= 10, let median = Self.percentile(samples, 0.5) {
            floorY = median
            isCalibrated = true
            status = .ready
            lastUpdate = time
        } else {
            // Not enough floor in view. Keep the provisional floor and try again with a fresh window.
            status = .cannotSeeFloor
            samples.removeAll()
            windowStart = time
        }
    }

    static func percentile(_ values: [Float], _ p: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Float(sorted.count - 1) * p).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}
