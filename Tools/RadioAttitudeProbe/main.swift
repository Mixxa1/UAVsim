// Headless check that an aircraft's own attitude does not cost it its control link.
//
// Built for the WingtraRAY that was sent home from every waypoint it stopped at. A tailsitter
// stands on its tail to hover; the one whip its radio was given is upright only in level flight,
// so standing up laid it flat — null down the heading, polarisation across the ground station's —
// and the recording shows the link going from −78 dBm to −115…−129 dBm without the aircraft
// moving. The equipment failsafe did what it is for and turned the aircraft round.
//
// Clear line of sight throughout: what is measured is the installation, not the city.
import Foundation

let repository = LIPODroneModelRepository()
var failures: [String] = []

func controlLink(_ profile: DroneModelProfile, distance: Double, altitude: Double,
                 yaw: Double, pitch: Double, roll: Double) -> RFLinkEvaluation? {
    let manager = RFSystemManager(configuration: RFCompatibilityPreset.make(for: profile, controlLink: nil))
    var poses: [String: RFEndpointPose] = [:]
    for device in manager.configuration.devices {
        switch device.endpoint {
        case .airborne:
            poses[device.id] = RFEndpointPose(
                positionM: RFVector3D(x: 0, y: altitude, z: -distance),
                orientation: RFOrientation(yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: roll))
        case .ground, .relay:
            let placement = manager.configuration.endpointPlacement(for: device.id)
            poses[device.id] = RFEndpointPose(positionM: placement.offsetFromHomeM, orientation: placement.orientation)
        }
    }
    let results = manager.evaluateAvailableLinks(
        endpointPosesM: poses, environment: .clear, timestamp: 0, pathContextResolver: { _ in .clear })
    if case let .success(evaluation)? = results[.control] { return evaluation }
    return nil
}

func column(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }

print("Control link against attitude, 1500 m out at 60 m, every heading in 30° steps")
print(String(repeating: "-", count: 104))
print(column("airframe", 30) + column("style", 16) + column("level dBm", 11) + column("banked 40°", 12)
      + column("nose up 45°", 13) + column("nose up 90°", 13) + column("past 100°", 11) + "worst health")

for profile in repository.allProfiles where profile.airframeClass == .hybridVTOL {
    func weakest(pitch: Double, roll: Double) -> (dBm: Double, health: RFLinkHealth)? {
        var result: (dBm: Double, health: RFLinkHealth)?
        for step in 0..<12 {
            guard let evaluation = controlLink(profile, distance: 1500, altitude: 60, yaw: Double(step) * 30,
                                               pitch: pitch, roll: roll) else { return nil }
            if result == nil || evaluation.rf.receivedPowerDBm < result!.dBm {
                result = (evaluation.rf.receivedPowerDBm, evaluation.quality.health)
            }
        }
        return result
    }
    guard let level = weakest(pitch: 0, roll: 0), let banked = weakest(pitch: 0, roll: 40),
          let halfway = weakest(pitch: 45, roll: 0), let upright = weakest(pitch: 90, roll: 0),
          let past = weakest(pitch: 100, roll: 0) else {
        failures.append("\(profile.displayName): no control link to evaluate")
        continue
    }
    let hover = [halfway, upright, past]
    let worst = hover.map(\.health).first { $0 != .healthy } ?? .healthy
    print(column(profile.displayName, 30) + column("\(profile.airframeStyle)", 16)
          + column(String(format: "%.1f", level.dBm), 11) + column(String(format: "%.1f", banked.dBm), 12)
          + column(String(format: "%.1f", halfway.dBm), 13) + column(String(format: "%.1f", upright.dBm), 13)
          + column(String(format: "%.1f", past.dBm), 11) + worst.rawValue)

    // An attitude the airframe flies in every sortie may not cost it more than its own 40° turn
    // does — the loss every aircraft here already lives with. Half a decibel for the pattern.
    if profile.airframeStyle == .tailsitterVTOL {
        for (name, sample) in [("45°", halfway), ("90°", upright), ("100°", past)] {
            if sample.dBm < banked.dBm - 0.5 {
                failures.append(String(format: "%@: nose up %@ costs %.1f dB of control link, a 40° bank %.1f dB",
                                       profile.displayName, name, level.dBm - sample.dBm, level.dBm - banked.dBm))
            }
            if sample.health != .healthy {
                failures.append("\(profile.displayName): control link \(sample.health.rawValue) nose up \(name) at 1500 m in the clear")
            }
        }
    }
    // Level flight is the installation everyone else has; a second element must not change it.
    if abs(level.dBm - (controlLink(profile, distance: 1500, altitude: 60, yaw: 0, pitch: 0, roll: 0)?.rf.receivedPowerDBm ?? 0)) > 0.5 {
        failures.append("\(profile.displayName): level-flight link depends on heading")
    }
}

print("")
if failures.isEmpty {
    print("RESULT: PASS - a tailsitter keeps its control link standing up")
} else {
    failures.forEach { print("FAIL: \($0)") }
    print("RESULT: FAIL")
    exit(1)
}
