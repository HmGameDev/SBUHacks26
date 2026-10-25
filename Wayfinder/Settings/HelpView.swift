import AppIntents
import SwiftUI

/// Every cue, what it means, and a button to hear it. Doubles as a practice screen before the first walk.
struct HelpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// True when pushed inside Settings, so it does not add its own navigation bar.
    var embedded = false

    private struct Entry: Identifiable {
        let id: String
        let icon: String
        let meaning: String
        let haptic: HapticEvent?
    }

    private let cues: [Entry] = [
        Entry(id: "stop", icon: "hand.raised.fill", meaning: "Something is right in front of you. Stop. Comes with a long buzz.", haptic: .stopBuzz),
        Entry(id: "step_down", icon: "arrow.down.to.line", meaning: "A curb or a single step down ahead.", haptic: .stopBuzz),
        Entry(id: "stairs_up", icon: "stairs", meaning: "Stairs going up ahead. Comes with a double tap.", haptic: .doubleTap),
        Entry(id: "stairs_down", icon: "stairs", meaning: "Stairs going down ahead. Comes with a double tap.", haptic: .doubleTap),
        Entry(id: "left", icon: "arrow.turn.up.left", meaning: "The clearest way around is to your left.", haptic: nil),
        Entry(id: "slight_left", icon: "arrow.up.left", meaning: "Bear a little to the left.", haptic: nil),
        Entry(id: "right", icon: "arrow.turn.up.right", meaning: "The clearest way around is to your right.", haptic: nil),
        Entry(id: "slight_right", icon: "arrow.up.right", meaning: "Bear a little to the right.", haptic: nil),
        Entry(id: "clear", icon: "checkmark.circle", meaning: "The way ahead is open again (Chatty only).", haptic: nil),
    ]

    var body: some View {
        if embedded {
            list
        } else {
            NavigationStack {
                list.toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private var list: some View {
        let feedback = model.feedback
        return List {
            Section {
                ForEach(cues) { cue in
                    Button {
                        feedback.preview(phrases: [cue.id])
                        if let haptic = cue.haptic { feedback.preview(haptic: haptic) }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: cue.icon).font(.title2).frame(width: 36).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CuePhrases.shared.text(for: cue.id)).font(.headline)
                                Text(cue.meaning).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle").font(.title2)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Plays this cue")
                }
            } header: {
                Text("Tap to hear each cue")
            } footer: {
                Text("A repeating tap that speeds up means something is getting closer. Silence means the way is clear.")
            }

            Section("Before you walk") {
                Label("Wear the phone on your chest, camera facing out, tilted slightly down.", systemImage: "iphone")
                Label("Press Start, then stand still for two seconds until it says Ready.", systemImage: "figure.stand")
                Label("Keep using your cane or guide dog. This app adds warnings; it does not replace them.", systemImage: "figure.walk")
            }

            Section {
                SiriTipView(intent: StartGuidanceIntent())
                SiriTipView(intent: NavigateIntent())
                Text("\"Hey Siri, start Wayfinder\" or \"stop Wayfinder\"")
                Text("\"Hey Siri, start navigation with Wayfinder\" (Siri asks where to)")
                Text("\"Hey Siri, stop navigation in Wayfinder\" (obstacle warnings stay on)")
                Text("\"Hey Siri, Wayfinder where am I going\"")
                Text("\"Hey Siri, Wayfinder quieter\" or \"more detail\"")
            } header: {
                Text("Hands-free with Siri")
            } footer: {
                Text("Open the app once after installing so Siri learns these phrases.")
            }
        }
        .navigationTitle("What the sounds mean")
        .onAppear { feedback.start() }
    }
}
