import Foundation
import simd

struct MissionWaypoint: Identifiable, Equatable {
    let id: UUID
    var index: Int
    var position: SIMD2<Float>

    init(
        id: UUID = UUID(),
        index: Int,
        position: SIMD2<Float>
    ) {
        self.id = id
        self.index = index
        self.position = position
    }

    var label: String {
        "W\(index + 1)"
    }
}
