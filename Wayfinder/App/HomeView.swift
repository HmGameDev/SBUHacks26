import SwiftUI

/// The everyday screen: start and stop, choose how to walk, say where to go, and optionally watch
/// what the camera sees. Built for VoiceOver and large text first.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showDebug = false
    @State private var showSettings = false
    @State private var showHelp = false
    @FocusState private var destinationFocused: Bool

    var body: some View {
        @Bindable var model = model
        @Bindable var prefs = model.preferencesStore
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if prefs.preferences.showCamera {
                        cameraCard
                    }
                    startButton(height: prefs.preferences.showCamera ? 120 : 200)

                    VStack(spacing: 10) {
                        CardButton(
                            icon: "figure.walk",
                            title: "Just walk",
                            detail: "Warns about obstacles, steps, and stairs",
                            selected: model.mode == .passive
                        ) { model.setMode(.passive) }
                        CardButton(
                            icon: "map",
                            title: "Go somewhere",
                            detail: "Walking directions, plus obstacle warnings",
                            selected: model.mode == .guided
                        ) { model.setMode(.guided) }
                    }

                    if model.mode == .guided {
                        destinationCard
                    }

                    Toggle(isOn: $prefs.preferences.showCamera) {
                        Label("Show camera view", systemImage: "camera.viewfinder").font(.title3)
                    }
                    .tint(Theme.accent)
                    .padding(16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHint("Shows what the camera sees and what the app detects. Uses more battery.")

                    Button {
                        model.debugVisible = true
                        showDebug = true
                    } label: {
                        Label("Developer tools", systemImage: "wrench.and.screwdriver")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle("Wayfinder")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHelp = true } label: {
                        Image(systemName: "questionmark.circle").font(.title2)
                    }
                    .accessibilityLabel("Help: what the sounds mean")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").font(.title2)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .tint(Theme.accent)
        .onAppear { model.cameraPreviewVisible = prefs.preferences.showCamera }
        .onChange(of: prefs.preferences.showCamera) { _, show in model.cameraPreviewVisible = show }
        .sheet(isPresented: $showSettings) { SettingsView().environment(model) }
        .sheet(isPresented: $showHelp) { HelpView().environment(model) }
        .fullScreenCover(isPresented: $showDebug, onDismiss: { model.debugVisible = false }) {
            DebugRootView().environment(model)
        }
    }

    // MARK: - Pieces

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title)
                .foregroundStyle(model.isRunning ? Theme.go : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isRunning ? "Guiding" : "Ready when you are").font(.headline)
                Text(model.statusMessage).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private var statusIcon: String {
        if !model.isRunning { return "checkmark.seal" }
        switch model.floorStatus {
        case .calibrating: return "hourglass"
        case .cannotSeeFloor: return "exclamationmark.triangle"
        case .ready: return "figure.walk.motion"
        }
    }

    private func startButton(height: CGFloat) -> some View {
        Button {
            model.toggle()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: height > 150 ? 64 : 40, weight: .bold))
                Text(model.isRunning ? "Stop" : "Start")
                    .font(.largeTitle.bold())
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(model.isRunning ? Theme.stop : Theme.go, in: RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .heavy), trigger: model.isRunning)
        .accessibilityLabel(model.isRunning ? "Stop guidance" : "Start guidance")
        .accessibilityValue(model.statusMessage)
        .accessibilityHint("Start, then stand still for two seconds while it finds the floor. You can also say, Hey Siri, start Wayfinder.")
    }

    @ViewBuilder
    private var cameraCard: some View {
        if let snapshot = model.snapshot, model.isRunning {
            CameraOverlayView(snapshot: snapshot, route: model.navigationProgress, compact: true)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
        } else {
            Text("The camera view appears here once guidance starts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var destinationCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Text("Where to?").font(.title3.bold())
            HStack(spacing: 10) {
                TextField("Say or type a place", text: $model.destination)
                    .font(.title3)
                    .padding(12)
                    .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 12))
                    .submitLabel(.search)
                    .focused($destinationFocused)
                    .onSubmit { model.searchDestination(model.destination) }
                Button {
                    destinationFocused = false
                    model.dictateDestination()
                } label: {
                    Image(systemName: model.speechInput.isListening ? "waveform" : "mic.fill")
                        .font(.title)
                        .foregroundStyle(.black)
                        .frame(width: 60, height: 60)
                        .background(model.speechInput.isListening ? Theme.stop : Theme.accent, in: Circle())
                        .symbolEffect(.pulse, isActive: model.speechInput.isListening)
                }
                .accessibilityLabel(model.speechInput.isListening ? "Stop listening" : "Say a destination")
            }
            if model.speechInput.isListening {
                Text(model.speechInput.transcript.isEmpty ? "Listening…" : model.speechInput.transcript)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            if let message = model.searchMessage {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.searchResults) { place in
                Button { model.go(to: place) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).font(.headline)
                            if !place.detail.isEmpty {
                                Text(place.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let distance = place.distance {
                            Text(GuidedNavigator.spokenDistance(distance)).font(.subheadline.monospacedDigit())
                        }
                        Image(systemName: "chevron.right")
                    }
                    .padding(12)
                    .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to \(place.spoken)")
            }
            routeSummary
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var routeSummary: some View {
        switch model.navigationState {
        case .navigating(let name):
            VStack(alignment: .leading, spacing: 6) {
                Label("Going to \(name)", systemImage: "location.fill").font(.headline).foregroundStyle(Theme.route)
                if let progress = model.navigationProgress {
                    Text(progress.nextInstruction).font(.title3.bold())
                    HStack {
                        if let turn = progress.distanceToNextTurn {
                            Text("in \(GuidedNavigator.spokenDistance(turn))")
                        }
                        Spacer()
                        if let remaining = progress.remaining {
                            Text("\(GuidedNavigator.spokenDistance(remaining)) left").foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .accessibilityElement(children: .combine)
        case .searching(let query):
            Label("Finding a route to \(query)…", systemImage: "magnifyingglass").font(.subheadline)
        case .arrived(let name):
            Label("Arrived at \(name)", systemImage: "flag.checkered").font(.headline)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }
}
