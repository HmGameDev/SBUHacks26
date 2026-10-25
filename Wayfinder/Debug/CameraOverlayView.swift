import SwiftUI

/// What the camera sees and what the app made of it: every sampled depth point colored by class,
/// the walking corridor on the floor, and the chosen heading.
struct CameraOverlayView: View {
    let snapshot: DebugSnapshot
    @State private var layer = Layer.camera
    @State private var showPoints = true
    @State private var showFloor = false
    @State private var showCorridor = true

    enum Layer: String, CaseIterable, Identifiable {
        case camera = "Camera"
        case depth = "Depth"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 6) {
            Picker("Layer", selection: $layer) {
                ForEach(Layer.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            GeometryReader { geo in
                let mapper = PortraitMapper(depthWidth: snapshot.depth.width, depthHeight: snapshot.depth.height, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    backgroundLayer(mapper: mapper, size: geo.size)
                    Canvas { context, _ in
                        draw(in: &context, mapper: mapper)
                    }
                }
            }
            .overlay(alignment: .bottom) { readout }

            HStack {
                Toggle("Points", isOn: $showPoints)
                Toggle("Floor", isOn: $showFloor)
                Toggle("Path", isOn: $showCorridor)
            }
            .toggleStyle(.button)
            .font(.caption)

            LegendRow(items: [
                ("Floor", PointClass.floor.color), ("Obstacle", PointClass.obstacle.color),
                ("Overhead", PointClass.overhead.color), ("Drop", PointClass.dropOff.color),
                ("Low conf.", PointClass.lowConfidence.color), ("Heading", .yellow),
            ])
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func backgroundLayer(mapper: PortraitMapper, size: CGSize) -> some View {
        let image: UIImage? = layer == .camera
            ? snapshot.colorJPEG.flatMap(DebugDrawing.portraitImage)
            : DebugDrawing.depthImage(snapshot.depth)
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(layer == .depth ? .none : .medium)
                .frame(width: mapper.rect.width, height: mapper.rect.height)
                .position(x: mapper.rect.midX, y: mapper.rect.midY)
        } else {
            Text(layer == .camera ? "No color frame yet" : "No depth")
                .foregroundStyle(.secondary)
                .position(x: size.width / 2, y: size.height / 2)
        }
    }

    private func draw(in context: inout GraphicsContext, mapper: PortraitMapper) {
        if showCorridor, snapshot.corridor.count >= 3 {
            var path = Path()
            path.addLines(snapshot.corridor.map { mapper.point($0) })
            path.closeSubpath()
            context.fill(path, with: .color(.cyan.opacity(0.15)))
            context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 1)
        }

        if showPoints {
            // One path per class keeps thousands of dots cheap to draw.
            var paths: [PointClass: Path] = [:]
            for point in snapshot.points {
                if point.cls == .ignored || (point.cls == .floor && !showFloor) { continue }
                let c = mapper.point(u: point.u, v: point.v)
                paths[point.cls, default: Path()].addRect(CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            }
            for (cls, path) in paths {
                context.fill(path, with: .color(cls.color.opacity(0.85)))
            }
        }

        if showCorridor, snapshot.headingPath.count >= 2 {
            var path = Path()
            path.addLines(snapshot.headingPath.map { mapper.point($0) })
            context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }

        // Reserved for identification: boxes from the classifier (always empty for now).
        for box in snapshot.classifiedBoxes {
            let w = Float(mapper.depthWidth), h = Float(mapper.depthHeight)
            let a = mapper.point(u: Float(box.rect.minX) * w, v: Float(box.rect.minY) * h)
            let b = mapper.point(u: Float(box.rect.maxX) * w, v: Float(box.rect.maxY) * h)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            context.stroke(Path(rect), with: .color(.white), lineWidth: 2)
            context.draw(Text(box.label.rawValue).font(.caption).foregroundStyle(.white), at: CGPoint(x: rect.minX + 4, y: rect.minY - 8), anchor: .leading)
        }
    }

    private var readout: some View {
        let p = snapshot.planner
        let nearest = p.nearestObstacle.map { String(format: "%.1f m", $0) } ?? "clear"
        return VStack(spacing: 2) {
            Text(nearest)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(p.urgency > 0.6 ? Color.red : Color.white)
            Text(String(format: "heading %+.0f°   urgency %.2f", p.heading * 180 / .pi, p.urgency))
                .font(.caption.monospacedDigit())
            if let drop = p.dropOffAhead {
                Text(String(format: "drop-off %.1f m", drop)).font(.caption.bold()).foregroundStyle(.purple)
            }
            if let overhead = p.overheadAhead {
                Text(String(format: "overhead %.1f m", overhead)).font(.caption.bold()).foregroundStyle(.orange)
            }
            Text(p.reason).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
    }
}
