import Foundation
import simd

// MARK: - Guidance math safety helpers

@inline(__always)
func isFiniteVector2(_ value: SIMD2<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite
}

@inline(__always)
func isFiniteVector3(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
}

@inline(__always)
func clampFinite(_ value: Float, fallback: Float = 0.0) -> Float {
    value.isFinite ? value : fallback
}

@inline(__always)
func safeDistance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let delta = a - b
    let length = simd_length(delta)
    return length.isFinite ? length : 0.0
}

@inline(__always)
func normalizeAngleRadians(_ angle: Float) -> Float {
    if !angle.isFinite { return 0.0 }
    var normalized = angle
    while normalized > .pi {
        normalized -= (.pi * 2.0)
    }
    while normalized < -.pi {
        normalized += (.pi * 2.0)
    }
    return normalized
}

@inline(__always)
func safeNormalize(_ vector: SIMD2<Float>) -> SIMD2<Float>? {
    let length = simd_length(vector)
    guard length.isFinite, length > 1.0e-5 else {
        return nil
    }
    let result = vector / length
    return isFiniteVector2(result) ? result : nil
}

// MARK: - Resolver types

/// Where the resolved target was sourced from.
enum MissionGuidanceTargetSource: String, Equatable {
    case missionWaypoint
    case missionRouteMarker
    case manualMarker
    case markerSnappedToWaypoint
    case none
}

/// Why a marker was rejected as a flight target.
enum MissionGuidanceRejectionReason: String, Equatable {
    case noMarker
    case nonFinitePosition
    case outOfBounds
    case tooCloseToCurrentPosition
    case markerNotBoundToActiveTarget
    case missionRequiresWaypoint
}

/// Result of resolving the active guidance target.
struct MissionGuidanceTargetResolution: Equatable {
    /// Validated planar guidance target (XZ). `nil` means the autopilot must hold.
    var planarPosition: SIMD2<Float>?
    var source: MissionGuidanceTargetSource
    var rejectionReason: MissionGuidanceRejectionReason?
    /// Mission target identifier when `source` is mission-derived.
    var activeMissionTargetID: UUID?
    /// Mission waypoint index when target is bound to a waypoint.
    var activeWaypointIndex: Int?
    /// Whether the target should be treated as a strict waypoint (autopilot owns it).
    var ownsAuthority: Bool

    static let unavailable = MissionGuidanceTargetResolution(
        planarPosition: nil,
        source: .none,
        rejectionReason: .noMarker,
        activeMissionTargetID: nil,
        activeWaypointIndex: nil,
        ownsAuthority: false
    )

    var hasFlightTarget: Bool {
        planarPosition != nil
    }
}

/// Inputs for the resolver. Lightweight value type — built once per tick.
struct MissionGuidanceResolutionInput {
    var marker: TargetMarkerState?
    var activeMissionTarget: MissionTarget?
    var missionIsActive: Bool
    var currentPlanarPosition: SIMD2<Float>
    var hardWorldHalfExtent: Float
    /// Maximum allowed distance from the active mission target for a marker
    /// to still be considered "snapped" to that waypoint.
    var waypointSnapToleranceMeters: Float
    /// Minimum planar distance from the drone before a target is meaningful
    /// (smaller distances become hold instead).
    var minimumEngagementDistanceMeters: Float
}

