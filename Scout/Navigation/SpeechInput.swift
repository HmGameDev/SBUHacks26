import AVFoundation
import Observation
import Speech

/// Say a destination instead of typing it. Listens until a short pause, then hands back the words.
/// Use from the main thread.
@Observable
final class SpeechInput {
    private(set) var isListening = false
    private(set) var transcript = ""
    private(set) var problem: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var onFinish: ((String) -> Void)?
    /// Called after listening, so the cue audio session can be restored.
    @ObservationIgnored var onSessionReleased: (() -> Void)?

    /// Asks for permission the first time, then listens. `finish` gets the final words (empty if nothing heard).
    func start(finish: @escaping (String) -> Void) {
        guard !isListening else { return }
        problem = nil
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard status == .authorized, granted else {
                        self.problem = "Microphone or speech recognition is off. Turn them on in Settings."
                        finish("")
                        return
                    }
                    self.begin(finish: finish)
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        request?.endAudio()
        complete()
    }

    private func begin(finish: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition is not available right now."
            finish("")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            problem = "Could not start the microphone."
            finish("")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        onFinish = finish
        transcript = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Could not start the microphone."
            complete()
            return
        }
        isListening = true
        armSilenceTimer(seconds: 6) // nothing said at all

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.armSilenceTimer(seconds: 1.5)
                    if result.isFinal { self.complete() }
                } else if error != nil {
                    self.complete()
                }
            }
        }
    }

    private func armSilenceTimer(seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.request?.endAudio()
            self?.complete()
        }
    }

    private func complete() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        let wasListening = isListening
        isListening = false
        onSessionReleased?()
        let finish = onFinish
        onFinish = nil
        if wasListening || finish != nil {
            finish?(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
