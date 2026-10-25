import SwiftUI

/// Debug mode. Mirror the phone to a Mac with AirPlay so a teammate walking alongside can watch,
/// or use iOS screen recording to review a walk afterward.
struct DebugRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HUDView()
                TabView {
                    tab { CameraOverlayView(snapshot: $0, route: model.navigationProgress) }
                        .tabItem { Label("Camera", systemImage: "camera.viewfinder") }
                    tab { MapTab(snapshot: $0, tuning: model.tuningStore.tuning) }
                        .tabItem { Label("Map", systemImage: "square.grid.3x3") }
                    PlannerGraphView(history: model.history)
                        .tabItem { Label("Planner", systemImage: "waveform.path.ecg") }
                    CueLogView()
                        .tabItem { Label("Cues", systemImage: "speaker.wave.2") }
                    SetupView()
                        .tabItem { Label("Setup", systemImage: "slider.horizontal.3") }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text(model.mode.title + (model.isReplaying ? " · replay" : "")).font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isRunning ? "Stop" : "Start") { model.toggle() }
                        .tint(model.isRunning ? .red : .green)
                }
            }
        }
    }

    @ViewBuilder
    private func tab<Content: View>(@ViewBuilder _ content: (DebugSnapshot) -> Content) -> some View {
        if let snapshot = model.snapshot {
            content(snapshot)
        } else {
            NoDataView()
        }
    }
}

/// One line of vitals on every debug screen.
struct HUDView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(String(format: "%.0f fps", s?.fps ?? 0))
                Text(String(format: "%.1f ms", s?.processingMs ?? 0))
                Text(thermalText).foregroundStyle(thermalColor)
                Text(batteryText)
                if model.recordingURL != nil {
                    Label("REC", systemImage: "record.circle").foregroundStyle(.red)
                }
            }
            HStack(spacing: 12) {
                Text(floorText)
                if let message = model.trackingMessage {
                    Text(message).foregroundStyle(.orange)
                }
                if let s, s.isReplay {
                    Text(String(format: "hash %016llx", s.plannerHash))
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.06))
    }

    private var floorText: String {
        let height = model.snapshot?.cameraHeight.map { String(format: " · camera %.2f m", $0) } ?? ""
        switch model.floorStatus {
        case .calibrating(let progress): return String(format: "Calibrating %.0f%%", progress * 100) + height
        case .ready: return "Floor ready" + height
        case .cannotSeeFloor: return "Can't see floor, tilt down" + height
        }
    }

    private var thermalText: String {
        switch model.thermalState {
        case .nominal: "cool"
        case .fair: "warm"
        case .serious: "HOT (15 fps)"
        case .critical: "CRITICAL"
        @unknown default: "?"
        }
    }

    private var thermalColor: Color {
        switch model.thermalState {
        case .serious, .critical: .red
        case .fair: .yellow
        default: .primary
        }
    }

    private var batteryText: String {
        model.batteryLevel < 0 ? "battery ?" : String(format: "battery %.0f%%", model.batteryLevel * 100)
    }
}
