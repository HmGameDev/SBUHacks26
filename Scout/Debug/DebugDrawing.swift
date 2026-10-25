import SwiftUI
import UIKit

extension PointClass {
    var color: Color {
        switch self {
        case .floor: .green
        case .obstacle: .red
        case .overhead: .orange
        case .dropOff: .purple
        case .lowConfidence: .gray
        case .ignored: .clear
        }
    }

    var title: String {
        switch self {
        case .floor: "Floor"
        case .obstacle: "Obstacle"
        case .overhead: "Overhead"
        case .dropOff: "Drop-off"
        case .lowConfidence: "Low confidence"
        case .ignored: "Ignored"
        }
    }
}

extension CellState {
    var color: Color {
        switch self {
        case .unknown: Color(white: 0.12)
        case .free: Color.green.opacity(0.35)
        case .obstacle: .red
        case .dropOff: .purple
        case .overhead: .orange
        }
    }
}

/// Maps native landscape depth-image pixels onto a portrait view. The depth map, the color frame, and
/// ARKit's intrinsics all share the sensor's landscape orientation; in portrait the image is shown
/// rotated 90 degrees clockwise (`UIImage.Orientation.right`), so pixel (u, v) lands at (H - v, u).
struct PortraitMapper {
    let depthWidth: CGFloat
    let depthHeight: CGFloat
    let rect: CGRect

    init(depthWidth: Int, depthHeight: Int, in size: CGSize) {
        self.depthWidth = CGFloat(max(1, depthWidth))
        self.depthHeight = CGFloat(max(1, depthHeight))
        // Portrait: the displayed width is the image height and vice versa.
        let scale = min(size.width / self.depthHeight, size.height / self.depthWidth)
        let width = self.depthHeight * scale
        let height = self.depthWidth * scale
        rect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    func point(u: Float, v: Float) -> CGPoint {
        let xn = 1 - CGFloat(v) / depthHeight
        let yn = CGFloat(u) / depthWidth
        return CGPoint(x: rect.minX + xn * rect.width, y: rect.minY + yn * rect.height)
    }

    func point(_ p: SIMD2<Float>) -> CGPoint {
        point(u: p.x, v: p.y)
    }
}

enum DebugDrawing {
    /// The color JPEG, rotated for portrait display.
    static func portraitImage(_ jpeg: Data) -> UIImage? {
        guard let image = UIImage(data: jpeg), let cg = image.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .right)
    }

    /// Heat map from Shepherd's DepthVisualizer: red is close, blue is far, gray is invalid.
    static func depthImage(_ depth: DepthImage, minDepth: Float = 0.2, maxDepth: Float = 4.0) -> UIImage? {
        let width = depth.width, height = depth.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let (r, g, b) = color(for: depth.values[i], minDepth: minDepth, maxDepth: maxDepth)
            pixels[i * 4] = r
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = b
        }
        let cgImage: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let cgImage else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }

    private static func color(for depth: Float, minDepth: Float, maxDepth: Float) -> (UInt8, UInt8, UInt8) {
        guard depth.isFinite, depth > 0 else { return (128, 128, 128) }
        let value = 1 - max(0, min(1, (depth - minDepth) / (maxDepth - minDepth)))
        func byte(_ x: Float) -> UInt8 { UInt8(max(0, min(255, x * 255))) }
        switch value {
        case ..<0.25: return (0, byte(value / 0.25), 255)
        case ..<0.5: return (0, 255, byte(1 - (value - 0.25) / 0.25))
        case ..<0.75: return (byte((value - 0.5) / 0.25), 255, 0)
        default: return (255, byte(1 - (value - 0.75) / 0.25), 0)
        }
    }
}

struct LegendRow: View {
    let items: [(String, Color)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Circle().fill(items[i].1).frame(width: 8, height: 8)
                    Text(items[i].0)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct NoDataView: View {
    var body: some View {
        ContentUnavailableView(
            "No frames yet",
            systemImage: "camera.metering.unknown",
            description: Text("Start guidance or replay a recording to see what the camera sees.")
        )
    }
}
