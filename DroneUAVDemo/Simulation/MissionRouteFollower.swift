import Foundation
import simd

final class MissionRouteFollower {
    struct Configuration {
        var lookaheadDistance: Float
        var segmentAdvanceDistance: Float
        var waypointCaptureRadius: Float
        var lineCaptureTolerance: Float
        var maxCrossTrackCorrectionDistance: Float

        static let multirotor = Configuration(
            lookaheadDistance: 1.2,
            segmentAdvanceDistance: 0.16,
            waypointCaptureRadius: 0.28,
            lineCaptureTolerance: 0.20,
            maxCrossTrackCorrectionDistance: 2.2
        )

        static let fixedWing = Configuration(
            lookaheadDistance: 10.0,
            segmentAdvanceDistance: 4.0,
            waypointCaptureRadius: 5.2,
            lineCaptureTolerance: 2.4,
            maxCrossTrackCorrectionDistance: 12.0
        )
    }

    func track(
        route: MissionValidatedRoute,
        activeSegmentIndex: Int,
        currentPosition: SIMD3<Float>,
        configuration: Configuration
    ) -> MissionLineTrackingState? {
        guard !route.segments.isEmpty else {
            return nil
        }

        let clampedSegmentIndex = min(max(0, activeSegmentIndex), route.segments.count - 1)
        let segment = route.segments[clampedSegmentIndex]
        let projection = project(position: currentPosition, onto: segment)
        let projectedPoint = projection.projectedPoint
        let signedCrossTrackError = projection.signedCrossTrackError
        let crossTrackError = abs(signedCrossTrackError)
        let distanceToSegmentEnd = simd_length(
            SIMD2<Float>(
                segment.end.x - projectedPoint.x,
                segment.end.z - projectedPoint.z
            )
        )
        let segmentEndsAtWaypoint = route.waypointRoutePointIndices.contains(segment.endPointIndex)
        let activeWaypointIndex = segment.targetWaypointIndex

        let clampedCorrectionDistance = min(
            configuration.maxCrossTrackCorrectionDistance,
            crossTrackError
        )
        let correctionDirection = SIMD2<Float>(
            projectedPoint.x - currentPosition.x,
            projectedPoint.z - currentPosition.z
        )
        let correctionDirectionLength = simd_length(correctionDirection)
        let normalizedCorrectionDirection = correctionDirectionLength > 0.0001
            ? correctionDirection / correctionDirectionLength
            : .zero

        let alongDistance: Float
        if crossTrackError > configuration.lineCaptureTolerance {
            alongDistance = 0.0
        } else {
            alongDistance = min(configuration.lookaheadDistance, distanceToSegmentEnd)
        }

        let lineLockTarget = SIMD3<Float>(
            projectedPoint.x + segment.directionXZ.x * alongDistance,
            segment.end.y,
            projectedPoint.z + segment.directionXZ.y * alongDistance
        )
        let correctionScale = min(1.0, clampedCorrectionDistance / max(0.001, configuration.maxCrossTrackCorrectionDistance))
        let correctedTarget = SIMD3<Float>(
            lineLockTarget.x + normalizedCorrectionDirection.x * clampedCorrectionDistance * correctionScale,
            lineLockTarget.y,
            lineLockTarget.z + normalizedCorrectionDirection.y * clampedCorrectionDistance * correctionScale
        )

        let targetPoint: SIMD3<Float> = {
            if crossTrackError > configuration.lineCaptureTolerance {
                return projectedPoint
            }
            if segmentEndsAtWaypoint && distanceToSegmentEnd <= configuration.waypointCaptureRadius {
                return segment.end
            }
            return correctedTarget
        }()

        let remainingPath = buildRemainingPath(
            route: route,
            activeSegmentIndex: clampedSegmentIndex,
            projectedPoint: projectedPoint
        )
        let distanceRemaining = buildRemainingDistance(
            route: route,
            activeSegmentIndex: clampedSegmentIndex,
            projectedPoint: projectedPoint
        )
        let waypointDistance: Float = {
            if let activeWaypointIndex,
               let waypointPoint = route.waypointPoint(forWaypointIndex: activeWaypointIndex) {
                return simd_length(
                    SIMD2<Float>(
                        waypointPoint.x - currentPosition.x,
                        waypointPoint.z - currentPosition.z
                    )
                )
            }
            return distanceToSegmentEnd
        }()

        let shouldAdvanceSegment = shouldAdvance(
            route: route,
            segment: segment,
            progress: projection.progress,
            distanceToSegmentEnd: distanceToSegmentEnd,
            waypointDistance: waypointDistance,
            crossTrackError: crossTrackError,
            configuration: configuration
        )
        let isRouteComplete = shouldAdvanceSegment && clampedSegmentIndex >= route.segments.count - 1

        return MissionLineTrackingState(
            activeSegment: MissionActiveSegment(
                index: clampedSegmentIndex,
                segment: segment,
                activeWaypointIndex: activeWaypointIndex
            ),
            projectedPoint: projectedPoint,
            targetPoint: shouldAdvanceSegment ? segment.end : targetPoint,
            crossTrackError: crossTrackError,
            signedCrossTrackError: signedCrossTrackError,
            alongTrackProgress: projection.progress,
            distanceToSegmentEnd: distanceToSegmentEnd,
            distanceRemaining: distanceRemaining,
            waypointDistance: waypointDistance,
            remainingPath: remainingPath,
            shouldAdvanceSegment: shouldAdvanceSegment,
            isRouteComplete: isRouteComplete
        )
    }

