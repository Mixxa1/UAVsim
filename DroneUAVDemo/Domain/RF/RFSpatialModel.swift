import Foundation

struct RFEndpointPose: Hashable, Sendable {
    var positionM: RFVector3D
    var orientation: RFOrientation

    init(positionM: RFVector3D, orientation: RFOrientation = .identity) {
        self.positionM = positionM
        self.orientation = orientation
    }

    func phaseCenter(for antenna: RFAntennaInstance) -> RFVector3D {
        positionM + orientation.rotatingLocalVectorToWorld(antenna.mountPositionM)
    }
}

enum RFPathObstructionKind: String, Codable, Hashable, Sendable {
    case airframe
    case vegetation
    case structure
    case terrain
    case generic
}

enum RFMaterialClass: String, Codable, Hashable, Sendable {
    case composite
    case metal
    case concrete
    case glass
    case wood
    case foliage
    case soil
    case rock
    case water
    case generic
}

struct RFPathObstruction: Codable, Hashable, Sendable {
    var id: String
    var kind: RFPathObstructionKind
    var material: RFMaterialClass
    var distanceFromTransmitterM: Double
}

/// Geometry facts only. The adapter reports what the ray crossed; RF policy decides the dB cost.
struct RFPathContext: Codable, Hashable, Sendable {
    var hasLineOfSight: Bool
    var obstructions: [RFPathObstruction]

    static let clear = RFPathContext(hasLineOfSight: true, obstructions: [])

    func merging(_ other: RFPathContext) -> RFPathContext {
        var byID = Dictionary(uniqueKeysWithValues: obstructions.map { ($0.id, $0) })
        for obstruction in other.obstructions {
            byID[obstruction.id] = obstruction
        }
        return RFPathContext(
            hasLineOfSight: hasLineOfSight && other.hasLineOfSight,
            obstructions: byID.values.sorted {
                if $0.distanceFromTransmitterM == $1.distanceFromTransmitterM {
                    return $0.id < $1.id
                }
                return $0.distanceFromTransmitterM < $1.distanceFromTransmitterM
            }
        )
    }
}

struct RFPathQuery: Hashable, Sendable {
    var linkKind: LogicalLinkKind
    var transmitterEndpoint: RFEndpointKind
    var receiverEndpoint: RFEndpointKind
    var transmitterPhaseCenterM: RFVector3D
    var receiverPhaseCenterM: RFVector3D
}

struct RFBodyVolume: Hashable, Sendable {
    var id: String
    var centerM: RFVector3D
    var radiiM: RFVector3D
    var orientation: RFOrientation
    var material: RFMaterialClass

    /// Tests the ray leaving an antenna against the inner airframe volume. Antennas authored a
    /// little inside a visual shell are projected to that shell first, so a mount does not shadow
    /// itself in every direction merely because the render mesh has thickness.
    func shadows(antennaPositionM: RFVector3D, remotePositionM: RFVector3D) -> Bool {
        let localAntenna = orientation.rotatingWorldVectorToLocal(antennaPositionM - centerM)
        let localRemote = orientation.rotatingWorldVectorToLocal(remotePositionM - centerM)
        let radii = RFVector3D(
            x: max(0.01, abs(radiiM.x)),
            y: max(0.01, abs(radiiM.y)),
            z: max(0.01, abs(radiiM.z))
        )
        let scaledRadius = sqrt(
            square(localAntenna.x / radii.x)
                + square(localAntenna.y / radii.y)
                + square(localAntenna.z / radii.z)
        )
        guard scaledRadius > 0.05 else {
            // A centre-mounted antenna has no declared exterior side; treating it as permanently
            // buried would be a much stronger and less useful assumption than leaving it clear.
            return false
        }

        let surfaceAntenna = scaledRadius < 1.0
            ? localAntenna / scaledRadius
            : localAntenna
        let ray = localRemote - surfaceAntenna
        let rayLength = ray.length
        guard rayLength > 0.002 else { return false }
        let start = surfaceAntenna + ray / rayLength * 0.001
        let direction = localRemote - start

        let a = square(direction.x / radii.x)
            + square(direction.y / radii.y)
            + square(direction.z / radii.z)
        guard a > 0.000_000_001 else { return false }
        let b = 2.0 * (
            start.x * direction.x / square(radii.x)
                + start.y * direction.y / square(radii.y)
                + start.z * direction.z / square(radii.z)
        )
        let c = square(start.x / radii.x)
            + square(start.y / radii.y)
            + square(start.z / radii.z) - 1.0
        let discriminant = b * b - 4.0 * a * c
        guard discriminant >= 0 else { return false }
        let root = sqrt(discriminant)
        let near = (-b - root) / (2.0 * a)
        let far = (-b + root) / (2.0 * a)
        return (near > 0.000_001 && near < 1.0) || (far > 0.000_001 && far < 1.0)
    }

