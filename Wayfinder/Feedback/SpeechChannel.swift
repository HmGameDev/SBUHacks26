import AVFoundation

/// Plays cues through the phone speaker. Bundled ElevenLabs clips first; on-device speech for dynamic
/// text and for any clip that has not been generated yet. Use from the main thread.
final class SpeechChannel: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    /// Called once a whole cue has finished playing. Not called for cues cut off by `stop()`.
    var onFinished: (() -> Void)?

    private(set) var missingClips: [String] = []
    private var players: [String: AVAudioPlayer] = [:]
    private let synthesizer = AVSpeechSynthesizer()

    private enum Item {
        case clip(String)
        case text(String)
    }

    private var sequence: [Item] = []
    private var active = false
    private weak var currentPlayer: AVAudioPlayer?
    private var currentUtterance: AVSpeechUtterance?

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
            player.volume = 1
            player.prepareToPlay()
            players[phrase.id] = player
        }
    }

    func play(_ cue: Cue, interrupt: Bool) {
        if interrupt { stop() }
        if cue.phrases.isEmpty {
            sequence = [.text(cue.text)]
        } else {
            sequence = cue.phrases.map { id in
                players[id] != nil ? .clip(id) : .text(CuePhrases.shared.text(for: id))
            }
        }
        active = true
        playNext()
    }

    func stop() {
        sequence.removeAll()
        active = false
        currentPlayer?.stop()
        currentPlayer = nil
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
        switch sequence.removeFirst() {
        case .clip(let id):
            guard let player = players[id] else { playNext(); return }
            player.currentTime = 0
            currentPlayer = player
            if !player.play() { playNext() }
        case .text(let text):
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            utterance.volume = 1
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            currentUtterance = utterance
            synthesizer.speak(utterance)
        }
    }

    // MARK: - Delegates (delivered on the main thread)

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === currentPlayer else { return }
        currentPlayer = nil
        playNext()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        playNext()
    }
}