    private func shouldAdvance(
        route: MissionValidatedRoute,
        segment: MissionRouteSegment,
        progress: Float,
        distanceToSegmentEnd: Float,
        waypointDistance: Float,
        crossTrackError: Float,
        configuration: Configuration
    ) -> Bool {
        let advanceDistance = min(
            max(configuration.segmentAdvanceDistance, segment.lengthMeters * 0.12),
            max(configuration.segmentAdvanceDistance, segment.lengthMeters * 0.45)
        )
        let segmentEndsAtWaypoint = route.waypointRoutePointIndices.contains(segment.endPointIndex)
        guard progress >= 0.995,
              distanceToSegmentEnd <= advanceDistance,
              crossTrackError <= configuration.lineCaptureTolerance else {
            return false
        }

        if segmentEndsAtWaypoint {
            return waypointDistance <= configuration.waypointCaptureRadius
        }

        return true
    }

    private func buildRemainingPath(
        route: MissionValidatedRoute,
        activeSegmentIndex: Int,
        projectedPoint: SIMD3<Float>
    ) -> [SIMD3<Float>] {
        guard activeSegmentIndex < route.segments.count else {
            return []
        }

        var output: [SIMD3<Float>] = [projectedPoint]
        let nextPointIndex = route.segments[activeSegmentIndex].endPointIndex
        for point in route.points[nextPointIndex...].map(\.position) {
            let last = output[output.count - 1]
            let distance = simd_length(SIMD2<Float>(point.x - last.x, point.z - last.z))
            if distance > 0.01 {
                output.append(point)
            }
        }
        return output
    }

    private func buildRemainingDistance(
        route: MissionValidatedRoute,
        activeSegmentIndex: Int,
        projectedPoint: SIMD3<Float>
    ) -> Float {
        guard activeSegmentIndex < route.segments.count else {
            return 0.0
        }

        var remaining = simd_length(
            SIMD2<Float>(
                route.segments[activeSegmentIndex].end.x - projectedPoint.x,
                route.segments[activeSegmentIndex].end.z - projectedPoint.z
            )
        )

        if activeSegmentIndex + 1 < route.segments.count {
            for segment in route.segments[(activeSegmentIndex + 1)...] {
                remaining += segment.lengthMeters
            }
        }

        return remaining
    }

    private func project(
        position: SIMD3<Float>,
        onto segment: MissionRouteSegment
    ) -> (projectedPoint: SIMD3<Float>, progress: Float, signedCrossTrackError: Float) {
        let segmentVector = SIMD2<Float>(segment.end.x - segment.start.x, segment.end.z - segment.start.z)
        let offset = SIMD2<Float>(position.x - segment.start.x, position.z - segment.start.z)
        let segmentLengthSquared = max(0.0001, simd_length_squared(segmentVector))
        let rawProgress = simd_dot(offset, segmentVector) / segmentLengthSquared
        let progress = max(0.0, min(1.0, rawProgress))
        let projectedPoint = SIMD3<Float>(
            segment.start.x + (segment.end.x - segment.start.x) * progress,
            segment.start.y + (segment.end.y - segment.start.y) * progress,
            segment.start.z + (segment.end.z - segment.start.z) * progress
        )
        let crossTrackVector = SIMD2<Float>(
            position.x - projectedPoint.x,
            position.z - projectedPoint.z
        )
        let signedCrossTrackError = segment.directionXZ.x * crossTrackVector.y - segment.directionXZ.y * crossTrackVector.x
        return (projectedPoint, progress, signedCrossTrackError)
    }
}
