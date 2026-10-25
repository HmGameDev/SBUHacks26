import simd

/// Pinhole camera math in ARKit's conventions: image u to the right, v down; camera x right, y up,
/// looking down -Z. Intrinsics are column-major, so cx = k[2][0] and cy = k[2][1].
enum Geometry {
    static func unproject(u: Float, v: Float, depth: Float, intrinsics k: simd_float3x3) -> SIMD3<Float> {
        let fx = k[0][0], fy = k[1][1], cx = k[2][0], cy = k[2][1]
        return SIMD3((u - cx) / fx * depth, -(v - cy) / fy * depth, -depth)
    }

    static func transform(_ point: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let p = matrix * SIMD4<Float>(point, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// World point to depth-image pixel coordinates, or nil when it is behind the camera.
    static func project(world: SIMD3<Float>, worldToCamera: simd_float4x4, intrinsics k: simd_float3x3) -> SIMD2<Float>? {
        let c = worldToCamera * SIMD4<Float>(world, 1)
        guard c.z < -0.05 else { return nil }
        let depth = -c.z
        return SIMD2(c.x / depth * k[0][0] + k[2][0], k[2][1] - c.y / depth * k[1][1])
    }
}

/// Horizontal frame that moves with the wearer: `forward` is the camera's viewing direction flattened
/// onto the floor plane, `right` is perpendicular to it. On a chest mount this is the walking direction.
struct BodyFrame: Sendable {
    let origin: SIMD3<Float>
    let forward: SIMD3<Float>
    let right: SIMD3<Float>

    /// Nil when the camera points nearly straight up or down, so "forward" is undefined.
    init?(cameraTransform t: simd_float4x4) {
        let look = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let length = simd_length(SIMD2<Float>(look.x, look.z))
        guard length > 0.3 else { return nil }
        forward = SIMD3(look.x / length, 0, look.z / length)
        right = SIMD3(-forward.z, 0, forward.x)
        origin = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    func local(_ point: SIMD3<Float>) -> (forward: Float, lateral: Float) {
        let d = point - origin
        return (simd_dot(d, forward), simd_dot(d, right))
    }

    func world(forward f: Float, lateral l: Float, y: Float) -> SIMD3<Float> {
        let p = origin + f * forward + l * right
        return SIMD3(p.x, y, p.z)
    }

    /// Walking direction in world space, radians clockwise from -Z seen from above.
    /// With `.gravityAndHeading` alignment, -Z is true north, so this is a compass heading.
    var yaw: Float { atan2(forward.x, -forward.z) }
}
