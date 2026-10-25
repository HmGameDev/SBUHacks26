import AVFoundation
import Foundation
import Observation

/// What the person using the app chooses: voice, loudness, vibration, camera preview. Separate from
/// `Tuning`, which holds the engineering knobs on the debug screen.
struct Preferences: Codable, Equatable, Sendable {
    /// `AVSpeechSynthesisVoice.identifier` for on-device speech; nil picks the best installed English voice.
    var voiceIdentifier: String?
    var speechRate: Float = 0.52
    /// 0...1, applied to every cue on top of the phone's own volume.
    var cueVolume: Float = 1.0
    /// 0...1, scales every vibration.
    var hapticStrength: Float = 1.0
    /// Open the full-screen camera view after Start.
    var showCamera = false
    /// Say what obstacles are ("Person, left"). Off until the blind-tester gate passes with it on.
    var nameObstacles = false
    /// Pasted in Settings; overrides `Secrets.plist`. Names obstacles the phone's detectors cannot.
    var geminiKey = ""
    /// Read directions with the ElevenLabs voice when a key is set and the network answers in time.
    var useAIVoice = true
    /// Pasted in Settings; overrides `Secrets.plist`. Stays on this phone, never in git.
    var elevenLabsKey = ""
    var elevenLabsVoiceID = ""

    init() {}

    // Decode field by field so adding a preference later never wipes the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        voiceIdentifier = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        speechRate = try c.decodeIfPresent(Float.self, forKey: .speechRate) ?? d.speechRate
        cueVolume = try c.decodeIfPresent(Float.self, forKey: .cueVolume) ?? d.cueVolume
        hapticStrength = try c.decodeIfPresent(Float.self, forKey: .hapticStrength) ?? d.hapticStrength
        showCamera = try c.decodeIfPresent(Bool.self, forKey: .showCamera) ?? d.showCamera
        nameObstacles = try c.decodeIfPresent(Bool.self, forKey: .nameObstacles) ?? d.nameObstacles
        geminiKey = try c.decodeIfPresent(String.self, forKey: .geminiKey) ?? d.geminiKey
        useAIVoice = try c.decodeIfPresent(Bool.self, forKey: .useAIVoice) ?? d.useAIVoice
        elevenLabsKey = try c.decodeIfPresent(String.self, forKey: .elevenLabsKey) ?? d.elevenLabsKey
        elevenLabsVoiceID = try c.decodeIfPresent(String.self, forKey: .elevenLabsVoiceID) ?? d.elevenLabsVoiceID
    }
}

@Observable
final class PreferencesStore {
    private static let key = "scout.preferences.v1"

    var preferences: Preferences {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = stored
        } else {
            preferences = Preferences()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Values from the gitignored `Scout/Secrets.plist`, if the team created one (see README).
enum Secrets {
    private static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        return plist.compactMapValues { $0 as? String }
    }()

    static var elevenLabsKey: String? { values["ELEVENLABS_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } }
    static var elevenLabsVoiceID: String? { values["ELEVENLABS_VOICE_ID"].flatMap { $0.isEmpty ? nil : $0 } }
    static var geminiKey: String? { values["GEMINI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } }
    static var geminiModel: String? { values["GEMINI_MODEL"].flatMap { $0.isEmpty ? nil : $0 } }
}

enum Voices {
    /// English voices installed on this phone, best quality first.
    static var english: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                a.quality.rawValue == b.quality.rawValue ? a.name < b.name : a.quality.rawValue > b.quality.rawValue
            }
    }

    static func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        let us = english.filter { $0.language == "en-US" }
        return us.first ?? english.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }
}
