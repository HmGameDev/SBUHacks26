import CoreImage
import ImageIO
import Foundation

struct CloudName: Sendable, Equatable {
    /// One to three plain words, spoken with the iPhone voice.
    let name: String
    /// Moves or hurts on contact: named in Normal as well as Chatty.
    let hazard: Bool
}

/// Names an obstacle the phone's own detectors could not, using Gemini. It takes one to three seconds and needs
/// a signal, so Scout only asks about obstacles still more than `cloudMinDistance` away: the name is ready by the
/// time the obstacle is close enough to matter, and if it never comes, nothing else changes.
/// Safety cues never wait for it. The key comes from Settings or the gitignored `Secrets.plist`.
final class CloudNamer {
    static let defaultModel = "gemini-3.5-flash-lite"

    var apiKey: String?
    var model = CloudNamer.defaultModel

    var isConfigured: Bool { !(apiKey ?? "").isEmpty }

    private let queue = DispatchQueue(label: "scout.cloud", qos: .utility)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// - Parameter image: the sensor-orientation color frame; it is turned upright before sending.
    /// - Parameter completion: called on an arbitrary queue, with nil on any failure or "unknown".
    func name(image: ColorImage, distance: Float, completion: @escaping @Sendable (CloudName?) -> Void) {
        guard let key = apiKey, !key.isEmpty else { completion(nil); return }
        let model = model
        queue.async {
            let upright = CIImage(cgImage: image.cgImage).oriented(.right)
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            guard let jpeg = self.ciContext.jpegRepresentation(
                of: upright, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [quality: 0.6]
            ), let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
                completion(nil)
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "contents": [[
                    "role": "user",
                    "parts": [
                        ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]],
                        ["text": Self.prompt(distance: distance)],
                    ],
                ]],
                // The fastest setting; this model cannot turn thinking fully off.
                "generationConfig": ["thinkingConfig": ["thinkingLevel": "minimal"]],
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            self.session.dataTask(with: request) { data, response, _ in
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { completion(nil); return }
                completion(Self.parse(response: data))
            }.resume()
        }
    }

    static func prompt(distance: Float) -> String {
        """
        This photo is from a camera worn on the chest of a blind person who is walking. Something is in their \
        path about \(String(format: "%.0f", distance)) meters ahead, near the middle of the photo. Name it in one \
        to three plain words a walker would understand, like "recycling bin" or "glass door". Then say whether it \
        could move or hurt them on contact. Reply on one line as: name | yes, or: name | no. If you cannot tell, \
        reply: unknown
        """
    }

    /// The text of the first candidate in a generateContent response.
    static func parse(response data: Data) -> CloudName? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return parse(text)
    }

    /// "Recycling bin | no" to a name. Anything unsure, long, or odd is dropped rather than spoken.
    static func parse(_ text: String) -> CloudName? {
        guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(separator: "|", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        }
        guard let name = fields.first?.lowercased(), !name.isEmpty, name != "unknown",
              name.count <= 30, name.split(separator: " ").count <= 3,
              name.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" }) else { return nil }
        let hazard = fields.count > 1 && fields[1].lowercased().hasPrefix("yes")
        return CloudName(name: name.prefix(1).uppercased() + name.dropFirst(), hazard: hazard)
    }
}