    private func square(_ value: Double) -> Double { value * value }
}

struct RFPathLossModel {
    func losses(for context: RFPathContext, frequencyHz: Double) -> RFSupplementalLosses {
        var losses = RFSupplementalLosses()
        let frequencyScale = max(0.0, log10(max(1.0, frequencyHz) / 1_000_000_000.0))

        for obstruction in context.obstructions {
            switch obstruction.kind {
            case .airframe:
                losses.bodyShadowDB += bodyLossDB(
                    material: obstruction.material,
                    frequencyScale: frequencyScale
                )
            case .vegetation:
                losses.vegetationDB += 3.5 + 2.5 * frequencyScale
            case .structure, .terrain, .generic:
                losses.materialDB += materialLossDB(
                    material: obstruction.material,
                    frequencyScale: frequencyScale
                )
            }
        }

        // A small edge/diffraction term keeps NLOS distinct from merely crossing a lossy volume.
        if !context.hasLineOfSight {
            losses.diffractionDB = 6.0 + 2.0 * frequencyScale
        }
        losses.bodyShadowDB = min(losses.bodyShadowDB, 36.0)
        losses.vegetationDB = min(losses.vegetationDB, 30.0)
        losses.materialDB = min(losses.materialDB, 48.0)
        return losses
    }

    private func bodyLossDB(material: RFMaterialClass, frequencyScale: Double) -> Double {
        switch material {
        case .metal: return 20.0 + 4.0 * frequencyScale
        case .composite: return 11.0 + 3.0 * frequencyScale
        case .wood, .foliage: return 6.0 + 2.0 * frequencyScale
        case .concrete, .glass, .soil, .rock, .water, .generic:
            return 9.0 + 2.0 * frequencyScale
        }
    }

    private func materialLossDB(material: RFMaterialClass, frequencyScale: Double) -> Double {
        switch material {
        case .metal: return 26.0 + 3.0 * frequencyScale
        case .concrete: return 14.0 + 5.0 * frequencyScale
        case .glass: return 4.0 + 2.0 * frequencyScale
        case .wood: return 6.0 + 2.0 * frequencyScale
        case .foliage: return 3.5 + 2.5 * frequencyScale
        case .soil, .rock: return 18.0 + 4.0 * frequencyScale
        case .water: return 3.0 + 2.0 * frequencyScale
        case .composite: return 10.0 + 3.0 * frequencyScale
        case .generic: return 9.0 + 3.0 * frequencyScale
        }
    }
}

enum RFAntennaSpatialModel {
    static func patternAdjustmentDB(
        antenna: RFAntennaInstance,
        endpointOrientation: RFOrientation,
        directionWorld: RFVector3D
    ) -> Double {
        guard let directionWorld = directionWorld.normalized else { return 0 }
        let bodyLocal = endpointOrientation.rotatingWorldVectorToLocal(directionWorld)
        let antennaLocal = antenna.orientation.rotatingWorldVectorToLocal(bodyLocal)
        let profile = antenna.profile
        let frontToBack = max(0, profile.frontToBackRatioDB ?? 24.0)

        switch profile.patternKind {
        case .isotropic, .custom:
            return 0
        case .omnidirectional:
            let horizontalMagnitude = hypot(antennaLocal.x, antennaLocal.z)
            let elevationDegrees = abs(atan2(antennaLocal.y, horizontalMagnitude) * 180.0 / .pi)
            let halfBeam = max(1.0, (profile.verticalBeamwidthDegrees ?? 78.0) * 0.5)
            return -min(frontToBack, 3.0 * square(elevationDegrees / halfBeam))
        case .directional:
            guard antennaLocal.z > 0 else { return -frontToBack }
            let azimuthDegrees = atan2(antennaLocal.x, antennaLocal.z) * 180.0 / .pi
            let elevationDegrees = atan2(
                antennaLocal.y,
                hypot(antennaLocal.x, antennaLocal.z)
            ) * 180.0 / .pi
            let horizontalHalfBeam = max(1.0, (profile.horizontalBeamwidthDegrees ?? 70.0) * 0.5)
            let verticalHalfBeam = max(1.0, (profile.verticalBeamwidthDegrees ?? 55.0) * 0.5)
            let normalizedOffsetSquared = square(azimuthDegrees / horizontalHalfBeam)
                + square(elevationDegrees / verticalHalfBeam)
            return -min(frontToBack, 3.0 * normalizedOffsetSquared)
        }
    }

