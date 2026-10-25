import SwiftUI

/// Recording, replay, and every tuning value.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var store = model.tuningStore
        Form {
            Section("Record and replay") {
                Button(model.recordingURL == nil ? "Start recording" : "Stop recording") {
                    model.toggleRecording()
                }
                .disabled(model.runState != .live)
                if let frames = model.snapshot?.recordingFrames {
                    Text("Recording: \(frames) frames")
                }
                Toggle("Mute cues during replay", isOn: $model.muteReplay)
                if let summary = model.lastReplaySummary {
                    Text(summary).font(.caption.monospaced())
                }
                ForEach(model.recordings) { recording in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(recording.name).font(.caption)
                            Text("\(recording.frameCount) frames, \(ByteCountFormatter.string(fromByteCount: recording.sizeBytes, countStyle: .file))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Replay") { model.startReplay(recording) }
                            .buttonStyle(.bordered)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.deleteRecording(recording) }
                    }
                }
                Text("Recordings are in the app's Documents folder; copy them off with Finder or the Files app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Capture") {
                DoubleSlider(title: "Target fps", value: $store.tuning.targetFPS, range: 10...60, step: 5)
                IntStepper(title: "Sample every Nth pixel", value: $store.tuning.sampleStride, range: 1...8)
                Toggle("Smoothed depth (less noise, more lag)", isOn: $store.tuning.useSmoothedDepth)
                FloatSlider(title: "Medium-confidence max range", value: $store.tuning.mediumConfidenceMaxRange, range: 0.5...5)
                FloatSlider(title: "Max range", value: $store.tuning.maxRange, range: 2...5)
            }
            Section("Floor and height bands (m above floor)") {
                FloatSlider(title: "Default camera height", value: $store.tuning.defaultCameraHeight, range: 0.8...1.8)
                DoubleSlider(title: "Floor follow time (s)", value: $store.tuning.floorTimeConstant, range: 0.2...10, step: 0.1)
                FloatSlider(title: "Step threshold", value: $store.tuning.stepThreshold, range: 0.05...0.4)
                FloatSlider(title: "Drop-off below", value: $store.tuning.dropThreshold, range: -0.5...(-0.03))
                FloatSlider(title: "Floor band top", value: $store.tuning.floorBand, range: 0.02...0.3)
                FloatSlider(title: "Overhead starts", value: $store.tuning.overheadStart, range: 0.8...1.8)
                FloatSlider(title: "Ignore above", value: $store.tuning.obstacleTop, range: 1.5...3)
            }
            Section("Grid") {
                IntStepper(title: "Points to mark a cell", value: $store.tuning.minPointsPerCell, range: 1...20)
                IntStepper(title: "Frames to confirm (of 3)", value: $store.tuning.persistenceFrames, range: 1...3)
                Toggle("Infer drop-offs from missing floor", isOn: $store.tuning.inferDropFromMissingFloor)
                FloatSlider(title: "Inferred drop max distance", value: $store.tuning.inferredDropMaxDistance, range: 0.5...3)
                IntStepper(title: "Inferred drop rows", value: $store.tuning.inferredDropRows, range: 1...10)
            }
            Section("Planner") {
                FloatSlider(title: "Corridor width", value: $store.tuning.corridorWidth, range: 0.3...1.5)
                FloatSlider(title: "Heading span (deg)", value: $store.tuning.headingSpanDegrees, range: 10...80, step: 5)
                FloatSlider(title: "Unseen run limit", value: $store.tuning.unknownRunLimit, range: 0.1...2)
                FloatSlider(title: "Clear distance", value: $store.tuning.clearDistance, range: 1...4)
                FloatSlider(title: "Stop distance", value: $store.tuning.stopDistance, range: 0.2...1.5)
                FloatSlider(title: "Urgency exponent", value: $store.tuning.urgencyExponent, range: 0.2...2)
                FloatSlider(title: "Turn penalty", value: $store.tuning.turnPenalty, range: 0...3)
                FloatSlider(title: "Switch penalty", value: $store.tuning.switchPenalty, range: 0...3)
                FloatSlider(title: "Goal weight", value: $store.tuning.goalWeight, range: 0...3)
                FloatSlider(title: "Heading smoothing", value: $store.tuning.headingSmoothing, range: 0.01...1)
                DoubleSlider(title: "Hysteresis (s)", value: $store.tuning.hysteresisSeconds, range: 0...1.5, step: 0.05)
                FloatSlider(title: "Straight deadband (deg)", value: $store.tuning.straightDeadbandDegrees, range: 0...20, step: 1)
            }
            Section("Cues") {
                FloatSlider(title: "Steer within", value: $store.tuning.steerTriggerDistance, range: 0.5...4)
                FloatSlider(title: "Slight turn below (deg)", value: $store.tuning.slightTurnDegrees, range: 5...40, step: 1)
                FloatSlider(title: "Stop at urgency", value: $store.tuning.stopUrgency, range: 0.5...1)
                FloatSlider(title: "Drop-off alert within", value: $store.tuning.dropAlertDistance, range: 0.5...3)
                FloatSlider(title: "Overhead alert within", value: $store.tuning.overheadAlertDistance, range: 0.5...3)
                DoubleSlider(title: "Repeat after (s)", value: $store.tuning.repeatInterval, range: 0.5...10, step: 0.5)
                DoubleSlider(title: "Queued cue expiry (s)", value: $store.tuning.queueExpiry, range: 0.5...5, step: 0.5)
                DoubleSlider(title: "Clear after (s)", value: $store.tuning.clearHoldSeconds, range: 0.2...5, step: 0.1)
                DoubleSlider(title: "Slowest pulse (s)", value: $store.tuning.pulseMaxInterval, range: 0.3...2, step: 0.05)
                DoubleSlider(title: "Fastest pulse (s)", value: $store.tuning.pulseMinInterval, range: 0.05...0.5, step: 0.01)
            }
            Section {
                Button("Reset all tuning", role: .destructive) { store.reset() }
                ShareLink("Export tuning JSON", item: store.exportJSON())
            }
        }
    }
}

struct FloatSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float = 0.05

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value)).monospacedDigit()
            }
            .font(.caption)
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct DoubleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value)).monospacedDigit()
            }
            .font(.caption)
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct IntStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper("\(title): \(value)", value: $value, in: range)
            .font(.caption)
    }
}
