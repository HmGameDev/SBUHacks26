import AVFoundation

/// Plays cues through the phone speaker. Bundled ElevenLabs clips for the fixed vocabulary; live
/// ElevenLabs for directions when a key is set and the network answers quickly; on-device speech for
/// everything else. Use from the main thread.
final class SpeechChannel: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    /// Called once a whole cue has finished playing. Not called for cues cut off by `stop()`.
    var onFinished: (() -> Void)?
    var preferences: () -> Preferences = { Preferences() }

    private(set) var missingClips: [String] = []
    private var players: [String: AVAudioPlayer] = [:]
    private let synthesizer = AVSpeechSynthesizer()
    let cloud = ElevenLabsVoice()

    private enum Item {
        case clip(String)
        case text(String, cloud: Bool)
    }

    private var sequence: [Item] = []
    private var active = false
    private weak var currentPlayer: AVAudioPlayer?
    private var cloudPlayer: AVAudioPlayer?
    private var currentUtterance: AVSpeechUtterance?
    /// Bumped on every stop, so a late network reply cannot play over a newer cue.
    private var generation = 0
    /// How long to wait for the network before falling back to on-device speech.
    private let cloudDeadline: TimeInterval = 1.5

    override init() {
        super.init()
        synthesizer.delegate = self
        configureSession()
        preload()
    }

    var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // .playback ignores the silent switch; .duckOthers lowers music or podcasts while a cue plays.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func preload() {
        for phrase in CuePhrases.shared.active {
            guard let url = Bundle.main.url(forResource: phrase.id, withExtension: "mp3"),
                  let player = try? AVAudioPlayer(contentsOf: url) else {
                missingClips.append(phrase.id)
                continue
            }
            player.delegate = self
            player.prepareToPlay()
            players[phrase.id] = player
        }
    }

    /// - Parameter allowCloud: only for dynamic, non-urgent text (directions). Never for safety cues.
    func play(_ cue: Cue, interrupt: Bool, allowCloud: Bool = false) {
        if interrupt { stop() }
        if cue.phrases.isEmpty {
            sequence = [.text(cue.text, cloud: allowCloud)]
        } else {
            sequence = cue.phrases.map { id in
                players[id] != nil ? .clip(id) : .text(CuePhrases.shared.text(for: id), cloud: false)
            }
        }
        active = true
        playNext()
    }

    func stop() {
        generation += 1
        sequence.removeAll()
        active = false
        currentPlayer?.stop()
        currentPlayer = nil
        cloudPlayer?.stop()
        cloudPlayer = nil
        currentUtterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func playNext() {
        guard active else { return }
        guard !sequence.isEmpty else {
            active = false
            onFinished?()
            return
        }
        let prefs = preferences()
        switch sequence.removeFirst() {
        case .clip(let id):
            guard let player = players[id] else { playNext(); return }
            player.currentTime = 0
            player.volume = prefs.cueVolume
            currentPlayer = player
            if !player.play() { playNext() }
        case .text(let text, let allowCloud):
            if allowCloud && prefs.useAIVoice && configureCloud(prefs) {
                speakCloud(text, prefs: prefs)
            } else {
                speakLocal(text, prefs: prefs)
            }
        }
    }

    private func configureCloud(_ prefs: Preferences) -> Bool {
        let key = prefs.elevenLabsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        cloud.apiKey = key.isEmpty ? Secrets.elevenLabsKey : key
        let voice = prefs.elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        cloud.voiceID = voice.isEmpty ? (Secrets.elevenLabsVoiceID ?? ElevenLabsVoice.defaultVoiceID) : voice
        return cloud.isConfigured
    }

    private func speakCloud(_ text: String, prefs: Preferences) {
        let token = generation
        var settled = false
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, !settled, token == self.generation else { return }
            settled = true
            self.speakLocal(text, prefs: prefs)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + cloudDeadline, execute: fallback)
        cloud.audio(for: text) { [weak self] data in
            guard let self, !settled, token == self.generation else { return }
            settled = true
            fallback.cancel()
            guard let data, let player = try? AVAudioPlayer(data: data) else {
                self.speakLocal(text, prefs: prefs)
                return
            }
            player.delegate = self
            player.volume = prefs.cueVolume
            self.cloudPlayer = player
            self.currentPlayer = player
            if !player.play() { self.speakLocal(text, prefs: prefs) }
        }
    }

    private func speakLocal(_ text: String, prefs: Preferences) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, prefs.speechRate))
        utterance.volume = prefs.cueVolume
        utterance.voice = Voices.voice(for: prefs.voiceIdentifier)
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    // MARK: - Delegates (delivered on the main thread)

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === currentPlayer else { return }
        currentPlayer = nil
        if player === cloudPlayer { cloudPlayer = nil }
        playNext()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        playNext()
    }
}
