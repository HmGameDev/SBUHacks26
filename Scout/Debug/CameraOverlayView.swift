import SwiftUI

/// What the camera sees and what the app made of it: every sampled depth point colored by class,
/// the walking corridor on the floor, the chosen heading (yellow), and the route direction (blue).
/// `compact` is the home-screen version: no controls, just the picture and the key numbers.
struct CameraOverlayView: View {
    let snapshot: DebugSnapshot
    var route: GuidedNavigator.Progress?
    var compact = false
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
            if !compact {
                Picker("Layer", selection: $layer) {
                    ForEach(Layer.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

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
            .overlay(alignment: .top) { routeBanner }

            if !compact {
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
                    ("Low conf.", PointClass.lowConfidence.color), ("Heading", .yellow), ("Route", Theme.route),
                ])
            }
        }
        .padding(.bottom, compact ? 0 : 6)
    }

    /// Next turn, how far, and an arrow toward the route, when Guided mode is navigating.
    @ViewBuilder
    private var routeBanner: some View {
        if let route {
            HStack(spacing: 10) {
                if let bearing = route.relativeBearing {
                    Image(systemName: "location.north.fill")
                        .font(.title2)
                        .rotationEffect(.degrees(bearing))
                        .foregroundStyle(Theme.route)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(route.nextInstruction).font(.subheadline.bold()).lineLimit(2)
                    HStack(spacing: 8) {
                        if let turn = route.distanceToNextTurn {
                            Text("in \(GuidedNavigator.spokenDistance(turn))")
                        }
                        if let bearing = route.relativeBearing {
                            Text(String(format: "route %+.0f°", bearing))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .padding(8)
        }
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

        if showCorridor, snapshot.goalPath.count >= 2 {
            var path = Path()
            path.addLines(snapshot.goalPath.map { mapper.point($0) })
            context.stroke(path, with: .color(Theme.route), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
        }

        if showCorridor, snapshot.headingPath.count >= 2 {
            var path = Path()
            path.addLines(snapshot.headingPath.map { mapper.point($0) })
            context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }

        // Identification: the latest detector boxes (dashed when the depth inside missed), then confirmed names.
        for detection in snapshot.detections {
            let w = Float(mapper.depthWidth), h = Float(mapper.depthHeight)
            let r = detection.rect
            let a = mapper.point(u: Float(r.minX) * w, v: Float(r.minY) * h)
            let b = mapper.point(u: Float(r.maxX) * w, v: Float(r.maxY) * h)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let color: Color = detection.world == nil ? .gray : (detection.label.tier == .hazard ? .orange : .mint)
            let dash: [CGFloat] = detection.world == nil ? [6, 4] : []
            context.stroke(Path(rect), with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
            let caption = String(format: "%@ %.2f", detection.label.rawValue, detection.confidence)
            context.draw(
                Text(caption).font(.caption.bold()).foregroundStyle(color),
                at: CGPoint(x: rect.minX + 4, y: rect.minY - 8), anchor: .leading
            )
        }
        for mark in snapshot.labelMarks {
            let at = mapper.point(mark.pixel)
            let text = Text(mark.label.rawValue.uppercased()).font(.caption.bold()).foregroundStyle(.black)
            let size = context.resolve(text).measure(in: CGSize(width: 200, height: 40))
            let tag = CGRect(x: at.x - size.width / 2 - 6, y: at.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
            context.fill(Path(roundedRect: tag, cornerRadius: 6), with: .color(mark.isNearest ? .yellow : .white.opacity(0.85)))
            context.draw(text, at: at)
        }
    }

    private var readout: some View {
        let p = snapshot.planner
        let nearest = p.nearestObstacle.map { String(format: "%.1f m", $0) } ?? "clear"
        return VStack(spacing: 2) {
            Text(nearest)
                .font(.system(size: compact ? 30 : 44, weight: .bold, design: .rounded))
                .foregroundStyle(p.urgency > 0.6 ? Color.red : Color.white)
            Text(String(format: "heading %+.0f°   urgency %.2f", p.heading * 180 / .pi, p.urgency))
                .font(.caption.monospacedDigit())
            if let stairs = p.stairs {
                Text(String(format: "stairs %@ %.1f m (%ld steps)", stairs.direction.rawValue, stairs.distance, stairs.steps))
                    .font(.caption.bold()).foregroundStyle(.cyan)
            }
            if let drop = p.dropOffAhead {
                Text(String(format: "drop-off %.1f m", drop)).font(.caption.bold()).foregroundStyle(.purple)
            }
            if let overhead = p.overheadAhead {
                Text(String(format: "overhead %.1f m", overhead)).font(.caption.bold()).foregroundStyle(.orange)
            }
            if !compact {
                Text(p.reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
    }
}