/// Single point of truth for resolving the planar flight target before it
/// is fed into the autopilots. The resolver is intentionally pure: it only
/// reads inputs and decides whether the marker is acceptable. It does not
/// directly mutate state. Callers (e.g. ViewModel orchestrator) decide what
/// to do when the resolution rejects the marker.
final class MissionGuidanceTargetResolver {
    func resolve(
        _ input: MissionGuidanceResolutionInput
    ) -> MissionGuidanceTargetResolution {
        // 1. Mission active: the active mission target is the only legal source
        //    of truth. The marker may only relay it, and only if it is
        //    snapped to that waypoint.
        if input.missionIsActive, let activeTarget = input.activeMissionTarget {
            guard isFiniteVector2(activeTarget.position) else {
                return MissionGuidanceTargetResolution(
                    planarPosition: nil,
                    source: .none,
                    rejectionReason: .nonFinitePosition,
                    activeMissionTargetID: activeTarget.id,
                    activeWaypointIndex: activeTarget.index,
                    ownsAuthority: false
                )
            }

            if let marker = input.marker, isFiniteVector2(marker.position) {
                let snapDistance = safeDistance(marker.position, activeTarget.position)
                if snapDistance <= max(0.05, input.waypointSnapToleranceMeters) {
                    return MissionGuidanceTargetResolution(
                        planarPosition: activeTarget.position,
                        source: .markerSnappedToWaypoint,
                        rejectionReason: nil,
                        activeMissionTargetID: activeTarget.id,
                        activeWaypointIndex: activeTarget.index,
                        ownsAuthority: true
                    )
                }
                // Marker drifted away from active mission waypoint: do not
                // hand authority to it — keep flying the mission target.
                return MissionGuidanceTargetResolution(
                    planarPosition: activeTarget.position,
                    source: .missionWaypoint,
                    rejectionReason: .markerNotBoundToActiveTarget,
                    activeMissionTargetID: activeTarget.id,
                    activeWaypointIndex: activeTarget.index,
                    ownsAuthority: true
                )
            }

            return MissionGuidanceTargetResolution(
                planarPosition: activeTarget.position,
                source: .missionWaypoint,
                rejectionReason: nil,
                activeMissionTargetID: activeTarget.id,
                activeWaypointIndex: activeTarget.index,
                ownsAuthority: true
            )
        }

        // 2. No mission target: only a manually placed, finite, in-bounds
        //    marker is accepted as an autopilot target.
        guard let marker = input.marker else {
            return MissionGuidanceTargetResolution(
                planarPosition: nil,
                source: .none,
                rejectionReason: .noMarker,
                activeMissionTargetID: nil,
                activeWaypointIndex: nil,
                ownsAuthority: false
            )
        }

        guard isFiniteVector2(marker.position) else {
            return MissionGuidanceTargetResolution(
                planarPosition: nil,
                source: .none,
                rejectionReason: .nonFinitePosition,
                activeMissionTargetID: nil,
                activeWaypointIndex: nil,
                ownsAuthority: false
            )
        }

        let safeHalfExtent = max(1.0, input.hardWorldHalfExtent)
        if abs(marker.position.x) > safeHalfExtent + 0.5 ||
            abs(marker.position.y) > safeHalfExtent + 0.5 {
            return MissionGuidanceTargetResolution(
                planarPosition: nil,
                source: .none,
                rejectionReason: .outOfBounds,
                activeMissionTargetID: nil,
                activeWaypointIndex: nil,
                ownsAuthority: false
            )
        }

        let distance = safeDistance(marker.position, input.currentPlanarPosition)
        if distance < max(0.05, input.minimumEngagementDistanceMeters) {
            return MissionGuidanceTargetResolution(
                planarPosition: nil,
                source: .none,
                rejectionReason: .tooCloseToCurrentPosition,
                activeMissionTargetID: nil,
                activeWaypointIndex: nil,
                ownsAuthority: false
            )
        }

        return MissionGuidanceTargetResolution(
            planarPosition: marker.position,
            source: .manualMarker,
            rejectionReason: nil,
            activeMissionTargetID: nil,
            activeWaypointIndex: nil,
            ownsAuthority: true
        )
    }

    /// Convenience: validate a previously resolved planar target before use.
    func validatePlanarTarget(
        _ position: SIMD2<Float>?,
        currentPlanarPosition: SIMD2<Float>,
        hardWorldHalfExtent: Float
    ) -> Bool {
        guard let position, isFiniteVector2(position) else {
            return false
        }
        let halfExtent = max(1.0, hardWorldHalfExtent) + 0.5
        if abs(position.x) > halfExtent || abs(position.y) > halfExtent {
            return false
        }
        return safeDistance(position, currentPlanarPosition).isFinite
    }
}
