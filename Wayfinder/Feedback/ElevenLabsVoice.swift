import Foundation

/// Live ElevenLabs speech for dynamic text such as turn-by-turn directions. Fixed cues never come
/// through here: they are bundled clips, so Stop and Left work offline with no delay.
///
/// The key comes from Settings or the gitignored `Secrets.plist`. Anyone holding the app binary can
/// extract it, so use a key with a low spending limit (the team accepted this for the demo).
final class ElevenLabsVoice {
    static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"

    var apiKey: String?
    var voiceID = ElevenLabsVoice.defaultVoiceID

    var isConfigured: Bool { !(apiKey ?? "").isEmpty }

    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private let maxCached = 40
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// MP3 audio for `text`, or nil on any failure. Calls back on the main thread.
    func audio(for text: String, completion: @escaping (Data?) -> Void) {
        let cacheKey = voiceID + "|" + text
        if let cached = cache[cacheKey] {
            completion(cached)
            return
        }
        guard let apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_64") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            // Flash is ElevenLabs' lowest-latency model.
            "model_id": "eleven_flash_v2_5",
            "voice_settings": ["stability": 0.7, "similarity_boost": 0.75],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let audio = ok ? data : nil
            DispatchQueue.main.async {
                if let audio, let self {
                    self.cache[cacheKey] = audio
                    self.cacheOrder.append(cacheKey)
                    if self.cacheOrder.count > self.maxCached {
                        self.cache[self.cacheOrder.removeFirst()] = nil
                    }
                }
                completion(audio)
            }
        }.resume()
    }
}
