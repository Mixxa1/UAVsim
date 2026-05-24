import Foundation

struct DesignTransform: Codable, Equatable {
    var positionX: Double = 0.0
    var positionY: Double = 0.0
    var positionZ: Double = 0.0
    var rotationX: Double = 0.0
    var rotationY: Double = 0.0
    var rotationZ: Double = 0.0
    var scale: Double = 1.0

    static let identity = DesignTransform()
}
