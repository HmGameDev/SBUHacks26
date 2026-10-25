import SwiftUI

/// Full-screen view of what the camera sees while guiding, opened after Start when "Open camera view after Start"
/// is on. A large Stop bar sits at the bottom so stopping never means hunting for a button.
struct LiveCameraView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.statusMessage)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Hide camera", systemImage: "chevron.down")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.card, in: Capsule())
                }
                .accessibilityHint("Goes back to the home screen. Guidance keeps running.")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let snapshot = model.snapshot {
                CameraOverlayView(snapshot: snapshot, route: model.navigationProgress, compact: true)
                    .accessibilityHidden(true)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting the camera…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                model.stop(announce: true)
                dismiss()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(Theme.stop)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop guidance")
        }
        .background(Color.black)
        .onAppear { model.cameraPreviewVisible = true }
        .onDisappear { model.cameraPreviewVisible = false }
        .onChange(of: model.isRunning) { _, running in
            if !running { dismiss() }
        }
    }
}
