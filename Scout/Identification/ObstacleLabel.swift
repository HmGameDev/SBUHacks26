import Foundation

/// How much a named obstacle matters to someone walking. Decides which verbosity levels hear its name.
enum LabelTier: Int, Comparable, Sendable {
    /// Furniture and street objects: named only in Chatty.
    case common
    /// Things that move, hurt on contact, or matter for finding the way (doors): named in Normal and Chatty.
    case hazard

    static func < (a: LabelTier, b: LabelTier) -> Bool { a.rawValue < b.rawValue }

    /// Minimal never names anything; Normal names hazards; Chatty names everything.
    func isSpoken(at verbosity: Verbosity) -> Bool {
        switch verbosity {
        case .minimal: false
        case .normal: self == .hazard
        case .chatty: true
        }
    }
}

/// What an obstacle is, when the camera can tell. Detection (something is there) always comes from LiDAR;
/// a label only names an obstacle the depth grid already holds.
enum ObstacleLabel: String, Sendable, CaseIterable {
    case person, bicycle, motorbike, vehicle, dog, pole, door, wheelchair, cart, tree
    case chair, bench, table, desk, couch, bed, shelf, cabinet, plant, bag, hydrant, parkingMeter, trashCan, box

    var tier: LabelTier {
        switch self {
        case .person, .bicycle, .motorbike, .vehicle, .dog, .pole, .door, .wheelchair, .cart, .tree: .hazard
        case .chair, .bench, .table, .desk, .couch, .bed, .shelf, .cabinet, .plant, .bag, .hydrant, .parkingMeter,
             .trashCan, .box: .common
        }
    }

    /// Phrase id in `phrases.json`: `label_` plus the name in snake case.
    var phrase: String {
        let snake = rawValue.reduce(into: "") { out, ch in
            if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
        }
        return "label_" + snake
    }

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
