import Foundation

/// Higher tiers win. Stop and Overhead interrupt anything below them.
enum CueTier: Int, Comparable, Sendable, CustomStringConvertible {
    case status = 0, guided, clear, steer, overhead, stop

    static func < (a: CueTier, b: CueTier) -> Bool { a.rawValue < b.rawValue }

    var isSafety: Bool { self >= .overhead }

    var description: String {
        switch self {
        case .status: "Status"
        case .guided: "Guided"
        case .clear: "Clear"
        case .steer: "Steer"
        case .overhead: "Overhead"
        case .stop: "Stop"
        }
    }
}

enum HapticEvent: Sendable, Equatable {
    /// One long strong buzz.
    case stopBuzz
    /// Two quick sharp taps.
    case doubleTap
    /// One light tap.
    case lightTap
}

enum Verbosity: String, CaseIterable, Codable, Sendable, Identifiable {
    case minimal, normal, chatty

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var quieter: Verbosity { self == .chatty ? .normal : .minimal }
    var louder: Verbosity { self == .minimal ? .normal : .chatty }
}

struct Cue: Sendable, Equatable {
    let tier: CueTier
    /// Bundled phrase ids, played in order. Empty for dynamic text.
    let phrases: [String]
    /// Spoken with on-device speech for dynamic cues (street names) or when a clip is missing.
    let text: String
    let haptic: HapticEvent?

    init(tier: CueTier, phrases: [String], haptic: HapticEvent? = nil) {
        self.tier = tier
        self.phrases = phrases
        self.text = phrases.map { CuePhrases.shared.text(for: $0) }.joined(separator: " ")
        self.haptic = haptic
    }

    init(tier: CueTier, text: String, haptic: HapticEvent? = nil) {
        self.tier = tier
        self.phrases = []
        self.text = text
        self.haptic = haptic
    }

    static func status(_ phrase: String) -> Cue {
        Cue(tier: .status, phrases: [phrase], haptic: .lightTap)
    }
}

enum FeedbackCommand: Equatable {
    case speak(Cue, interrupt: Bool)
    case haptic(HapticEvent)
    /// Repeating proximity pulse; nil turns it off.
    case pulse(interval: Double?)
}

/// The fixed cue vocabulary, loaded from `phrases.json` in the app bundle.
struct CuePhrases {
    struct Phrase: Decodable {
        let id: String
        let text: String
        let reserved: Bool?
    }

    static let shared = CuePhrases(bundle: .main)

    let all: [Phrase]
    private let texts: [String: String]

    init(bundle: Bundle) {
        struct File: Decodable { let phrases: [Phrase] }
        if let url = bundle.url(forResource: "phrases", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            all = file.phrases
        } else {
            all = []
        }
        texts = Dictionary(all.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
    }

    /// Phrases the app may play. Reserved ones are cues it no longer plays (Duck), kept so old notes still make sense.
    var active: [Phrase] { all.filter { $0.reserved != true } }

    func text(for id: String) -> String {
        texts[id] ?? id.replacingOccurrences(of: "_", with: " ").capitalized + "."
    }
}
