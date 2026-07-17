import Foundation
import simd

struct CodableVector3D: Codable, Equatable, Hashable {
    let x: Double
    let y: Double
    let z: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ vector: SIMD3<Double>) {
        x = vector.x
        y = vector.y
        z = vector.z
    }

    init(_ vector: SIMD3<Float>) {
        x = Double(vector.x)
        y = Double(vector.y)
        z = Double(vector.z)
    }

    var simd: SIMD3<Double> { SIMD3<Double>(x, y, z) }
    var simdFloat: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}
