import SwiftUI

/// The last ten seconds of planner output: heading raw vs smoothed, urgency, and nearest obstacle.
/// Left-right flipping shows up here immediately.
struct PlannerGraphView: View {
    let history: [PlannerSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panel("Heading (degrees, ±40). Gray is raw, yellow is smoothed.", range: -40...40) { sample in
                [(Double(sample.rawHeading * 180 / .pi), Color.gray), (Double(sample.heading * 180 / .pi), Color.yellow)]
            }
            panel("Urgency (0 to 1)", range: 0...1) { sample in
                [(Double(sample.urgency), Color.red)]
            }
            panel("Nearest obstacle ahead (m)", range: 0...4) { sample in
                sample.nearest.map { [(Double($0), Color.cyan)] } ?? []
            }
        }
        .padding()
    }

    private func panel(_ title: String, range: ClosedRange<Double>, values: @escaping (PlannerSample) -> [(Double, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold())
            Canvas { context, size in
                guard let last = history.last?.time else { return }
                let window = 10.0
                func x(_ time: TimeInterval) -> CGFloat { size.width * CGFloat(1 - (last - time) / window) }
                func y(_ value: Double) -> CGFloat {
                    let clamped = min(range.upperBound, max(range.lowerBound, value))
                    return size.height * CGFloat(1 - (clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
                }
                if range.contains(0) {
                    var zero = Path()
                    zero.move(to: CGPoint(x: 0, y: y(0)))
                    zero.addLine(to: CGPoint(x: size.width, y: y(0)))
                    context.stroke(zero, with: .color(.white.opacity(0.2)), lineWidth: 0.5)
                }
                var paths: [Int: (Path, Color, Bool)] = [:]
                for sample in history where last - sample.time <= window {
                    for (index, (value, color)) in values(sample).enumerated() {
                        let point = CGPoint(x: x(sample.time), y: y(value))
                        if var entry = paths[index] {
                            entry.0.addLine(to: point)
                            paths[index] = entry
                        } else {
                            var path = Path()
                            path.move(to: point)
                            paths[index] = (path, color, true)
                        }
                    }
                }
                for (_, entry) in paths.sorted(by: { $0.key < $1.key }) {
                    context.stroke(entry.0, with: .color(entry.1), lineWidth: 1.5)
                }
            }
            .frame(height: 110)
            .background(Color.white.opacity(0.05))
        }
    }
}
