import SwiftUI

/// Set up before mounting: one huge start button, mode, destination, verbosity. Works with VoiceOver.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showDebug = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            Button {
                model.toggle()
            } label: {
                VStack(spacing: 12) {
                    Image(systemName: model.isRunning ? "stop.circle.fill" : "figure.walk.circle.fill")
                        .font(.system(size: 96))
                    Text(model.isRunning ? "Stop" : "Start")
                        .font(.largeTitle.bold())
                    Text(model.statusMessage)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(model.isRunning ? Color.red : Color.green, in: RoundedRectangle(cornerRadius: 32))
            }
            .accessibilityLabel(model.isRunning ? "Stop guidance" : "Start guidance")
            .accessibilityValue(model.statusMessage)
            .accessibilityHint("Mount the phone after starting. You can also say, Hey Siri, start Wayfinder.")

            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(AppModel.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Mode")

            if model.mode == .guided {
                TextField("Destination", text: $model.destination)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .onSubmit { if model.isRunning { model.navigate(to: model.destination) } }
                Text(navigationText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker("Verbosity", selection: $model.verbosity) {
                ForEach(Verbosity.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("How much the app talks")

            Button {
                model.debugVisible = true
                showDebug = true
            } label: {
                Label("Debug view", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .fullScreenCover(isPresented: $showDebug, onDismiss: { model.debugVisible = false }) {
            DebugRootView()
                .environment(model)
        }
    }

    private var navigationText: String {
        switch model.navigationState {
        case .idle: "Siri: \"Navigate with Wayfinder\", or type a place."
        case .searching(let query): "Finding \(query)…"
        case .navigating(let name): "Navigating to \(name)"
        case .arrived(let name): "Arrived at \(name)"
        case .failed(let message): message
        }
    }
}
