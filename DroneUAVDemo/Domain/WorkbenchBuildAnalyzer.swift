import Foundation
import simd

enum WorkbenchAirframeClass: String, Codable {
    case multicopter
    case fixedWing
    case hybridVTOL
    case custom
}

struct WorkbenchBuildStats: Hashable {
    var totalMassKg: Double = 0
    var centerOfMass: SIMD3<Double> = .zero
    var motorCount: Int = 0
    var batteryEnergyWh: Double = 0
    var batteryCells: Int = 0
    var batteryCapacityMah: Double = 0
    var nominalVoltage: Double = 0
    var totalMaxThrustN: Double = 0
    var thrustToWeight: Double = 0
    var maxRPM: Double = 0
    var maxElectricalPowerW: Double = 0
    var estimatedHoverTimeMin: Double = 0
    var estimatedMaxSpeedMps: Double = 0
    var inferredClass: WorkbenchAirframeClass = .multicopter
    var componentCount: Int = 0

    var errors: [String] = []
    var warnings: [String] = []

    var isFlightReady: Bool {
        guard errors.isEmpty else { return false }
        switch inferredClass {
        case .fixedWing:
            return motorCount >= 1 && totalMaxThrustN > 0
        case .multicopter, .hybridVTOL:
            return thrustToWeight >= 1.0
        case .custom:
            return motorCount > 0
        }
    }
}

struct WorkbenchResolvedComponentPlacement: Hashable {
    var kind: WorkbenchComponentKind
    var surface: WorkbenchMountSurface
    var position: SIMD3<Float>
    var size: SIMD3<Float>
}

/// Upper hard-points authored by each landing-gear renderer. Placement and
/// mounting hardware both consume this layout so the visible leg roots, rather
/// than the catalog proxy box, are seated against the aircraft belly.
struct WorkbenchLandingGearAttachmentLayout {
    var upperLocalY: Float
    var rootPoints: [SIMD3<Float>]
}

enum WorkbenchBuildAnalyzer {
    private static let gravity = 9.80665

