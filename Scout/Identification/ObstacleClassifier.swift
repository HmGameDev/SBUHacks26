import CoreGraphics

/// Seam for obstacle identification (foundation prompt section 8). Not built yet: detection ships first.
///
/// When identification starts, implement this with Vision or a Core ML detector, place each box's label
/// onto the grid cell under the depth at the box center (`GridCell.label`), and add the reserved phrases
/// in `phrases.json` to the cue vocabulary. Shepherd's `detectPerson` in `reference/shepherd/` is the
/// first candidate. Do not name anything `ObjectIdentifier`; that is a Swift standard library type.
struct ClassifiedBox: Sendable {
    let label: ObstacleLabel
    let confidence: Float
    /// Normalized to the color image, origin top-left, in the same landscape orientation as the depth map.
    let rect: CGRect
}

protocol ObstacleClassifier: AnyObject {
    /// Needs `FrameBundle.colorJPEG`; return an empty array when it is missing.
    func classify(_ frame: FrameBundle) -> [ClassifiedBox]
}

final class NullClassifier: ObstacleClassifier {
    func classify(_ frame: FrameBundle) -> [ClassifiedBox] { [] }
}
