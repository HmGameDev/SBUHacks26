import Foundation
import simd

/// Depth in meters, row-major, in the sensor's native landscape orientation.
struct DepthImage: Sendable {
    let width: Int
    let height: Int
    var values: [Float]

    @inline(__always)
    func value(_ u: Int, _ v: Int) -> Float { values[v * width + u] }
}

/// ARConfidenceLevel per pixel: 0 low, 1 medium, 2 high. Same layout as `DepthImage`.
struct ConfidenceImage: Sendable {
    let width: Int
    let height: Int
    var values: [UInt8]

    @inline(__always)
    func value(_ u: Int, _ v: Int) -> UInt8 { values[v * width + u] }
}

/// Everything downstream needs from one camera frame. Live and replayed frames are identical in shape,
/// so nothing after the source knows which one it is getting.
struct FrameBundle: Sendable {
    /// Seconds, on the same clock as `ProcessInfo.systemUptime` for live frames.
    let timestamp: TimeInterval
    let depth: DepthImage
    let confidence: ConfidenceImage?
    /// Downscaled JPEG of the color frame, same orientation as `depth`. Only present when a debug view,
    /// the recorder, or a classifier asked for it.
    let colorJPEG: Data?
    /// Camera intrinsics already scaled to the depth image resolution.
    let intrinsics: simd_float3x3
    /// World-from-camera transform. ARKit convention: the camera looks down its -Z axis.
    let cameraTransform: simd_float4x4
    let trackingNormal: Bool
}
