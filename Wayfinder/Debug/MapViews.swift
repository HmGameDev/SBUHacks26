import SwiftUI

/// Top-down occupancy grid with the 16 candidate headings and the chosen one.
struct GridMapView: View {
    let snapshot: DebugSnapshot

    var body: some View {
        Canvas { context, size in
            let grid = snapshot.grid
            let widthMeters = CGFloat(2 * grid.halfWidth)
            let depthMeters = CGFloat(grid.forwardRange)
            let scale = min(size.width / widthMeters, (size.height - 8) / depthMeters)
            let originX = size.width / 2
            let originY = size.height - 4
            let cell = CGFloat(grid.cellSize) * scale

            func screen(forward: Float, lateral: Float) -> CGPoint {
                CGPoint(x: originX + CGFloat(lateral) * scale, y: originY - CGFloat(forward) * scale)
            }

            for row in 0..<grid.rows {
                for col in 0..<grid.cols {
                    let c = grid.cells[grid.index(col: col, row: row)]
                    let x = originX + (CGFloat(col) * CGFloat(grid.cellSize) - CGFloat(grid.halfWidth)) * scale
                    let y = originY - CGFloat(row + 1) * cell
                    let rect = CGRect(x: x, y: y, width: cell - 0.5, height: cell - 0.5)
                    let color = c.inferred ? Color.purple.opacity(0.5) : c.state.color
                    context.fill(Path(rect), with: .color(color))
                }
            }

            // Meter rings.
            for meters in 1...Int(grid.forwardRange) {
                let y = originY - CGFloat(meters) * scale
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
                context.draw(Text("\(meters) m").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 4, y: y - 6), anchor: .leading)
            }

            // Candidate headings: brighter means a better score.
            let scores = snapshot.candidates.map(\.score)
            let low = scores.min() ?? 0, high = scores.max() ?? 1
            for candidate in snapshot.candidates {
                let t = high > low ? (candidate.score - low) / (high - low) : 1
                var ray = Path()
                ray.move(to: CGPoint(x: originX, y: originY))
                ray.addLine(to: screen(forward: candidate.freeDistance * cosf(candidate.angle), lateral: candidate.freeDistance * sinf(candidate.angle)))
                context.stroke(ray, with: .color(.cyan.opacity(0.15 + 0.6 * Double(t))), lineWidth: 1.5)
            }

            // Chosen heading.
            let p = snapshot.planner
            let length = p.straightFree ?? 2
            var arrow = Path()
            arrow.move(to: CGPoint(x: originX, y: originY))
            arrow.addLine(to: screen(forward: length * cosf(p.heading), lateral: length * sinf(p.heading)))
            context.stroke(arrow, with: .color(.yellow), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .background(Color.black)
    }
}

/// Side view: forward distance against height above the floor, with the class thresholds.
/// The best view for tuning drop-offs and overhead obstacles.
struct SideMapView: View {
    let snapshot: DebugSnapshot
    let tuning: Tuning

    var body: some View {
        Canvas { context, size in
            let minHeight: Float = -0.6, maxHeight: Float = 2.4
            let xScale = size.width / CGFloat(tuning.maxRange)
            let yScale = size.height / CGFloat(maxHeight - minHeight)
            func screen(_ forward: Float, _ height: Float) -> CGPoint {
                CGPoint(x: CGFloat(forward) * xScale, y: size.height - CGFloat(height - minHeight) * yScale)
            }

            let lines: [(Float, String, Color)] = [
                (tuning.dropThreshold, "drop", .purple),
                (0, "floor", .green),
                (tuning.floorBand, "", .green.opacity(0.5)),
                (tuning.overheadStart, "overhead", .orange),
                (tuning.obstacleTop, "top", .red),
            ]
            for (height, label, color) in lines {
                var line = Path()
                line.move(to: screen(0, height))
                line.addLine(to: screen(tuning.maxRange, height))
                context.stroke(line, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                if !label.isEmpty {
                    context.draw(Text(label).font(.caption2).foregroundStyle(color), at: screen(tuning.maxRange - 0.05, height + 0.06), anchor: .trailing)
                }
            }

            let half = tuning.corridorWidth / 2
            var inCorridor: [PointClass: Path] = [:]
            var outside = Path()
            for point in snapshot.points where point.cls != .lowConfidence && point.cls != .ignored {
                guard point.height >= minHeight, point.height <= maxHeight, point.forward >= 0 else { continue }
                let c = screen(point.forward, point.height)
                let rect = CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2)
                if abs(point.lateral) <= half {
                    inCorridor[point.cls, default: Path()].addRect(rect)
                } else {
                    outside.addRect(rect)
                }
            }
            context.fill(outside, with: .color(.white.opacity(0.12)))
            for (cls, path) in inCorridor {
                context.fill(path, with: .color(cls.color))
            }

            if let cameraHeight = snapshot.cameraHeight {
                let c = screen(0, cameraHeight)
                context.fill(Path(ellipseIn: CGRect(x: c.x, y: c.y - 5, width: 10, height: 10)), with: .color(.yellow))
                context.draw(Text(String(format: "camera %.2f m", cameraHeight)).font(.caption2).foregroundStyle(.yellow), at: CGPoint(x: c.x + 14, y: c.y), anchor: .leading)
            }
        }
        .background(Color.black)
    }
}

struct MapTab: View {
    let snapshot: DebugSnapshot
    let tuning: Tuning

    var body: some View {
        VStack(spacing: 4) {
            Text("Top-down grid").font(.caption.bold())
            GridMapView(snapshot: snapshot)
            Text("Side view (points inside the walking corridor are colored)").font(.caption.bold())
            SideMapView(snapshot: snapshot, tuning: tuning)
                .frame(height: 180)
            LegendRow(items: [
                ("Free", CellState.free.color), ("Obstacle", CellState.obstacle.color),
                ("Overhead", CellState.overhead.color), ("Drop", CellState.dropOff.color),
                ("Unknown", Color.gray),
            ])
        }
        .padding(.horizontal, 4)
    }
}
