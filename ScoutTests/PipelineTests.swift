import simd
import XCTest
@testable import Scout

/// End to end on synthetic frames: a camera 1.3 m above a flat floor, looking level at a wall.
final class PipelineTests: XCTestCase {
    let width = 256, height = 192
    let intrinsics = simd_float3x3(columns: (
        SIMD3<Float>(100, 0, 0),
        SIMD3<Float>(0, 100, 0),
        SIMD3<Float>(128, 96, 1)
    ))
    let cameraHeight: Float = 1.3

    func frame(wallAt wall: Float, time: TimeInterval) -> FrameBundle {
        var values = [Float](repeating: .nan, count: width * height)
        for v in 0..<height {
            // Rows below the image center see the floor where their ray hits it before the wall.
            let below = (Float(v) - intrinsics[2][1]) / intrinsics[1][1]
            let floorDepth = below > 0 ? cameraHeight / below : .infinity
            for u in 0..<width {
                values[v * width + u] = min(wall, floorDepth)
            }
        }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0, cameraHeight, 0, 1)
        return FrameBundle(
            timestamp: time,
            depth: DepthImage(width: width, height: height, values: values),
            confidence: nil,
            colorJPEG: nil,
            intrinsics: intrinsics,
            cameraTransform: transform,
            trackingNormal: true
        )
    }

    func runFrames(wallAt wall: Float, seconds: Double) -> PerceptionResult {
        let pipeline = PerceptionPipeline()
        var result: PerceptionResult?
        var t = 0.0
        while t <= seconds {
            result = pipeline.process(frame(wallAt: wall, time: t), goalHeading: nil, wantDebug: true)
            t += 1.0 / 30.0
        }
        return result!
    }

    func testCalibratesFloorAndFindsWall() {
        let result = runFrames(wallAt: 3, seconds: 2.5)
        XCTAssertEqual(result.floorStatus, .ready)
        XCTAssertEqual(result.cameraHeight ?? 0, cameraHeight, accuracy: 0.05)
        XCTAssertEqual(result.planner.nearestObstacle ?? 0, 3, accuracy: 0.15)
        XCTAssertNil(result.planner.dropOffAhead)
        XCTAssertTrue(result.points.contains { $0.cls == .floor })
        XCTAssertTrue(result.points.contains { $0.cls == .obstacle })
        XCTAssertFalse(result.corridor.isEmpty)
    }

    func testCloseWallIsUrgent() {
        let result = runFrames(wallAt: 1, seconds: 0.5)
        XCTAssertEqual(result.planner.nearestObstacle ?? 0, 1, accuracy: 0.15)
        XCTAssertGreaterThan(result.planner.urgency, 0.8)
    }

    func testFrameCodecRoundTrip() throws {
        var original = frame(wallAt: 2, time: 12.5)
        original = FrameBundle(
            timestamp: original.timestamp,
            depth: original.depth,
            confidence: ConfidenceImage(width: width, height: height, values: [UInt8](repeating: 2, count: width * height)),
            colorJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            intrinsics: original.intrinsics,
            cameraTransform: original.cameraTransform,
            trackingNormal: true
        )
        let decoded = try FrameCodec.decode(FrameCodec.encode(original))
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.depth.width, width)
        XCTAssertEqual(decoded.depth.values.count, original.depth.values.count)
        XCTAssertEqual(decoded.depth.values[100 * width + 5], original.depth.values[100 * width + 5])
        XCTAssertEqual(decoded.confidence?.values.first, 2)
        XCTAssertEqual(decoded.colorJPEG, original.colorJPEG)
        XCTAssertEqual(decoded.intrinsics, original.intrinsics)
        XCTAssertEqual(decoded.cameraTransform, original.cameraTransform)
    }

    func testReplayIsDeterministic() {
        let frames = (0..<60).map { frame(wallAt: 1.5 + Float($0) * 0.02, time: Double($0) / 30) }
        func outputs() -> [PlannerOutput] {
            let pipeline = PerceptionPipeline()
            return frames.map { pipeline.process($0, goalHeading: nil, wantDebug: false).planner }
        }
        XCTAssertEqual(outputs(), outputs())
    }
}
