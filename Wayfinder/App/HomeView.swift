import SwiftUI

/// The everyday screen: start and stop, choose how to walk, say where to go, and optionally watch
/// what the camera sees. Built for VoiceOver and large text first.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showDebug = false
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var showCamera = false
    @FocusState private var destinationFocused: Bool

    var body: some View {
        @Bindable var model = model
        @Bindable var prefs = model.preferencesStore
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    startButton
                    if model.isRunning && prefs.preferences.showCamera && !showCamera {
                        Button { showCamera = true } label: {
                            Label("Show camera view", systemImage: "camera.viewfinder")
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.card)
                    }

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
                        Label("Open camera view after Start", systemImage: "camera.viewfinder").font(.title3)
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
        // The camera view opens on its own screen after Start, so it never shrinks the Start button.
        .onChange(of: model.isRunning) { _, running in
            if running && prefs.preferences.showCamera && !model.isReplaying { showCamera = true }
        }
        .fullScreenCover(isPresented: $showCamera) {
            LiveCameraView().environment(model)
        }
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

    /// Takes most of the screen: it is the one control that matters, and it has to be easy to hit by feel.
    private var startButton: some View {
        Button {
            model.toggle()
        } label: {
            VStack(spacing: 12) {
                Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 96, weight: .bold))
                Text(model.isRunning ? "Stop" : "Start")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 360)
            .background(model.isRunning ? Theme.stop : Theme.go, in: RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .heavy), trigger: model.isRunning)
        .accessibilityLabel(model.isRunning ? "Stop guidance" : "Start guidance")
        .accessibilityValue(model.statusMessage)
        .accessibilityHint("Start, then stand still for two seconds while it finds the floor. You can also say, Hey Siri, start Wayfinder.")
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
