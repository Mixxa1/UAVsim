import Foundation

struct DesignMassProperties: Codable, Equatable {
    var massKg: Double
    var centerOfMassX: Double
    var centerOfMassY: Double
    var centerOfMassZ: Double
    var boundingWidth: Double
    var boundingHeight: Double
    var boundingDepth: Double
    var dragPenalty: Double
    var structuralRating: Double

    static let zero = DesignMassProperties(
        massKg: 0,
        centerOfMassX: 0, centerOfMassY: 0, centerOfMassZ: 0,
        boundingWidth: 0, boundingHeight: 0, boundingDepth: 0,
        dragPenalty: 0, structuralRating: 1
    )
}
