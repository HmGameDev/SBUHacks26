import simd
import XCTest
@testable import Scout

final class GeometryTests: XCTestCase {
    let intrinsics = simd_float3x3(columns: (
        SIMD3<Float>(200, 0, 0),
        SIMD3<Float>(0, 200, 0),
        SIMD3<Float>(128, 96, 1)
    ))

    func testUnprojectThenProjectRoundTrips() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0.5, 1.3, -2, 1)
        for (u, v, depth) in [(10, 20, 1.0), (128, 96, 2.5), (250, 180, 3.7)] as [(Float, Float, Float)] {
            let world = Geometry.transform(Geometry.unproject(u: u, v: v, depth: depth, intrinsics: intrinsics), by: transform)
            let pixel = Geometry.project(world: world, worldToCamera: transform.inverse, intrinsics: intrinsics)
            XCTAssertNotNil(pixel)
            XCTAssertEqual(pixel!.x, u, accuracy: 0.01)
            XCTAssertEqual(pixel!.y, v, accuracy: 0.01)
        }
    }

    func testImageAxes() {
        // Principal point looks straight ahead; image up (smaller v) is camera up (+y); image right is +x.
        let center = Geometry.unproject(u: 128, v: 96, depth: 2, intrinsics: intrinsics)
        XCTAssertEqual(center, SIMD3<Float>(0, 0, -2))
        let up = Geometry.unproject(u: 128, v: 0, depth: 2, intrinsics: intrinsics)
        XCTAssertGreaterThan(up.y, 0)
        let right = Geometry.unproject(u: 255, v: 96, depth: 2, intrinsics: intrinsics)
        XCTAssertGreaterThan(right.x, 0)
    }

    func testBodyFrameLooksForwardAndRight() {
        let body = BodyFrame(cameraTransform: matrix_identity_float4x4)!
        XCTAssertEqual(body.forward, SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(body.right, SIMD3<Float>(1, 0, 0))
        let local = body.local(SIMD3<Float>(0.5, 0, -2))
        XCTAssertEqual(local.forward, 2, accuracy: 1e-5)
        XCTAssertEqual(local.lateral, 0.5, accuracy: 1e-5)
        XCTAssertEqual(body.yaw, 0, accuracy: 1e-5)
    }

    func testYawIncreasesClockwise() {
        // Turn right by 90 degrees: camera now looks down +X.
        let turned = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        let body = BodyFrame(cameraTransform: turned)!
        XCTAssertEqual(body.forward.x, 1, accuracy: 1e-5)
        XCTAssertEqual(body.yaw, .pi / 2, accuracy: 1e-4)
    }

    func testBodyFrameUndefinedWhenLookingDown() {
        let down = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0)))
        XCTAssertNil(BodyFrame(cameraTransform: down))
    }
}
