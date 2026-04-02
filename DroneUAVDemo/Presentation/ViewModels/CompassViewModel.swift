import Foundation
import SwiftUI
import simd

@MainActor
final class CompassViewModel: ObservableObject {
    @Published private(set) var headingDegrees: Double = 0.0
    @Published private(set) var targetBearingDegrees: Double = .nan

    func update(
        headingRadians: Float,
        dronePlanarPosition: SIMD2<Float>,
        targetMarker: TargetMarkerState?
    ) {
        let nextHeading = Double(bodyHeadingDegrees(fromYawRadians: headingRadians))
        if abs(nextHeading - headingDegrees) > 0.05 {
            headingDegrees = nextHeading
        }

        if let targetMarker {
            let nextBearing = Double(targetMarker.bearingDegrees(from: dronePlanarPosition))
            if !targetBearingDegrees.isFinite || abs(nextBearing - targetBearingDegrees) > 0.05 {
                targetBearingDegrees = nextBearing
            }
        } else if targetBearingDegrees.isFinite {
            targetBearingDegrees = .nan
        }
    }
}