    static func polarizationMismatchLossDB(
        transmitter: RFAntennaInstance,
        transmitterOrientation: RFOrientation,
        receiver: RFAntennaInstance,
        receiverOrientation: RFOrientation,
        propagationDirectionWorld: RFVector3D
    ) -> Double {
        let txPolarization = transmitter.profile.polarization
        let rxPolarization = receiver.profile.polarization
        if txPolarization == .custom || rxPolarization == .custom { return 0 }

        let txCircular = txPolarization == .lhcp || txPolarization == .rhcp
        let rxCircular = rxPolarization == .lhcp || rxPolarization == .rhcp
        if txCircular || rxCircular {
            if txCircular && rxCircular {
                return txPolarization == rxPolarization ? 0 : 25.0
            }
            return 3.0103
        }

        guard let propagationDirection = propagationDirectionWorld.normalized else { return 0 }
        let txAxis = worldPolarizationAxis(
            polarization: txPolarization,
            antenna: transmitter,
            endpointOrientation: transmitterOrientation
        )
        let rxAxis = worldPolarizationAxis(
            polarization: rxPolarization,
            antenna: receiver,
            endpointOrientation: receiverOrientation
        )
        let txProjected = projectedUnit(txAxis, perpendicularTo: propagationDirection)
        let rxProjected = projectedUnit(rxAxis, perpendicularTo: propagationDirection)
        if txProjected == nil, rxProjected == nil {
            // Both equal linear axes are end-on to the ray. Their pattern null already accounts
            // for the loss; adding a second 30 dB "mismatch" would double-count the same geometry.
            return txPolarization == rxPolarization ? 0 : 30.0
        }
        guard let txProjected, let rxProjected else { return 30.0 }
        let coupling = min(1.0, max(0.0, abs(txProjected.dot(rxProjected))))
        return min(30.0, -20.0 * log10(max(0.031_622_776, coupling)))
    }

    private static func worldPolarizationAxis(
        polarization: RFPolarization,
        antenna: RFAntennaInstance,
        endpointOrientation: RFOrientation
    ) -> RFVector3D {
        let local = polarization == .linearHorizontal
            ? RFVector3D(x: 1, y: 0, z: 0)
            : RFVector3D(x: 0, y: 1, z: 0)
        let body = antenna.orientation.rotatingLocalVectorToWorld(local)
        return endpointOrientation.rotatingLocalVectorToWorld(body)
    }

    private static func projectedUnit(
        _ vector: RFVector3D,
        perpendicularTo direction: RFVector3D
    ) -> RFVector3D? {
        (vector - direction * vector.dot(direction)).normalized
    }

    private static func square(_ value: Double) -> Double { value * value }
}

extension RFVector3D {
    static func - (lhs: RFVector3D, rhs: RFVector3D) -> RFVector3D {
        RFVector3D(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static func * (lhs: RFVector3D, rhs: Double) -> RFVector3D {
        RFVector3D(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    static func / (lhs: RFVector3D, rhs: Double) -> RFVector3D {
        guard rhs != 0 else { return .zero }
        return RFVector3D(x: lhs.x / rhs, y: lhs.y / rhs, z: lhs.z / rhs)
    }

    var length: Double { sqrt(x * x + y * y + z * z) }

    var normalized: RFVector3D? {
        let magnitude = length
        guard magnitude.isFinite, magnitude > 0.000_000_001 else { return nil }
        return self / magnitude
    }

    func dot(_ other: RFVector3D) -> Double {
        x * other.x + y * other.y + z * other.z
    }
}

extension RFOrientation {
    func rotatingLocalVectorToWorld(_ vector: RFVector3D) -> RFVector3D {
        let roll = rollDegrees * .pi / 180.0
        let pitch = pitchDegrees * .pi / 180.0
        let yaw = yawDegrees * .pi / 180.0
        return Self.rotateY(Self.rotateX(Self.rotateZ(vector, angle: roll), angle: pitch), angle: yaw)
    }

    func rotatingWorldVectorToLocal(_ vector: RFVector3D) -> RFVector3D {
        let roll = rollDegrees * .pi / 180.0
        let pitch = pitchDegrees * .pi / 180.0
        let yaw = yawDegrees * .pi / 180.0
        return Self.rotateZ(Self.rotateX(Self.rotateY(vector, angle: -yaw), angle: -pitch), angle: -roll)
    }

    private static func rotateX(_ vector: RFVector3D, angle: Double) -> RFVector3D {
        let c = cos(angle), s = sin(angle)
        return RFVector3D(x: vector.x, y: c * vector.y - s * vector.z, z: s * vector.y + c * vector.z)
    }

    private static func rotateY(_ vector: RFVector3D, angle: Double) -> RFVector3D {
        let c = cos(angle), s = sin(angle)
        return RFVector3D(x: c * vector.x + s * vector.z, y: vector.y, z: -s * vector.x + c * vector.z)
    }

    private static func rotateZ(_ vector: RFVector3D, angle: Double) -> RFVector3D {
        let c = cos(angle), s = sin(angle)
        return RFVector3D(x: c * vector.x - s * vector.y, y: s * vector.x + c * vector.y, z: vector.z)
    }
}
