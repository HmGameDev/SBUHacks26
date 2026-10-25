import CoreGraphics
import ImageIO
import Vision

/// A color frame for the detector, in the sensor's native landscape orientation (the same as the depth
/// map). `CGImage` is immutable, so handing one between queues is safe.
struct ColorImage: @unchecked Sendable {
    let cgImage: CGImage
}

struct ClassifiedBox: Sendable, Equatable {
    let label: ObstacleLabel
    let confidence: Float
    /// Normalized to the color image, origin top-left, in the same landscape orientation as the depth map.
    let rect: CGRect
}

/// Names what is in a color frame. Never decides whether something is an obstacle; `LabelFusion` only
/// keeps a box whose depth lands on something, and the cue policy only names obstacles LiDAR already sees.
/// Do not name anything `ObjectIdentifier`; that is a Swift standard library type.
protocol ObstacleClassifier: AnyObject {
    /// Called on one queue at a time; implementations need no locking.
    func classify(_ image: CGImage) -> [ClassifiedBox]
}

final class NullClassifier: ObstacleClassifier {
    func classify(_ image: CGImage) -> [ClassifiedBox] { [] }
}

/// Apple's built-in Vision detectors: people and dogs. No model file, no network.
/// The phone is portrait on the chest, so the landscape sensor image is upright when rotated to `.right`,
/// the same assumption `PortraitMapper` makes for the debug view.
final class VisionClassifier: ObstacleClassifier {
    var minConfidence: Float = 0.5

    private let humans: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        // Whole bodies: close up, a chest camera often sees torso and legs but not the head.
        request.upperBodyOnly = false
        return request
    }()
    private let animals = VNRecognizeAnimalsRequest()

    func classify(_ image: CGImage) -> [ClassifiedBox] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .right, options: [:])
        do {
            try handler.perform([humans, animals])
        } catch {
            return []
        }
        var boxes: [ClassifiedBox] = []
        for observation in humans.results ?? [] where observation.confidence >= minConfidence {
            boxes.append(ClassifiedBox(
                label: .person, confidence: observation.confidence, rect: Self.sensorRect(fromUpright: observation.boundingBox)
            ))
        }
        for observation in animals.results ?? [] {
            guard let top = observation.labels.first, top.identifier == VNAnimalIdentifier.dog.rawValue,
                  top.confidence >= minConfidence else { continue }
            boxes.append(ClassifiedBox(
                label: .dog, confidence: top.confidence, rect: Self.sensorRect(fromUpright: observation.boundingBox)
            ))
        }
        return boxes
    }

    /// Vision's box (normalized, origin bottom-left, in the `.right`-rotated upright image) to the native
    /// landscape image (normalized, origin top-left). Upright top-left (x, y) is sensor (y, 1 - x).
    static func sensorRect(fromUpright box: CGRect) -> CGRect {
        CGRect(x: 1 - box.maxY, y: 1 - box.maxX, width: box.height, height: box.width)
    }
}
