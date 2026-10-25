import CoreGraphics
import CoreML
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

/// Everything on the phone, no network: Apple's built-in people and dog detectors, plus the bundled
/// `ObstacleDetector` (YOLOv8n, Open Images V7, 600 classes) for doors, furniture, vehicles, and street objects.
/// The phone is portrait on the chest, so the landscape sensor image is upright when rotated to `.right`,
/// the same assumption `PortraitMapper` makes for the debug view.
final class VisionClassifier: ObstacleClassifier {
    /// For Apple's detectors.
    var minConfidence: Float = 0.5
    /// For the bundled detector, whose scores run lower.
    var objectMinConfidence: Float = 0.35

    private let humans: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        // Whole bodies: close up, a chest camera often sees torso and legs but not the head.
        request.upperBodyOnly = false
        return request
    }()
    private let animals = VNRecognizeAnimalsRequest()
    /// Nil if the model is missing from the bundle; people and dogs still work.
    private let objects: VNCoreMLRequest? = {
        guard let url = Bundle.main.url(forResource: "ObstacleDetector", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url, configuration: MLModelConfiguration()),
              let vision = try? VNCoreMLModel(for: model) else { return nil }
        // The exported model takes its thresholds as inputs. Keep them loose; `objectMinConfidence` and the
        // tracker's vote do the filtering.
        vision.featureProvider = try? MLDictionaryFeatureProvider(dictionary: ["iouThreshold": 0.5, "confidenceThreshold": 0.2])
        let request = VNCoreMLRequest(model: vision)
        // Stretch the whole frame onto the square input, so boxes cover the full image and map back directly.
        request.imageCropAndScaleOption = .scaleFill
        return request
    }()

    func classify(_ image: CGImage) -> [ClassifiedBox] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .right, options: [:])
        var requests: [VNRequest] = [humans, animals]
        if let objects { requests.append(objects) }
        do {
            try handler.perform(requests)
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
        for case let observation as VNRecognizedObjectObservation in objects?.results ?? [] {
            guard let top = observation.labels.first, top.confidence >= objectMinConfidence,
                  let label = ObstacleLabel.openImages[top.identifier] else { continue }
            boxes.append(ClassifiedBox(
                label: label, confidence: top.confidence, rect: Self.sensorRect(fromUpright: observation.boundingBox)
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