    static func analyze(_ build: WorkbenchBuild) -> WorkbenchBuildStats {
        var stats = WorkbenchBuildStats()
        let frame = build.resolvedFrame
        let arms = frame.motorMounts.count
        let p = WorkbenchComponentSpec.ParamKey.self

        var mass = max(frame.massKg, 0)
        var weightedCoM = SIMD3<Double>.zero
        stats.componentCount = 1

        let motor = build.spec(for: .motor)
        let propeller = build.spec(for: .propeller)
        let componentLayout = resolvedComponentLayout(for: build)
        if motor != nil { stats.motorCount = arms }
        for mount in frame.motorMounts {
            let position = SIMD3<Double>(Double(mount.x), Double(mount.y), Double(mount.z))
            if let motor {
                mass += motor.massKg
                weightedCoM += position * motor.massKg
                stats.componentCount += 1
            }
            if let propeller {
                mass += propeller.massKg
                weightedCoM += position * propeller.massKg
                stats.componentCount += 1
            }
        }

        for kind in WorkbenchBuild.slotKinds where kind != .motor && kind != .propeller {
            guard let spec = build.spec(for: kind) else { continue }
            if kind == .servo, !frame.servoMounts.isEmpty {
                for servoMount in resolvedServoPositions(frame: frame, spec: spec) {
                    mass += spec.massKg
                    weightedCoM += SIMD3<Double>(
                        Double(servoMount.x), Double(servoMount.y), Double(servoMount.z)
                    ) * spec.massKg
                    stats.componentCount += 1
                }
                continue
            }
            let slot = componentLayout[kind]?.position
                ?? resolvedSlotPosition(kind, spec: spec, frame: frame)
            mass += spec.massKg
            weightedCoM += SIMD3<Double>(Double(slot.x), Double(slot.y), Double(slot.z)) * spec.massKg
            stats.componentCount += 1
            if kind == .battery {
                stats.batteryEnergyWh = spec.param(p.batteryEnergyWh) ?? 0
                stats.batteryCells = Int(spec.param(p.batteryCells) ?? 0)
                stats.batteryCapacityMah = spec.param(p.batteryCapacityMah) ?? 0
                stats.nominalVoltage = Double(stats.batteryCells) * 3.7
            }
        }
        stats.totalMassKg = mass
        stats.centerOfMass = mass > 1e-9 ? weightedCoM / mass : .zero

        if let motor {
            let singleThrust = motor.param(p.motorMaxThrustN) ?? 0
            stats.totalMaxThrustN = singleThrust * Double(arms)
            let motorPower = motor.param(p.motorMaxPowerW) ?? 0
            stats.maxElectricalPowerW = motorPower * Double(arms)
            let kv = motor.param(p.motorKv) ?? 0
            stats.maxRPM = kv * stats.nominalVoltage
        }
        let weightN = mass * gravity
        stats.thrustToWeight = weightN > 1e-6 ? stats.totalMaxThrustN / weightN : 0

        if let propeller {
            let pitch = propeller.param(p.propPitchInch) ?? 0
            let pitchSpeed = pitch * 0.0254 * stats.maxRPM / 60.0
            // Real slip is substantial; T/W adds a small authority benefit.
            if frame.architecture == .fixedWing || frame.architecture == .liftCruiseVTOL {
                stats.estimatedMaxSpeedMps = min(52, pitchSpeed * 0.72)
            } else {
                stats.estimatedMaxSpeedMps = min(
                    48,
                    pitchSpeed * 0.68 * max(0.55, min(stats.thrustToWeight / 2.2, 1.15)))
            }
        }
        if stats.batteryEnergyWh > 0, stats.maxElectricalPowerW > 0, stats.thrustToWeight > 0 {
            if frame.architecture == .fixedWing {
                let cruisePower = stats.maxElectricalPowerW * 0.34
                stats.estimatedHoverTimeMin = stats.batteryEnergyWh / max(cruisePower, 1) * 60 * 0.84
            } else {
                let hoverThrottle = sqrt(min(1, 1 / max(stats.thrustToWeight, 0.01)))
                let hoverPower = stats.maxElectricalPowerW * pow(hoverThrottle, 1.55)
                stats.estimatedHoverTimeMin = stats.batteryEnergyWh / max(hoverPower, 1) * 60 * 0.82
            }
        }

        switch frame.architecture {
        case .multicopter:
            stats.inferredClass = arms >= 3 ? .multicopter : .custom
        case .fixedWing:
            stats.inferredClass = .fixedWing
        case .liftCruiseVTOL:
            stats.inferredClass = .hybridVTOL
        }
        for issue in WorkbenchCompatibility.check(build) {
            switch issue.severity {
            case .error: stats.errors.append(issue.message)
            case .warning: stats.warnings.append(issue.message)
            }
        }
        if frame.architecture != .fixedWing,
           stats.totalMaxThrustN > 0, stats.thrustToWeight < 1.0 {
            stats.errors.append(String(
                format: "Тяги недостаточно для взлёта (тяговооружённость %.2f).",
                stats.thrustToWeight))
        } else if frame.architecture != .fixedWing,
                  stats.thrustToWeight > 0, stats.thrustToWeight < 1.8 {
            stats.warnings.append(String(
                format: "Низкая тяговооружённость %.2f — рекомендуем не меньше 2,0.",
                stats.thrustToWeight))
        }
        if stats.estimatedHoverTimeMin > 0, stats.estimatedHoverTimeMin < 2.5 {
            stats.warnings.append(frame.architecture == .fixedWing
                ? "Расчётное время полёта меньше 2,5 минут."
                : "Расчётное время висения меньше 2,5 минут.")
        }

        let horizontalLimit = max(frame.sizeMeters.x, frame.sizeMeters.z) * 0.6 + 0.04
        if simd_length(SIMD2(stats.centerOfMass.x, stats.centerOfMass.z)) > horizontalLimit {
            stats.warnings.append("Центр масс смещён за безопасную область рамы.")
        }
        return stats
    }

    static func slotPosition(
        _ kind: WorkbenchComponentKind,
        frame: WorkbenchResolvedFrame
    ) -> SIMD3<Float> {
        switch kind {
        case .battery: return frame.batteryTray
        case .camera: return frame.cameraMount
        case .payload: return SIMD3<Float>(0, -0.025, 0)
        case .landingGear: return SIMD3<Float>(0, -0.035, 0)
        case .gps: return frame.fcBay + SIMD3<Float>(0, 0.028, -0.025)
        case .receiver: return frame.fcBay + SIMD3<Float>(0.018, 0.012, -0.015)
        case .sensor: return frame.fcBay + SIMD3<Float>(-0.018, 0.012, -0.015)
        case .esc: return frame.fcBay + SIMD3<Float>(0, 0.004, 0)
        case .flightController: return frame.fcBay + SIMD3<Float>(0, 0.012, 0)
        case .servo: return frame.fcBay + SIMD3<Float>(-0.025, 0.010, 0)
        case .motor, .propeller: return .zero
        }
    }

