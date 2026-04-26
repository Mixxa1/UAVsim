import Foundation
import simd

/// Legacy compatibility shims for the previous primitive-path system.
///
/// The new fixed-wing autopilot derives smooth turns directly from raw
/// polyline waypoints (carrot pursuit + low-pass filtered course). It does
/// not need pre-baked line/arc geometry, so the old `FixedWingFlyablePath`
/// system has been deleted.
///
/// These thin shims exist only so the ViewModel call sites that still
/// construct/cache/pass a `FixedWingFlyableRoute` continue to compile while
/// the surrounding helpers are torn down. Constructed routes are simply
/// ignored by `FixedWingAutopilotController.trackingCommand`.

enum FixedWingTurnDirection: String, Equatable {
    case left
    case right
}

struct FixedWingPathPrimitive: Equatable {
    var startPoint: SIMD2<Float>
    var endPoint: SIMD2<Float>
    var length: Float
}

struct FixedWingPrimitiveAnchor: Equatable {
    var primitiveIndex: Int
    var missionWaypointIndex: Int
}

struct FixedWingFlyableRoute: Equatable {
    var routeIdentifier: String
    var primitives: [FixedWingPathPrimitive]
    var anchors: [FixedWingPrimitiveAnchor]
    var samples: [SIMD2<Float>]

    var totalLength: Float {
        primitives.reduce(0.0) { $0 + $1.length }
    }

    var isUsable: Bool {
        !primitives.isEmpty
    }
}

final class FixedWingFlyableRouteBuilder {
    struct WaypointInput: Equatable {
        var position: SIMD2<Float>
        var missionWaypointIndex: Int?
    }

    func build(
        routeIdentifier: String,
        start: SIMD2<Float>,
        waypoints: [WaypointInput],
        wing _: FixedWingParameters,
        airspeed _: Float
    ) -> FixedWingFlyableRoute? {
        var points: [SIMD2<Float>] = [start]
        for wp in waypoints where wp.position.x.isFinite && wp.position.y.isFinite {
            if let last = points.last, simd_length(wp.position - last) < 0.5 {
                continue
            }
            points.append(wp.position)
        }
        guard points.count >= 2 else { return nil }

        var primitives: [FixedWingPathPrimitive] = []
        var anchors: [FixedWingPrimitiveAnchor] = []
        for i in 0..<(points.count - 1) {
            let length = simd_length(points[i + 1] - points[i])
            primitives.append(
                FixedWingPathPrimitive(
                    startPoint: points[i],
                    endPoint: points[i + 1],
                    length: length
                )
            )
            if let missionIndex = waypoints.indices.contains(i) ? waypoints[i].missionWaypointIndex : nil {
                anchors.append(
                    FixedWingPrimitiveAnchor(
                        primitiveIndex: i,
                        missionWaypointIndex: missionIndex
                    )
                )
            }
        }
        return FixedWingFlyableRoute(
            routeIdentifier: routeIdentifier,
            primitives: primitives,
            anchors: anchors,
            samples: points
        )
    }
}
