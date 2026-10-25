import AVFoundation
import SwiftUI
import UIKit

/// Everyday settings. Every change plays an example right away, so the user hears or feels what it does.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showKey = false

    private var voices: [AVSpeechSynthesisVoice] { Voices.english }

    var body: some View {
        @Bindable var model = model
        @Bindable var store = model.preferencesStore
        let feedback = model.feedback
        NavigationStack {
            Form {
                Section {
                    ForEach(Verbosity.allCases) { level in
                        Button {
                            model.verbosity = level
                            feedback.preview(phrases: Self.example(for: level))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(level.title).font(.headline)
                                    Text(Self.describe(level)).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.verbosity == level {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(model.verbosity == level ? .isSelected : [])
                    }
                } header: {
                    Text("How much it talks")
                } footer: {
                    Text("Tap a level to hear an example.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Label("Cue volume: \(Int(store.preferences.cueVolume * 100))%", systemImage: "speaker.wave.2")
                        Slider(value: $store.preferences.cueVolume, in: 0.2...1, step: 0.05, onEditingChanged: { editing in
                            if !editing { feedback.preview(phrases: ["left"]) }
                        })
                        .accessibilityLabel("Cue volume")
                        // VoiceOver adjusts sliders by swiping, which never "lets go", so preview on each step.
                        .onChange(of: store.preferences.cueVolume) {
                            if UIAccessibility.isVoiceOverRunning { feedback.preview(phrases: ["left"]) }
                        }
                    }
                    if feedback.speech.outputVolume < 0.6 {
                        Label("The phone's own volume is low. Press the volume up button.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Loudness")
                } footer: {
                    Text("Let go of the slider to hear a cue at that volume. The phone's volume buttons set the overall level.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Label("Strength: \(Int(store.preferences.hapticStrength * 100))%", systemImage: "iphone.radiowaves.left.and.right")
                        Slider(value: $store.preferences.hapticStrength, in: 0.2...1, step: 0.05, onEditingChanged: { editing in
                            if !editing { feedback.preview(haptic: .stopBuzz) }
                        })
                        .accessibilityLabel("Vibration strength")
                        // VoiceOver adjusts sliders by swiping, which never "lets go", so preview on each step.
                        .onChange(of: store.preferences.hapticStrength) {
                            if UIAccessibility.isVoiceOverRunning { feedback.preview(haptic: .stopBuzz) }
                        }
                    }
                    Button("Feel: Stop (long buzz)") { feedback.preview(haptic: .stopBuzz) }
                    Button("Feel: Stairs (double tap)") { feedback.preview(haptic: .doubleTap) }
                    Button("Feel: something getting closer") { feedback.previewPulse() }
                } header: {
                    Text("Vibration")
                } footer: {
                    Text("Vibration says how urgent, never which way. The voice gives the direction.")
                }

                Section {
                    Picker("Voice", selection: $store.preferences.voiceIdentifier) {
                        Text("Best available").tag(String?.none)
                        ForEach(voices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(Voices.qualityName(voice)))").tag(Optional(voice.identifier))
                        }
                    }
                    .onChange(of: store.preferences.voiceIdentifier) {
                        feedback.preview(text: "This is how spoken directions and messages will sound.")
                    }
                    VStack(alignment: .leading) {
                        Label("Speaking speed", systemImage: "hare")
                        Slider(value: $store.preferences.speechRate, in: 0.35...0.65, step: 0.01, onEditingChanged: { editing in
                            if !editing { feedback.preview(text: "In 30 meters, turn left onto Main Street.") }
                        })
                        .accessibilityLabel("Speaking speed")
                        // VoiceOver adjusts sliders by swiping, which never "lets go", so preview on each step.
                        .onChange(of: store.preferences.speechRate) {
                            if UIAccessibility.isVoiceOverRunning { feedback.preview(text: "In 30 meters, turn left onto Main Street.") }
                        }
                    }
                } header: {
                    Text("iPhone voice")
                } footer: {
                    Text("Used when the AI voice is off or the network is slow. For a more natural voice, download a Premium voice in the iPhone Settings app: Accessibility, Spoken Content, Voices, English.")
                }

                Section {
                    Toggle("Read directions with the AI voice", isOn: $store.preferences.useAIVoice)
                        .tint(Theme.accent)
                    HStack {
                        Group {
                            if showKey {
                                TextField("ElevenLabs API key", text: $store.preferences.elevenLabsKey)
                            } else {
                                SecureField("ElevenLabs API key", text: $store.preferences.elevenLabsKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(showKey ? "Hide key" : "Show key")
                    }
                    TextField("Voice ID (optional)", text: $store.preferences.elevenLabsVoiceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Hear the AI voice") {
                        feedback.preview(text: "In 30 meters, turn left onto Main Street.", cloud: true)
                    }
                    Text(aiVoiceStatus(store.preferences)).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("AI voice for directions")
                } footer: {
                    Text("Directions and messages use ElevenLabs when the network answers within 1.5 seconds; otherwise the iPhone voice. Stop, Left, Right, and Stairs always use the built-in clips so they work offline. Use a key with a low spending limit: it is stored on this phone.")
                }

                Section {
                    Toggle("Open camera view after Start", isOn: $store.preferences.showCamera)
                        .tint(Theme.accent)
                } footer: {
                    Text("Shows what the camera sees and what the app detects. Keeps the screen bright, which uses more battery.")
                }

                Section {
                    NavigationLink("What the sounds mean") { HelpView(embedded: true) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { feedback.start() }
        }
    }

    private func aiVoiceStatus(_ prefs: Preferences) -> String {
        if !prefs.elevenLabsKey.trimmingCharacters(in: .whitespaces).isEmpty { return "Using the key entered here." }
        if Secrets.elevenLabsKey != nil { return "Using the key built into this copy of the app." }
        return "No key yet: directions use the iPhone voice."
    }

    static func example(for level: Verbosity) -> [String] {
        switch level {
        case .minimal: ["stop"]
        case .normal: ["left"]
        case .chatty: ["left", "dist_2"]
        }
    }

    static func describe(_ level: Verbosity) -> String {
        switch level {
        case .minimal: "Only Stop, Step down, and Stairs."
        case .normal: "Also which way to go around things."
        case .chatty: "Also distances, and Clear when the way opens up."
        }
    }
}