    /// Physical support envelope used by both the layout resolver and the
    /// SceneKit mounting hardware. Keeping this derived from the same frame
    /// dimensions prevents a side shelf from terminating in empty space.
    static func mountingEnvelope(
        for frame: WorkbenchResolvedFrame
    ) -> (
        width: Float,
        length: Float,
        top: Float,
        bottom: Float,
        frontZ: Float,
        rearZ: Float
    ) {
        let frameHeight = Float(max(frame.sizeMeters.y, 0.025))
        if frame.architecture == .multicopter {
            let arm = Float(frame.armLengthM)
            let isMicro = frame.frameClass == .tinyWhoop
            let width = isMicro
                ? max(arm * 0.78, 0.026)
                : min(max(arm * 0.54, 0.060), 0.092)
            let length = isMicro
                ? max(arm * 0.92, 0.030)
                : min(max(arm * 0.68, 0.076), 0.116)
            // The FC/ESC live *inside* a real stack.  `top` is the roof plate,
            // not the FC PCB itself; a top battery therefore sits on the roof
            // instead of being piled directly on the controller.
            let deckTop = isMicro
                ? max(frame.fcBay.y + 0.007, 0.009)
                : max(
                    frame.fcBay.y + 0.020,
                    min(max(frameHeight * 0.28, 0.028), 0.050))
            return (
                width: width,
                length: length,
                top: deckTop,
                bottom: min(-0.004, -frameHeight * 0.12),
                frontZ: length * 0.5,
                rearZ: -length * 0.5)
        }

        // These equations mirror `liftingAirframeNode`: the support envelope
        // is the fuselage, not an arbitrary fraction of the full wingspan.
        let span = max(Float(frame.sizeMeters.x), 0.45)
        let length = max(Float(frame.sizeMeters.z), 0.36)
        let referenceArea = max(Float(frame.wingAreaM2), span * length * 0.18)
        let meanChord = min(max(referenceArea / span, length * 0.20), length * 0.52)
        let bodyRadius = min(
            max(frameHeight * 0.23, span * 0.025),
            max(meanChord * 0.21, 0.038))
        let fuselageTop = bodyRadius * 1.12
        let fuselageBottom = -bodyRadius * 0.88
        let fuselageLength = length * 0.78
        let fuselageCenterZ = -length * 0.015
        let noseLength = max(length * 0.10, 0.055)
        let legacyNoseFrontZ = fuselageLength * 0.5 + fuselageCenterZ
            + noseLength * 0.92
        let cruiseFirewallZ = frame.motorMounts.enumerated()
            .filter { index, _ in
                guard frame.propulsionAxes.indices.contains(index) else { return false }
                let axis = frame.propulsionAxes[index]
                return simd_length_squared(axis) > 1e-8
                    && simd_normalize(axis).z > 0.65
            }
            .map { $0.element.z }
            .max()
        return (
            width: bodyRadius * 2,
            length: fuselageLength,
            top: max(frame.fcBay.y + 0.006, fuselageTop),
            bottom: min(-0.004, fuselageBottom),
            frontZ: cruiseFirewallZ ?? legacyNoseFrontZ,
            rearZ: fuselageCenterZ - fuselageLength * 0.5)
    }

    static func landingGearAttachmentLayout(
        for spec: WorkbenchComponentSpec
    ) -> WorkbenchLandingGearAttachmentLayout {
        let size = spec.proxy.size.simdFloat

        if spec.id.contains("micro-guards") {
            let ringRadius = size.x * 0.42
            let pipeRadius = max(size.y * 0.10, 0.0015)
            return WorkbenchLandingGearAttachmentLayout(
                upperLocalY: pipeRadius,
                rootPoints: [
                    SIMD3<Float>(-ringRadius, pipeRadius, 0),
                    SIMD3<Float>(ringRadius, pipeRadius, 0),
                    SIMD3<Float>(0, pipeRadius, -ringRadius),
                    SIMD3<Float>(0, pipeRadius, ringRadius),
                ])
        }

        if spec.id.contains("cine-bumpers") {
            let bumperTop = -size.y * 0.18 + max(size.y * 0.82, 0.020) * 0.5
            let rootX = size.x * 0.34
            let rootZ = size.z * 0.34
            return WorkbenchLandingGearAttachmentLayout(
                upperLocalY: bumperTop,
                rootPoints: [
                    SIMD3<Float>(-rootX, bumperTop, -rootZ),
                    SIMD3<Float>(-rootX, bumperTop, rootZ),
                    SIMD3<Float>(rootX, bumperTop, -rootZ),
                    SIMD3<Float>(rootX, bumperTop, rootZ),
                ])
        }

        if spec.id.contains("retractable") {
            let pivotTop = size.y * 0.27 + size.z * 0.16
            let rootX = size.x * 0.31
            return WorkbenchLandingGearAttachmentLayout(
                upperLocalY: pivotTop,
                rootPoints: [
                    SIMD3<Float>(-rootX, pivotTop, 0),
                    SIMD3<Float>(rootX, pivotTop, 0),
                ])
        }

        // Both the conventional skid and Tall Carbon Gear share the rendered
        // four-strut layout. These are the actual upper beam endpoints.
        let rootX = size.x * 0.34
        let rootY = size.y * 0.45
        let rootZ = size.z * 0.13
        return WorkbenchLandingGearAttachmentLayout(
            upperLocalY: rootY,
            rootPoints: [
                SIMD3<Float>(-rootX, rootY, -rootZ),
                SIMD3<Float>(-rootX, rootY, rootZ),
                SIMD3<Float>(rootX, rootY, -rootZ),
                SIMD3<Float>(rootX, rootY, rootZ),
            ])
    }

