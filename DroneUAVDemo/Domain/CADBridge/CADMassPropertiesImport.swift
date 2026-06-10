import Foundation

struct CADMassPropertiesImport: Codable, Equatable {
    var massKg: Double
    var centerOfMass: CADBridgeVector3
    var inertiaTensorKgM2: [Double]
    var boundingBoxMin: CADBridgeVector3?
    var boundingBoxMax: CADBridgeVector3?

    init(
        massKg: Double,
        centerOfMass: CADBridgeVector3 = .zero,
        inertiaTensorKgM2: [Double] = [],
        boundingBoxMin: CADBridgeVector3? = nil,
        boundingBoxMax: CADBridgeVector3? = nil
    ) {
        self.massKg = massKg
        self.centerOfMass = centerOfMass
        self.inertiaTensorKgM2 = inertiaTensorKgM2
        self.boundingBoxMin = boundingBoxMin
        self.boundingBoxMax = boundingBoxMax
    }
}
