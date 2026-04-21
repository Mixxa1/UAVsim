import Foundation
import simd

enum MissionLegKind: String, Equatable {
    case outbound
    case leadTurn
    case returnHome
}

struct MissionLeg: Identifiable, Equatable {
    let id: UUID
    var startPoint: SIMD2<Float>
    var endPoint: SIMD2<Float>
    var sampledPoints: [SIMD2<Float>]
    var kind: MissionLegKind
    var targetWaypointIndex: Int?

    init(
        id: UUID = UUID(),
        startPoint: SIMD2<Float>,
        endPoint: SIMD2<Float>,
        sampledPoints: [SIMD2<Float>],
        kind: MissionLegKind,
        targetWaypointIndex: Int?
    ) {
        self.id = id
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.sampledPoints = sampledPoints
        self.kind = kind
        self.targetWaypointIndex = targetWaypointIndex
    }

    var lengthMeters: Float {
        guard sampledPoints.count > 1 else {
            return simd_distance(startPoint, endPoint)
        }

        return zip(sampledPoints, sampledPoints.dropFirst()).reduce(0.0) { partialResult, pair in
            partialResult + simd_distance(pair.0, pair.1)
        }
    }
}
