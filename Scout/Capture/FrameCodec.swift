import Foundation
import simd

/// Compact binary format for recorded frames (one `.wfr` file per frame).
///
/// Layout, little-endian: magic "WFR1", timestamp (Float64), depth width and height (Int32),
/// intrinsics (9 x Float32, column-major), camera transform (16 x Float32, column-major),
/// tracking flag (UInt8), confidence flag (UInt8), depth (w*h Float32), confidence (w*h UInt8, if flagged),
/// JPEG length (Int32), JPEG bytes.
enum FrameCodec {
    static let fileExtension = "wfr"
    private static let magic: UInt32 = 0x3152_4657 // "WFR1"

    enum CodecError: Error {
        case badMagic
        case truncated
    }

    static func encode(_ frame: FrameBundle) -> Data {
        var data = Data()
        data.reserveCapacity(frame.depth.values.count * 5 + (frame.colorJPEG?.count ?? 0) + 128)
        append(&data, magic)
        append(&data, frame.timestamp)
        append(&data, Int32(frame.depth.width))
        append(&data, Int32(frame.depth.height))
        for column in 0..<3 {
            for row in 0..<3 { append(&data, frame.intrinsics[column][row]) }
        }
        for column in 0..<4 {
            for row in 0..<4 { append(&data, frame.cameraTransform[column][row]) }
        }
        append(&data, UInt8(frame.trackingNormal ? 1 : 0))
        append(&data, UInt8(frame.confidence == nil ? 0 : 1))
        frame.depth.values.withUnsafeBytes { data.append(contentsOf: $0) }
        if let confidence = frame.confidence {
            data.append(contentsOf: confidence.values)
        }
        let jpeg = frame.colorJPEG ?? Data()
        append(&data, Int32(jpeg.count))
        data.append(jpeg)
        return data
    }

    static func decode(_ data: Data) throws -> FrameBundle {
        var reader = Reader(data: data)
        guard try reader.read(UInt32.self) == magic else { throw CodecError.badMagic }
        let timestamp = try reader.read(Double.self)
        let width = Int(try reader.read(Int32.self))
        let height = Int(try reader.read(Int32.self))

        var intrinsics = simd_float3x3()
        for column in 0..<3 {
            for row in 0..<3 { intrinsics[column][row] = try reader.read(Float.self) }
        }
        var transform = simd_float4x4()
        for column in 0..<4 {
            for row in 0..<4 { transform[column][row] = try reader.read(Float.self) }
        }

        let trackingNormal = try reader.read(UInt8.self) == 1
        let hasConfidence = try reader.read(UInt8.self) == 1
        let depthValues = try reader.readArray(Float.self, count: width * height)
        var confidence: ConfidenceImage?
        if hasConfidence {
            let values = try reader.readArray(UInt8.self, count: width * height)
            confidence = ConfidenceImage(width: width, height: height, values: values)
        }
        let jpegLength = Int(try reader.read(Int32.self))
        let jpeg: Data? = try jpegLength > 0 ? reader.readData(count: jpegLength) : nil

        return FrameBundle(
            timestamp: timestamp,
            depth: DepthImage(width: width, height: height, values: depthValues),
            confidence: confidence,
            colorJPEG: jpeg,
            intrinsics: intrinsics,
            cameraTransform: transform,
            trackingNormal: trackingNormal
        )
    }

    private static func append<T>(_ data: inout Data, _ value: T) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func read<T>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw CodecError.truncated }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return value
        }

        mutating func readArray<T>(_ type: T.Type, count: Int) throws -> [T] {
            let byteCount = count * MemoryLayout<T>.stride
            guard count >= 0, offset + byteCount <= data.count else { throw CodecError.truncated }
            let start = offset
            let array = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    if let src = raw.baseAddress, let dst = buffer.baseAddress, byteCount > 0 {
                        memcpy(dst, src + start, byteCount)
                    }
                }
                initialized = count
            }
            offset += byteCount
            return array
        }

        mutating func readData(count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw CodecError.truncated }
            let start = data.startIndex + offset
            offset += count
            return data.subdata(in: start..<(start + count))
        }
    }
}
