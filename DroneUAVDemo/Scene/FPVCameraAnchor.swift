import Foundation
import simd

struct FPVCameraAnchor {
    let baseOffset: SIMD3<Float>
    let forwardClearance: Float

    static func resolved(for profile: DroneModelProfile, subjectScale: Float) -> FPVCameraAnchor {
        let scale = max(0.18, subjectScale)

        var baseOffset: SIMD3<Float>
        var forwardClearance: Float

        switch profile.airframeClass {
        case .multirotor:
            baseOffset = SIMD3<Float>(0.0, 0.006, 0.0)
            forwardClearance = max(0.024, min(0.070, scale * 0.11))
        case .fixedWing, .hybridVTOL:
            baseOffset = SIMD3<Float>(0.0, 0.010, 0.0)
            forwardClearance = max(0.038, min(0.120, scale * 0.14))
        }

        switch profile.id {
        case "dji-matrice-350-rtk", "dji-phantom-3-standard":
            baseOffset.y += 0.010
            forwardClearance = max(forwardClearance, 0.045)
        case "dji-mavic-4-pro":
            baseOffset.y += 0.008
            forwardClearance = max(forwardClearance, 0.040)
        case "dji-neo":
            baseOffset.y += 0.005
            forwardClearance = max(forwardClearance, 0.028)
        case "freefly-alta-x", "dji-flycart-30", "griff-30", "griff-60":
            baseOffset.y += 0.012
            forwardClearance = max(forwardClearance, 0.055)
        case "avidrone-490tl":
            baseOffset.y += 0.014
            forwardClearance = max(forwardClearance, 0.050)
        case "wingtraone-gen-ii", "quantum-systems-trinity-pro":
            baseOffset.y += 0.008
            forwardClearance = max(forwardClearance, 0.060)
        default:
            break
        }

        return FPVCameraAnchor(baseOffset: baseOffset, forwardClearance: forwardClearance)
    }
}
