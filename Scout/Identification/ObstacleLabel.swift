import Foundation

/// How much a named obstacle matters to someone walking. Decides which verbosity levels hear its name.
enum LabelTier: Int, Comparable, Sendable {
    /// Furniture and street objects: named only in Chatty.
    case common
    /// Things that move or hurt on contact: named in Normal and Chatty.
    case hazard

    static func < (a: LabelTier, b: LabelTier) -> Bool { a.rawValue < b.rawValue }
}

/// What an obstacle is, when the camera can tell. Detection (something is there) always comes from LiDAR;
/// a label only names an obstacle the depth grid already holds.
enum ObstacleLabel: String, Sendable, CaseIterable {
    case person, bicycle, motorbike, vehicle, dog, pole
    case chair, bench, table, couch, plant, bag, hydrant, parkingMeter

    var tier: LabelTier {
        switch self {
        case .person, .bicycle, .motorbike, .vehicle, .dog, .pole: .hazard
        case .chair, .bench, .table, .couch, .plant, .bag, .hydrant, .parkingMeter: .common
        }
    }

    /// Phrase id in `phrases.json`.
    var phrase: String {
        switch self {
        case .parkingMeter: "label_parking_meter"
        default: "label_\(rawValue)"
        }
    }

    /// Minimal never names anything; Normal names hazards; Chatty names everything on the list.
    func isSpoken(at verbosity: Verbosity) -> Bool {
        switch verbosity {
        case .minimal: false
        case .normal: tier == .hazard
        case .chatty: true
        }
    }
}