    /// Seats repeated wing servos on the actual skin instead of trusting
    /// legacy anchors whose Y value could leave a body half embedded in the
    /// wing (or suspended above the tail). X/Z remain the authored control-
    /// surface positions and coincident anchors are separated deterministically.
    static func resolvedServoPositions(
        frame: WorkbenchResolvedFrame,
        spec: WorkbenchComponentSpec
    ) -> [SIMD3<Float>] {
        let size = spec.proxy.size.simdFloat
        let clearance: Float = 0.005
        var result: [SIMD3<Float>] = []

        let span = max(Float(frame.sizeMeters.x), 0.45)
        let length = max(Float(frame.sizeMeters.z), 0.36)
        let referenceArea = max(Float(frame.wingAreaM2), span * length * 0.18)
        let meanChord = min(max(referenceArea / span, length * 0.20), length * 0.52)
        let wingThickness = min(max(meanChord * 0.055, 0.010), 0.024)
        let tailThickness = max(wingThickness * 0.58, 0.006)
        let flangeThickness: Float = 0.0015

        func overlaps(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Bool {
            abs(lhs.x - rhs.x) < size.x + clearance
                && abs(lhs.z - rhs.z) < size.z + clearance
                && abs(lhs.y - rhs.y) < size.y + clearance
        }

        for (index, anchor) in frame.servoMounts.enumerated() {
            let isTailBay = anchor.z < -length * 0.22 && abs(anchor.x) < span * 0.18
            let skinTop = (isTailBay ? tailThickness : wingThickness) * 0.5
            var candidate = SIMD3<Float>(
                anchor.x,
                // Recess the case into the servo pocket. Only the flange,
                // horn and pushrod remain above the aerodynamic skin.
                skinTop - size.y * 0.5 + flangeThickness * 0.45,
                anchor.z)
            var attempt = 0
            while result.contains(where: { overlaps(candidate, $0) }), attempt < 12 {
                attempt += 1
                let ring = Float((attempt + 1) / 2)
                let side: Float = attempt.isMultiple(of: 2) ? 1 : -1
                candidate.x = anchor.x + side * ring * (size.x + clearance)
                candidate.z = anchor.z + Float(attempt / 4) * (size.z + clearance)
            }
            if attempt == 12 && result.contains(where: { overlaps(candidate, $0) }) {
                candidate.x += Float(index + 1) * (size.x + clearance)
            }
            result.append(candidate)
        }
        return result
    }

    /// Resolves every installed module as one layout so neighbouring physical
    /// envelopes can be separated. The result is deterministic, persisted
    /// mounting intent remains honoured, and the same positions are consumed
    /// by mass analysis, the editor and simulation rendering.
    static func resolvedComponentLayout(
        for build: WorkbenchBuild
    ) -> [WorkbenchComponentKind: WorkbenchResolvedComponentPlacement] {
        let frame = build.resolvedFrame
        let support = mountingEnvelope(for: frame)
        let bodyWidth = support.width
        let bodyLength = support.length
        let frameHeight = Float(max(frame.sizeMeters.y, 0.025))
        let deckTop = support.top
        let deckBottom = support.bottom
        let gap: Float = frame.frameClass == .tinyWhoop ? 0.0018 : 0.0035
        let isLiftingAirframe = frame.architecture != .multicopter
        let span = max(Float(frame.sizeMeters.x), 0.08)
        let aircraftLength = max(Float(frame.sizeMeters.z), bodyLength)
        let referenceArea = max(Float(frame.wingAreaM2), span * aircraftLength * 0.18)
        let meanChord = isLiftingAirframe
            ? min(max(referenceArea / max(span, 0.01), aircraftLength * 0.20), aircraftLength * 0.52)
            : bodyLength
        let wingThickness = isLiftingAirframe
            ? min(max(meanChord * 0.055, 0.010), 0.024)
            : 0

        struct Envelope {
            var min: SIMD3<Float>
            var max: SIMD3<Float>

            func intersects(_ other: Envelope, clearance: Float) -> Bool {
                min.x < other.max.x + clearance && max.x > other.min.x - clearance
                    && min.y < other.max.y + clearance && max.y > other.min.y - clearance
                    && min.z < other.max.z + clearance && max.z > other.min.z - clearance
            }
        }

        func envelope(at position: SIMD3<Float>, size: SIMD3<Float>) -> Envelope {
            let half = size * 0.5
            return Envelope(min: position - half, max: position + half)
        }

        /// Recognizable renderers extend beyond their catalog body proxy.
        /// Reserve only geometry that is physically attached to that body;
        /// routed battery/RX wiring has its own clipped path and must not push
        /// an otherwise internal module outside the fuselage.
        func collisionEnvelope(
            for kind: WorkbenchComponentKind,
            at position: SIMD3<Float>,
            size: SIMD3<Float>
        ) -> Envelope {
            var result = envelope(at: position, size: size)
            switch kind {
            case .battery:
                // Two retention straps sit slightly above the pack. The former
                // long-Z reservation represented loose leads, which no longer
                // exist now that the assembly owns a routed power harness.
                result.max.y += 0.002
            case .receiver:
                // Only the protected RX body occupies the bay. Antennas are
                // routed independently through clips along the frame/wing.
                result.min.x -= 0.002
                result.max.x += 0.002
            case .camera:
                result.max.z += max(size.z * 0.58, 0.006)
                result.min.x -= 0.003
                result.max.x += 0.003
            case .servo:
                result.min.x -= size.x * 0.14
                result.max.x += size.x * 0.38
                result.max.y += 0.005
            case .gps:
                result.max.y += 0.006
            default:
                break
            }
            return result
        }

        func automaticSurface(
            for kind: WorkbenchComponentKind,
            spec: WorkbenchComponentSpec,
            size: SIMD3<Float>
        ) -> WorkbenchMountSurface {
            let identity = "\(spec.id) \(spec.displayName)".lowercased()
            if isLiftingAirframe {
                switch kind {
                // Real fixed-wing and lift+cruise builds keep power and radio
                // electronics inside the fuselage under an access hatch.
                case .battery, .esc, .flightController, .receiver:
                    return .internalBay
                case .servo:
                    return .internalBay
                case .gps:
                    // PX4/ArduPilot require an unobstructed upper GNSS zone;
                    // it belongs on the wing/fuselage top, never underneath.
                    return .top
                case .camera:
                    return identity.contains("mapping") ? .bottom : .front
                case .payload, .landingGear:
                    return .bottom
                case .sensor:
                    if identity.contains("obstacle-array") || identity.contains("360") {
                        return .top
                    }
                    if identity.contains("radar") || identity.contains("flow")
                        || identity.contains("range") || identity.contains("altimeter") {
                        return .bottom
                    }
                    return size.x > bodyWidth * 0.72 ? .bottom : .internalBay
                case .motor, .propeller:
                    return .automatic
                }
            }

            switch kind {
            case .battery: return .top
            case .esc, .flightController, .receiver: return .internalBay
            case .servo: return .internalBay
            case .camera: return .front
            case .gps: return .top
            case .payload, .landingGear: return .bottom
            case .sensor:
                if identity.contains("obstacle-array") || identity.contains("360") {
                    return .top
                }
                if identity.contains("radar") || identity.contains("flow")
                    || identity.contains("range") || identity.contains("altimeter") {
                    return .bottom
                }
                if identity.contains("obstacle") { return .front }
                if identity.contains("air quality") { return .top }
                return .top
            case .motor, .propeller: return .automatic
            }
        }

        func basePosition(
            for kind: WorkbenchComponentKind,
            surface: WorkbenchMountSurface,
            size: SIMD3<Float>
        ) -> SIMD3<Float> {
            let half = size * 0.5

            if isLiftingAirframe {
                switch surface {
                case .internalBay:
                    // Longitudinal functional bays: ESC near the motor, FC at
                    // CoG, battery on the CoG adjustment rail, RX aft in an RF
                    // quiet pocket.  Vertical offsets create two supported
                    // shelves without placing anything on the fuselage skin.
                    let bayCenterY = (deckTop + deckBottom) * 0.5
                    let z: Float
                    let y: Float
                    switch kind {
                    case .esc:
                        z = bodyLength * 0.29
                        y = bayCenterY - bodyWidth * 0.10
                    case .flightController:
                        z = bodyLength * 0.075
                        y = bayCenterY + bodyWidth * 0.12
                    case .battery:
                        z = -bodyLength * 0.105
                        y = deckBottom + half.y + gap * 1.3
                    case .receiver:
                        z = -bodyLength * 0.33
                        y = bayCenterY + bodyWidth * 0.02
                    case .sensor:
                        z = -bodyLength * 0.22
                        y = bayCenterY
                    default:
                        z = frame.fcBay.z
                        y = bayCenterY
                    }
                    return SIMD3<Float>(0, y, z)

                case .top, .automatic:
                    if kind == .gps {
                        // A single pad on the wing keeps GNSS clear of the
                        // battery/current loop while preserving sky view.
                        let side: Float = frame.architecture == .liftCruiseVTOL ? -1 : 1
                        return SIMD3<Float>(
                            side * min(span * 0.22, 0.34),
                            wingThickness * 0.5 + half.y + gap,
                            -aircraftLength * 0.015)
                    }
                    return SIMD3<Float>(0, deckTop + half.y + gap, frame.fcBay.z)

                case .bottom:
                    let z: Float
                    switch kind {
                    case .camera: z = aircraftLength * 0.18
                    case .sensor: z = aircraftLength * 0.02
                    case .payload: z = -aircraftLength * 0.06
                    default: z = frame.fcBay.z
                    }
                    return SIMD3<Float>(0, deckBottom - half.y - gap, z)

                case .front:
                    return SIMD3<Float>(
                        frame.cameraMount.x,
                        frame.cameraMount.y,
                        support.frontZ + half.z + gap)
                case .rear:
                    return SIMD3<Float>(0, 0, support.rearZ - half.z - gap)
                case .left:
                    return SIMD3<Float>(-bodyWidth * 0.5 - half.x - gap, 0, 0)
                case .right:
                    return SIMD3<Float>(bodyWidth * 0.5 + half.x + gap, 0, 0)
                }
            }

            switch surface {
            case .internalBay:
                // Open-frame central stack. ESC is the lower tier, FC is on
                // four damped standoffs, RX occupies the protected rear tier.
                let interiorBottom = deckBottom + gap
                switch kind {
                case .esc:
                    return SIMD3<Float>(frame.fcBay.x, interiorBottom + half.y, frame.fcBay.z)
                case .flightController:
                    return SIMD3<Float>(frame.fcBay.x, interiorBottom + half.y + 0.010, frame.fcBay.z)
                case .receiver:
                    return SIMD3<Float>(0, interiorBottom + half.y + 0.002, -bodyLength * 0.34)
                default:
                    return SIMD3<Float>(frame.fcBay.x, interiorBottom + half.y, frame.fcBay.z)
                }
            case .top, .automatic:
                var x = frame.fcBay.x
                var z = frame.fcBay.z
                if kind == .battery {
                    x = frame.batteryTray.x
                    z = frame.batteryTray.z
                }
                if kind == .gps { z -= bodyLength * 0.38 }
                let mastClearance = kind == .gps
                    ? max(0.014, size.x * 0.18)
                    : gap
                return SIMD3<Float>(x, deckTop + half.y + mastClearance, z)
            case .bottom:
                var x = frame.fcBay.x
                if kind == .sensor { x = bodyWidth * 0.22 }
                let z = kind == .battery ? frame.batteryTray.z : frame.fcBay.z
                return SIMD3<Float>(x, deckBottom - half.y - gap, z)
            case .front:
                return SIMD3<Float>(
                    frame.cameraMount.x,
                    max(frame.cameraMount.y, deckTop + half.y),
                    max(frame.cameraMount.z, support.frontZ + half.z + gap))
            case .rear:
                return SIMD3<Float>(0, deckTop + half.y, support.rearZ - half.z - gap)
            case .left:
                return SIMD3<Float>(-bodyWidth * 0.5 - half.x - gap, deckTop + half.y, 0)
            case .right:
                return SIMD3<Float>(bodyWidth * 0.5 + half.x + gap, deckTop + half.y, 0)
            }
        }

        func candidateOffsets(
            for surface: WorkbenchMountSurface,
            kind: WorkbenchComponentKind
        ) -> [SIMD3<Float>] {
            // GNSS remains on one rigid upper mast. If the battery occupies
            // the rear roof, the collision solver raises this same mast
            // rather than inventing a second cantilevering frame.
            if kind == .gps, surface == .top { return [.zero] }
            if kind == .flightController || kind == .esc {
                return surface == .internalBay
                    ? [.zero, SIMD3<Float>(0, 0, bodyLength * 0.18)]
                    : [.zero]
            }
            switch surface {
            case .internalBay:
                return [
                    .zero,
                    SIMD3<Float>(0, 0, -bodyLength * 0.18),
                    SIMD3<Float>(0, 0, bodyLength * 0.18),
                    SIMD3<Float>(0, 0, -bodyLength * 0.34),
                    SIMD3<Float>(0, 0, bodyLength * 0.34),
                    SIMD3<Float>(-bodyWidth * 0.18, 0, 0),
                    SIMD3<Float>(bodyWidth * 0.18, 0, 0),
                ]
            case .top, .bottom, .automatic:
                return [
                    .zero,
                    SIMD3<Float>(0, 0, -bodyLength * 0.36),
                    SIMD3<Float>(0, 0, bodyLength * 0.36),
                    SIMD3<Float>(-bodyWidth * 0.42, 0, 0),
                    SIMD3<Float>(bodyWidth * 0.42, 0, 0),
                    SIMD3<Float>(-bodyWidth * 0.38, 0, -bodyLength * 0.30),
                    SIMD3<Float>(bodyWidth * 0.38, 0, -bodyLength * 0.30),
                ]
            case .front, .rear:
                return [
                    .zero,
                    SIMD3<Float>(-bodyWidth * 0.42, 0, 0),
                    SIMD3<Float>(bodyWidth * 0.42, 0, 0),
                    SIMD3<Float>(0, frameHeight * 0.55, 0),
                ]
            case .left, .right:
                return [
                    .zero,
                    SIMD3<Float>(0, 0, -bodyLength * 0.35),
                    SIMD3<Float>(0, 0, bodyLength * 0.35),
                    SIMD3<Float>(0, frameHeight * 0.55, 0),
                ]
            }
        }

        let order: [WorkbenchComponentKind] = [
            .esc, .flightController, .battery, .servo, .receiver,
            .gps, .camera, .sensor, .payload, .landingGear,
        ]
        var result: [WorkbenchComponentKind: WorkbenchResolvedComponentPlacement] = [:]
        var occupied: [(WorkbenchComponentKind, Envelope)] = []

        // Repeated control-surface servos are installed components too;
        // generic GPS/sensor/camera bays must route around their full horns.
        if let servo = build.spec(for: .servo), !frame.servoMounts.isEmpty {
            let servoSize = SIMD3<Float>(
                max(Float(servo.proxy.size.x), 0.004),
                max(Float(servo.proxy.size.y), 0.003),
                max(Float(servo.proxy.size.z), 0.004))
            for position in resolvedServoPositions(frame: frame, spec: servo) {
                occupied.append((
                    .servo,
                    collisionEnvelope(for: .servo, at: position, size: servoSize)))
            }
        }

        for kind in order {
            guard let spec = build.spec(for: kind) else { continue }
            // Wing templates repeat the selected servo at explicit control-
            // surface mounts; they are not a single avionics brick on deck.
            if kind == .servo, !frame.servoMounts.isEmpty { continue }
            let requested = build.placement(for: kind)
            // Proxy dimensions describe catalog data, while a few recognizable
            // renderers intentionally change orientation.  The resolver must
            // use the rendered envelope or an apparently collision-free layout
            // can still interpenetrate in SceneKit (LiPo length is fore/aft).
            let renderedSize: SIMD3<Float>
            if kind == .battery {
                renderedSize = SIMD3<Float>(
                    Float(spec.proxy.size.z),
                    Float(spec.proxy.size.y),
                    Float(spec.proxy.size.x))
            } else {
                renderedSize = spec.proxy.size.simdFloat
            }
            let size = SIMD3<Float>(
                max(renderedSize.x, 0.004),
                max(renderedSize.y, 0.003),
                max(renderedSize.z, 0.004))
            let automatic = automaticSurface(for: kind, spec: spec, size: size)
            let surface: WorkbenchMountSurface
            if requested.surface == .automatic {
                surface = automatic
            } else if kind == .gps {
                // A legacy Blueprint may still request a bottom/side GNSS
                // shelf. Never honour it: GNSS needs a clear upper sky view.
                surface = .top
            } else if isLiftingAirframe,
                      [.battery, .esc, .flightController, .receiver, .servo].contains(kind) {
                // Fixed-wing avionics and the movable CG battery belong under
                // the service hatch, not on top of the aerodynamic surface.
                surface = .internalBay
            } else if kind == .landingGear {
                // Landing gear has one meaningful mounting face. Normalizing
                // legacy Blueprints prevents a valid gear assembly being
                // attached to the roof or a side of the aircraft.
                surface = .bottom
            } else if kind == .receiver || kind == .flightController || kind == .esc {
                surface = .internalBay
            } else {
                surface = requested.surface
            }
            let offset = requested.offset.simdFloat
            var base = basePosition(for: kind, surface: surface, size: size) + offset
            if kind == .landingGear, surface == .bottom {
                let attachments = landingGearAttachmentLayout(for: spec)
                // Seat the visible upper hard-points just below the real belly.
                // The small remaining service gap is bridged by explicit pads
                // and braces in WorkbenchModelBuilder.
                base.y = deckBottom - gap - attachments.upperLocalY + offset.y
            }
            var chosen: SIMD3<Float>?

            // Landing gear is an enclosing structure with an intentionally
            // empty centre; treating its full proxy as solid would push it
            // through the table whenever a bottom payload is installed.
            let checksSolidEnvelope = kind != .landingGear
            for candidateOffset in candidateOffsets(for: surface, kind: kind) {
                let candidate = base + candidateOffset
                let candidateEnvelope = collisionEnvelope(
                    for: kind, at: candidate, size: size)
                if !checksSolidEnvelope || !occupied.contains(where: {
                    candidateEnvelope.intersects($0.1, clearance: gap)
                }) {
                    chosen = candidate
                    break
                }
            }

            var position = chosen ?? base
            if chosen == nil && checksSolidEnvelope {
                // Preserve the requested face and create a real air gap rather
                // than allowing an unresolved overlap. Side/front mounts move
                // outward; top and bottom mounts form a supported vertical tier.
                for _ in 0..<occupied.count + 2 {
                    let current = collisionEnvelope(
                        for: kind, at: position, size: size)
                    guard let conflict = occupied.first(where: {
                        current.intersects($0.1, clearance: gap)
                    })?.1 else { break }
                    switch surface {
                    case .internalBay:
                        // Interior conflicts are resolved along the fuselage/
                        // stack axis, never by pushing a module through skin.
                        let direction: Float = position.z <= 0 ? -1 : 1
                        position.z += direction * (
                            max(current.max.z - current.min.z, 0.010) + gap)
                    case .bottom:
                        position.y += conflict.min.y - gap - current.max.y
                    case .front:
                        position.z += conflict.max.z + gap - current.min.z
                    case .rear:
                        position.z += conflict.min.z - gap - current.max.z
                    case .left:
                        position.x += conflict.min.x - gap - current.max.x
                    case .right:
                        position.x += conflict.max.x + gap - current.min.x
                    case .top, .automatic:
                        position.y += conflict.max.y + gap - current.min.y
                    }
                }
            }

            let placement = WorkbenchResolvedComponentPlacement(
                kind: kind, surface: surface, position: position, size: size)
            result[kind] = placement
            if checksSolidEnvelope {
                occupied.append((
                    kind,
                    collisionEnvelope(for: kind, at: position, size: size)))
            }
        }
        return result
    }

    /// Component centres after their full physical extents have been seated on
    /// or suspended below the frame. Shared by mass analysis and 3D placement.
    static func resolvedSlotPosition(
        _ kind: WorkbenchComponentKind,
        spec: WorkbenchComponentSpec,
        frame: WorkbenchResolvedFrame
    ) -> SIMD3<Float> {
        var position = slotPosition(kind, frame: frame)
        switch kind {
        case .battery:
            position.y = max(position.y, Float(spec.proxy.size.y) * 0.5 + 0.010)
        case .payload:
            position.y = min(position.y, -Float(spec.proxy.size.y) * 0.5 - 0.010)
        case .landingGear:
            let support = mountingEnvelope(for: frame)
            let gap: Float = frame.frameClass == .tinyWhoop ? 0.0018 : 0.0035
            position.y = support.bottom - gap
                - landingGearAttachmentLayout(for: spec).upperLocalY
        default:
            break
        }
        return position
    }
}
