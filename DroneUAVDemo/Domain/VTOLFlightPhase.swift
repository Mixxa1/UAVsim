import Foundation

/// Derived telemetry label for a hybridVTOL aircraft's current place in the
/// hover<->cruise sweep. This is *not* an input to force computation (that
/// reads `DroneState.vtolTransitionProgress`, a continuous scalar, directly)
/// and it does not replace `DroneFlightMode`/`DronePhysicalState` — it is
/// additive, display-oriented metadata for airframes that carry propulsion
/// units capable of tilting.
enum VTOLFlightPhase: String, CaseIterable, Hashable {
    case verticalTakeoff
    case hover
    case transitionToForward
    case cruise
    case transitionToHover
    case verticalLanding
}
