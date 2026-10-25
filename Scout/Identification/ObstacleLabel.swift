import Foundation

/// How much a named obstacle matters to someone walking. Decides which verbosity levels hear its name.
enum LabelTier: Int, Comparable, Sendable {
    /// Furniture and street objects.
    case common
    /// Things that move, hurt on contact, or matter for finding the way (doors). Only these get Chatty's
    /// "just off to your left" mentions when they are beside the path rather than in it.
    case hazard

    static func < (a: LabelTier, b: LabelTier) -> Bool { a.rawValue < b.rawValue }

    /// Minimal never names anything; Normal and Chatty name whatever is in the way (team decision, 2026-10-25).
    func isSpoken(at verbosity: Verbosity) -> Bool {
        verbosity != .minimal
    }
}

/// What an obstacle is, when the camera can tell. Detection (something is there) always comes from LiDAR;
/// a label only names an obstacle the depth grid already holds. `doorway` is the exception: an opening found
/// in the depth grid (`DoorwayDetector`), announced on its own and never treated as an obstacle.
enum ObstacleLabel: String, Sendable, CaseIterable {
    case person, bicycle, motorbike, vehicle, dog, pole, door, wheelchair, cart, tree, doorway
    case chair, bench, table, desk, couch, bed, shelf, cabinet, plant, bag, hydrant, parkingMeter, trashCan, box

    var tier: LabelTier {
        switch self {
        case .person, .bicycle, .motorbike, .vehicle, .dog, .pole, .door, .wheelchair, .cart, .tree, .doorway: .hazard
        case .chair, .bench, .table, .desk, .couch, .bed, .shelf, .cabinet, .plant, .bag, .hydrant, .parkingMeter,
             .trashCan, .box: .common
        }
    }

    private var snake: String {
        rawValue.reduce(into: "") { out, ch in
            if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
        }
    }

    /// Phrase ids in `phrases.json`, each the name in snake case after a prefix:
    /// `label_` "A door" (before "is just off to your left."),
    /// `ahead_` "There's a door just ahead," (before which way to go),
    /// `near_` "There's a door right in front of you." (after Stop).
    var phrase: String { "label_" + snake }
    var aheadPhrase: String { "ahead_" + snake }
    var nearPhrase: String { "near_" + snake }

    func isSpoken(at verbosity: Verbosity) -> Bool { tier.isSpoken(at: verbosity) }

    /// Open Images class names from the bundled detector (`ObstacleDetector.mlpackage`, YOLOv8n trained on
    /// Open Images V7) that Scout speaks, and what it calls them. People and dogs are left to Apple's own
    /// detectors, which are better at them; stairs are left to the depth-based stair detector.
    static let openImages: [String: ObstacleLabel] = [
        "Bicycle": .bicycle, "Motorcycle": .motorbike,
        "Car": .vehicle, "Bus": .vehicle, "Truck": .vehicle, "Van": .vehicle, "Taxi": .vehicle,
        "Street light": .pole, "Traffic sign": .pole, "Traffic light": .pole, "Stop sign": .pole,
        "Door": .door, "Wheelchair": .wheelchair, "Cart": .cart, "Tree": .tree,
        "Chair": .chair, "Stool": .chair, "Bench": .bench,
        "Table": .table, "Kitchen & dining room table": .table, "Coffee table": .table, "Desk": .desk,
        "Couch": .couch, "Sofa bed": .couch, "Bed": .bed,
        "Shelf": .shelf, "Bookcase": .shelf,
        "Cabinetry": .cabinet, "Chest of drawers": .cabinet, "Filing cabinet": .cabinet, "Wardrobe": .cabinet,
        "Houseplant": .plant, "Flowerpot": .plant,
        "Suitcase": .bag, "Backpack": .bag,
        "Fire hydrant": .hydrant, "Parking meter": .parkingMeter, "Waste container": .trashCan, "Box": .box,
    ]
}
