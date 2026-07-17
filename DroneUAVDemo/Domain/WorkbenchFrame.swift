import Foundation
import simd

/// High-level vehicle layout used by the Workbench, compatibility analysis,
/// runtime profile synthesis, and procedural renderer. Keep this separate
/// from `WorkbenchFrameClass`: architecture describes how the aircraft flies,
/// while frame class describes the visual/mechanical family.
enum WorkbenchVehicleArchitecture: String, Codable, CaseIterable, Hashable {
    case multicopter
    case fixedWing
    case liftCruiseVTOL

    var displayName: String {
        switch self {
        case .multicopter: return "Мультиротор"
        case .fixedWing: return "Самолёт"
        case .liftCruiseVTOL: return "Lift + Cruise VTOL"
        }
    }
}

enum WorkbenchFrameClass: String, Codable, CaseIterable, Hashable {
    case tinyWhoop
    case fiveInch
    case sevenInch
    case cinematic
    case fixedWing
    case vtol

    var displayName: String {
        switch self {
        case .tinyWhoop: return "Tiny Whoop"
        case .fiveInch: return "5\" фристайл"
        case .sevenInch: return "7\" дальнолёт"
        case .cinematic: return "Cinematic"
        case .fixedWing: return "Самолётная"
        case .vtol: return "VTOL"
        }
    }
}

/// A frame from the built-in library: defines the mount slots (motor arms,
/// battery tray, FC bay, camera) that equipment snaps into, plus the size
/// and mass that drive physics. Geometry is built procedurally by
/// `WorkbenchModelBuilder` from `motorMounts` + `armLengthM`.
struct WorkbenchFrameSpec: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var frameClass: WorkbenchFrameClass
    var architecture: WorkbenchVehicleArchitecture
    var armCount: Int
    var motorMounts: [CodableVector3D] // frame space, metres
    /// Unit thrust axes matching `motorMounts`: +Y is vertical lift and +Z is
    /// forward in Workbench model space. Missing legacy values are resolved
    /// from `architecture`.
    var propulsionAxes: [CodableVector3D]
    /// Number of leading propulsion mounts that contribute direct vertical
    /// lift. A fixed-wing tractor/pusher therefore has zero lift motors.
    var liftMotorCount: Int
    /// Repeated mounting points for the selected servo model. Fixed-wing and
    /// VTOL templates use these for aileron/elevator/rudder actuators.
    var servoMounts: [CodableVector3D]
    /// Reference wing planform area. Zero for aircraft without lifting wings.
    var wingAreaM2: Double
    var armLengthM: Double
    var propMaxInch: Double
    var motorStatorMaxMm: Double
    var batteryTray: CodableVector3D
    var fcBay: CodableVector3D
    var cameraMount: CodableVector3D
    var massKg: Double
    var sizeMeters: CodableVector3D

    init(
        id: String,
        name: String,
        frameClass: WorkbenchFrameClass,
        architecture: WorkbenchVehicleArchitecture = .multicopter,
        armCount: Int,
        motorMounts: [CodableVector3D],
        propulsionAxes: [CodableVector3D] = [],
        liftMotorCount: Int? = nil,
        servoMounts: [CodableVector3D] = [],
        wingAreaM2: Double = 0,
        armLengthM: Double,
        propMaxInch: Double,
        motorStatorMaxMm: Double,
        batteryTray: CodableVector3D,
        fcBay: CodableVector3D,
        cameraMount: CodableVector3D,
        massKg: Double,
        sizeMeters: CodableVector3D
    ) {
        self.id = id
        self.name = name
        self.frameClass = frameClass
        self.architecture = architecture
        self.armCount = armCount
        self.motorMounts = motorMounts
        self.propulsionAxes = propulsionAxes
        self.liftMotorCount = max(
            0,
            min(liftMotorCount ?? (architecture == .fixedWing ? 0 : motorMounts.count),
                motorMounts.count)
        )
        self.servoMounts = servoMounts
        self.wingAreaM2 = max(wingAreaM2, 0)
        self.armLengthM = armLengthM
        self.propMaxInch = propMaxInch
        self.motorStatorMaxMm = motorStatorMaxMm
        self.batteryTray = batteryTray
        self.fcBay = fcBay
        self.cameraMount = cameraMount
        self.massKg = massKg
        self.sizeMeters = sizeMeters
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, frameClass, architecture, armCount, motorMounts
        case propulsionAxes, liftMotorCount, servoMounts, wingAreaM2
        case armLengthM, propMaxInch, motorStatorMaxMm
        case batteryTray, fcBay, cameraMount, massKg, sizeMeters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        frameClass = try c.decode(WorkbenchFrameClass.self, forKey: .frameClass)
        architecture = try c.decodeIfPresent(
            WorkbenchVehicleArchitecture.self,
            forKey: .architecture
        ) ?? .multicopter
        armCount = try c.decodeIfPresent(Int.self, forKey: .armCount) ?? 0
        motorMounts = try c.decodeIfPresent(
            [CodableVector3D].self,
            forKey: .motorMounts
        ) ?? []
        propulsionAxes = try c.decodeIfPresent(
            [CodableVector3D].self,
            forKey: .propulsionAxes
        ) ?? []
        let defaultLiftCount = architecture == .fixedWing ? 0 : motorMounts.count
        liftMotorCount = max(
            0,
            min(try c.decodeIfPresent(Int.self, forKey: .liftMotorCount) ?? defaultLiftCount,
                motorMounts.count)
        )
        servoMounts = try c.decodeIfPresent(
            [CodableVector3D].self,
            forKey: .servoMounts
        ) ?? []
        wingAreaM2 = max(try c.decodeIfPresent(Double.self, forKey: .wingAreaM2) ?? 0, 0)
        armLengthM = try c.decodeIfPresent(Double.self, forKey: .armLengthM) ?? 0
        propMaxInch = try c.decodeIfPresent(Double.self, forKey: .propMaxInch) ?? 0
        motorStatorMaxMm = try c.decodeIfPresent(Double.self, forKey: .motorStatorMaxMm) ?? 0
        batteryTray = try c.decodeIfPresent(CodableVector3D.self, forKey: .batteryTray)
            ?? CodableVector3D(x: 0, y: 0, z: 0)
        fcBay = try c.decodeIfPresent(CodableVector3D.self, forKey: .fcBay)
            ?? CodableVector3D(x: 0, y: 0, z: 0)
        cameraMount = try c.decodeIfPresent(CodableVector3D.self, forKey: .cameraMount)
            ?? CodableVector3D(x: 0, y: 0, z: 0)
        massKg = max(try c.decodeIfPresent(Double.self, forKey: .massKg) ?? 0, 0)
        sizeMeters = try c.decodeIfPresent(CodableVector3D.self, forKey: .sizeMeters)
            ?? CodableVector3D(x: 0.1, y: 0.1, z: 0.1)
    }
}

/// Where a build's frame comes from: the built-in library or an imported
/// CADNext assembly (baked geometry + mount points from attachment points).
enum WorkbenchFrameSource: Codable, Hashable {
    case library(id: String)
    case imported(WorkbenchConstruction)
}

/// A frame resolved to the uniform data the analyzer, model builder and
/// synthesizer consume — regardless of whether it is a library frame or an
/// imported CADNext airframe.
struct WorkbenchResolvedFrame: Hashable {
    var name: String
    var frameClass: WorkbenchFrameClass
    var architecture: WorkbenchVehicleArchitecture
    var motorMounts: [SIMD3<Float>]
    var propulsionAxes: [SIMD3<Float>]
    var liftMotorCount: Int
    var servoMounts: [SIMD3<Float>]
    var wingAreaM2: Double
    var armLengthM: Double
    var propMaxInch: Double
    var motorStatorMaxMm: Double
    var batteryTray: SIMD3<Float>
    var fcBay: SIMD3<Float>
    var cameraMount: SIMD3<Float>
    var massKg: Double
    var sizeMeters: SIMD3<Double>
    /// Present for imported CADNext frames (rendered as-is); nil for library
    /// frames (procedural geometry).
    var importedMesh: WorkbenchConstruction.Mesh?
}

extension WorkbenchFrameSource {
    func resolve(
        architecture preferredArchitecture: WorkbenchVehicleArchitecture? = nil
    ) -> WorkbenchResolvedFrame {
        switch self {
        case let .library(id):
            let spec = WorkbenchFrameLibrary.spec(id: id) ?? WorkbenchFrameLibrary.defaultFrame
            // Library geometry and propulsion mount axes are authored as one
            // coherent airframe. Its architecture is therefore authoritative;
            // only imported CAD frames may be assigned an architecture at
            // runtime by the user.
            let architecture = spec.architecture
            return WorkbenchResolvedFrame(
                name: spec.name,
                frameClass: spec.frameClass,
                architecture: architecture,
                motorMounts: spec.motorMounts.map { $0.simdFloat },
                propulsionAxes: resolvedPropulsionAxes(
                    spec.propulsionAxes.map { $0.simdFloat },
                    mountCount: spec.motorMounts.count,
                    architecture: architecture,
                    liftMotorCount: spec.liftMotorCount),
                liftMotorCount: min(spec.liftMotorCount, spec.motorMounts.count),
                servoMounts: spec.servoMounts.map { $0.simdFloat },
                wingAreaM2: spec.wingAreaM2,
                armLengthM: spec.armLengthM,
                propMaxInch: spec.propMaxInch,
                motorStatorMaxMm: spec.motorStatorMaxMm,
                batteryTray: spec.batteryTray.simdFloat,
                fcBay: spec.fcBay.simdFloat,
                cameraMount: spec.cameraMount.simdFloat,
                massKg: spec.massKg,
                sizeMeters: spec.sizeMeters.simd,
                importedMesh: nil)
        case let .imported(construction):
            let architecture = preferredArchitecture ?? .multicopter
            // CADNext exports Z-up coordinates; SceneKit uses Y-up. Keep one
            // conversion here for all snap points and convert the mesh in the
            // model builder with the same mapping: (x, y, z) -> (x, z, -y).
            let motorPoints = construction.attachmentPoints
                .filter { $0.resolvedRole == .motor }
                .map { cadToScene($0.position.simdFloat) }
            let battery = construction.attachmentPoints.first { $0.resolvedRole == .battery }
            let camera = construction.attachmentPoints.first { $0.resolvedRole == .camera }
            let cadDims = construction.dimensionsMeters
            let dims = SIMD3<Double>(cadDims.x, cadDims.z, cadDims.y)
            let armLen = max(cadDims.x, cadDims.y) * 0.5
            let mounts = motorPoints.isEmpty
                ? defaultMotorMounts(
                    architecture: architecture,
                    arm: Float(max(armLen, 0.1)),
                    dimensions: dims)
                : motorPoints
            let propMax = max(1.6, armLen * 39.37 * 0.92)
            let inferredClass: WorkbenchFrameClass
            switch architecture {
            case .fixedWing:
                inferredClass = .fixedWing
            case .liftCruiseVTOL:
                inferredClass = .vtol
            case .multicopter:
                if propMax <= 2.0 {
                    inferredClass = .tinyWhoop
                } else if propMax <= 5.8 {
                    inferredClass = .fiveInch
                } else if propMax <= 8.2 {
                    inferredClass = .sevenInch
                } else {
                    inferredClass = .cinematic
                }
            }
            let liftMotorCount = architecture == .fixedWing
                ? 0
                : architecture == .liftCruiseVTOL ? max(mounts.count - 1, 0) : mounts.count
            return WorkbenchResolvedFrame(
                name: construction.name.isEmpty ? "Импортированная рама" : construction.name,
                frameClass: inferredClass,
                architecture: architecture,
                motorMounts: mounts,
                propulsionAxes: resolvedPropulsionAxes(
                    [], mountCount: mounts.count, architecture: architecture,
                    liftMotorCount: liftMotorCount),
                liftMotorCount: liftMotorCount,
                servoMounts: defaultServoMounts(
                    architecture: architecture,
                    dimensions: dims),
                wingAreaM2: architecture == .multicopter
                    ? 0
                    : max(dims.x * dims.z * 0.34, 0.03),
                armLengthM: armLen,
                propMaxInch: propMax,
                motorStatorMaxMm: propMax <= 2 ? 10 : propMax <= 6 ? 32 : 55,
                batteryTray: battery.map { cadToScene($0.position.simdFloat) }
                    ?? SIMD3<Float>(0, Float(max(dims.y * 0.18, 0.02)), 0),
                fcBay: SIMD3<Float>(0, 0, 0),
                cameraMount: camera.map { cadToScene($0.position.simdFloat) }
                    ?? SIMD3<Float>(0, 0.01, Float(dims.z) * 0.35),
                massKg: construction.massKg,
                sizeMeters: dims,
                importedMesh: construction.mesh.isRenderable ? construction.mesh : nil)
        }
    }

    private func defaultQuadMounts(arm: Float) -> [SIMD3<Float>] {
        let a = arm * 0.7071
        return [SIMD3(a, 0, a), SIMD3(-a, 0, a), SIMD3(-a, 0, -a), SIMD3(a, 0, -a)]
    }

    private func defaultMotorMounts(
        architecture: WorkbenchVehicleArchitecture,
        arm: Float,
        dimensions: SIMD3<Double>
    ) -> [SIMD3<Float>] {
        switch architecture {
        case .multicopter:
            return defaultQuadMounts(arm: arm)
        case .fixedWing:
            return [SIMD3<Float>(0, 0, Float(dimensions.z) * 0.46)]
        case .liftCruiseVTOL:
            let x = Float(max(dimensions.x * 0.30, Double(arm * 0.55)))
            let z = Float(max(dimensions.z * 0.22, Double(arm * 0.34)))
            return [
                SIMD3<Float>(-x, 0, z), SIMD3<Float>(x, 0, z),
                SIMD3<Float>(-x, 0, -z), SIMD3<Float>(x, 0, -z),
                SIMD3<Float>(0, 0, Float(dimensions.z) * 0.46),
            ]
        }
    }

    private func resolvedPropulsionAxes(
        _ explicit: [SIMD3<Float>],
        mountCount: Int,
        architecture: WorkbenchVehicleArchitecture,
        liftMotorCount: Int
    ) -> [SIMD3<Float>] {
        guard explicit.count == mountCount else {
            return (0..<mountCount).map { index in
                switch architecture {
                case .multicopter:
                    return SIMD3<Float>(0, 1, 0)
                case .fixedWing:
                    return SIMD3<Float>(0, 0, 1)
                case .liftCruiseVTOL:
                    return index < liftMotorCount
                        ? SIMD3<Float>(0, 1, 0)
                        : SIMD3<Float>(0, 0, 1)
                }
            }
        }
        return explicit.map { axis in
            let length = simd_length(axis)
            return length > 0.0001 ? axis / length : SIMD3<Float>(0, 1, 0)
        }
    }

    private func defaultServoMounts(
        architecture: WorkbenchVehicleArchitecture,
        dimensions: SIMD3<Double>
    ) -> [SIMD3<Float>] {
        guard architecture != .multicopter else { return [] }
        let halfSpan = Float(max(dimensions.x * 0.32, 0.08))
        let tail = -Float(max(dimensions.z * 0.34, 0.08))
        return [
            SIMD3<Float>(-halfSpan, 0, 0),
            SIMD3<Float>(halfSpan, 0, 0),
            SIMD3<Float>(0, 0, tail),
        ]
    }

    private func cadToScene(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(p.x, p.z, -p.y)
    }
}

enum WorkbenchFrameLibrary {
    static let all: [WorkbenchFrameSpec] = [
        tinyWhoop, whoop75, cineWhoop25, ultralight35,
        fiveInch, fiveInchRace, fiveInchDeadcat,
        longRangeSix, sevenInch, expeditionEight,
        cinematic, utilityTenInch,
        surveyFixedWing, liftCruiseVTOL,
    ]

    static func spec(id: String) -> WorkbenchFrameSpec? { all.first { $0.id == id } }

    static var defaultFrame: WorkbenchFrameSpec { fiveInch }

    private static func quadMounts(arm: Double) -> [CodableVector3D] {
        let a = arm * 0.7071
        return [
            CodableVector3D(x: a, y: 0, z: a), CodableVector3D(x: -a, y: 0, z: a),
            CodableVector3D(x: -a, y: 0, z: -a), CodableVector3D(x: a, y: 0, z: -a),
        ]
    }

    private static func radialMounts(count: Int, radius: Double) -> [CodableVector3D] {
        (0..<count).map { index in
            let angle = Double(index) / Double(count) * .pi * 2 + .pi / 6
            return CodableVector3D(
                x: cos(angle) * radius,
                y: 0,
                z: sin(angle) * radius)
        }
    }

    private static func deadcatMounts() -> [CodableVector3D] {
        [
            CodableVector3D(x: -0.090, y: 0, z: 0.090),
            CodableVector3D(x: 0.090, y: 0, z: 0.090),
            CodableVector3D(x: -0.104, y: 0, z: -0.066),
            CodableVector3D(x: 0.104, y: 0, z: -0.066),
        ]
    }

    static let fiveInch = WorkbenchFrameSpec(
        id: "frame-5inch-freestyle", name: "5\" фристайл-рама", frameClass: .fiveInch,
        armCount: 4, motorMounts: quadMounts(arm: 0.11), armLengthM: 0.11,
        propMaxInch: 5.1, motorStatorMaxMm: 24,
        batteryTray: CodableVector3D(x: 0, y: 0.02, z: 0),
        fcBay: CodableVector3D(x: 0, y: 0.006, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.012, z: 0.05),
        massKg: 0.11, sizeMeters: CodableVector3D(x: 0.22, y: 0.05, z: 0.22))

    static let fiveInchRace = WorkbenchFrameSpec(
        id: "frame-5inch-race", name: "Aero R5 гоночная", frameClass: .fiveInch,
        armCount: 4, motorMounts: quadMounts(arm: 0.105), armLengthM: 0.105,
        propMaxInch: 5.1, motorStatorMaxMm: 24,
        batteryTray: CodableVector3D(x: 0, y: 0.018, z: -0.010),
        fcBay: CodableVector3D(x: 0, y: 0.006, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.010, z: 0.052),
        massKg: 0.082, sizeMeters: CodableVector3D(x: 0.21, y: 0.045, z: 0.21))

    static let fiveInchDeadcat = WorkbenchFrameSpec(
        id: "frame-5inch-deadcat", name: "Vista 5 Deadcat", frameClass: .fiveInch,
        armCount: 4, motorMounts: deadcatMounts(), armLengthM: 0.115,
        propMaxInch: 5.1, motorStatorMaxMm: 25,
        batteryTray: CodableVector3D(x: 0, y: 0.024, z: -0.012),
        fcBay: CodableVector3D(x: 0, y: 0.007, z: -0.004),
        cameraMount: CodableVector3D(x: 0, y: 0.015, z: 0.062),
        massKg: 0.134, sizeMeters: CodableVector3D(x: 0.23, y: 0.060, z: 0.21))

    static let longRangeSix = WorkbenchFrameSpec(
        id: "frame-6inch-longrange", name: "Nomad 6 — дальнолёт", frameClass: .sevenInch,
        armCount: 4, motorMounts: quadMounts(arm: 0.138), armLengthM: 0.138,
        propMaxInch: 6.1, motorStatorMaxMm: 28,
        batteryTray: CodableVector3D(x: 0, y: 0.025, z: -0.012),
        fcBay: CodableVector3D(x: 0, y: 0.007, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.014, z: 0.064),
        massKg: 0.142, sizeMeters: CodableVector3D(x: 0.276, y: 0.065, z: 0.276))

    static let sevenInch = WorkbenchFrameSpec(
        id: "frame-7inch-lr", name: "7\" дальнолёт-рама", frameClass: .sevenInch,
        armCount: 4, motorMounts: quadMounts(arm: 0.16), armLengthM: 0.16,
        propMaxInch: 7.1, motorStatorMaxMm: 30,
        batteryTray: CodableVector3D(x: 0, y: 0.028, z: 0),
        fcBay: CodableVector3D(x: 0, y: 0.008, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.016, z: 0.07),
        massKg: 0.16, sizeMeters: CodableVector3D(x: 0.32, y: 0.07, z: 0.32))

    static let expeditionEight = WorkbenchFrameSpec(
        id: "frame-8inch-expedition", name: "Expedition 8", frameClass: .sevenInch,
        armCount: 4, motorMounts: quadMounts(arm: 0.185), armLengthM: 0.185,
        propMaxInch: 8.1, motorStatorMaxMm: 36,
        batteryTray: CodableVector3D(x: 0, y: 0.034, z: -0.015),
        fcBay: CodableVector3D(x: 0, y: 0.009, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.019, z: 0.082),
        massKg: 0.245, sizeMeters: CodableVector3D(x: 0.37, y: 0.085, z: 0.37))

    static let tinyWhoop = WorkbenchFrameSpec(
        id: "frame-tinywhoop", name: "Tiny Whoop 65 мм", frameClass: .tinyWhoop,
        armCount: 4, motorMounts: quadMounts(arm: 0.031), armLengthM: 0.031,
        propMaxInch: 1.6, motorStatorMaxMm: 9,
        batteryTray: CodableVector3D(x: 0, y: 0.006, z: -0.01),
        fcBay: CodableVector3D(x: 0, y: 0.002, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.006, z: 0.015),
        massKg: 0.020, sizeMeters: CodableVector3D(x: 0.08, y: 0.03, z: 0.08))

    static let whoop75 = WorkbenchFrameSpec(
        id: "frame-whoop75", name: "Tiny Whoop 75 мм", frameClass: .tinyWhoop,
        armCount: 4, motorMounts: quadMounts(arm: 0.036), armLengthM: 0.036,
        propMaxInch: 1.9, motorStatorMaxMm: 11,
        batteryTray: CodableVector3D(x: 0, y: 0.007, z: -0.012),
        fcBay: CodableVector3D(x: 0, y: 0.003, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.007, z: 0.018),
        massKg: 0.026, sizeMeters: CodableVector3D(x: 0.095, y: 0.034, z: 0.095))

    static let cineWhoop25 = WorkbenchFrameSpec(
        id: "frame-cinewhoop-25", name: "CineWhoop 2.5", frameClass: .cinematic,
        armCount: 4, motorMounts: quadMounts(arm: 0.055), armLengthM: 0.055,
        propMaxInch: 2.6, motorStatorMaxMm: 16,
        batteryTray: CodableVector3D(x: 0, y: 0.020, z: -0.008),
        fcBay: CodableVector3D(x: 0, y: 0.006, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.014, z: 0.029),
        massKg: 0.069, sizeMeters: CodableVector3D(x: 0.13, y: 0.055, z: 0.13))

    static let ultralight35 = WorkbenchFrameSpec(
        id: "frame-35inch-ultralight", name: "Sparrow 3.5", frameClass: .fiveInch,
        armCount: 4, motorMounts: quadMounts(arm: 0.078), armLengthM: 0.078,
        propMaxInch: 3.6, motorStatorMaxMm: 20,
        batteryTray: CodableVector3D(x: 0, y: 0.017, z: -0.006),
        fcBay: CodableVector3D(x: 0, y: 0.005, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.010, z: 0.038),
        massKg: 0.052, sizeMeters: CodableVector3D(x: 0.156, y: 0.045, z: 0.156))

    static let cinematic = WorkbenchFrameSpec(
        id: "frame-cine", name: "Cinematic 6\"", frameClass: .cinematic,
        armCount: 4, motorMounts: quadMounts(arm: 0.135), armLengthM: 0.135,
        propMaxInch: 6.1, motorStatorMaxMm: 32,
        batteryTray: CodableVector3D(x: 0, y: 0.03, z: 0),
        fcBay: CodableVector3D(x: 0, y: 0.008, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.02, z: 0.06),
        massKg: 0.19, sizeMeters: CodableVector3D(x: 0.27, y: 0.08, z: 0.27))

    static let utilityTenInch = WorkbenchFrameSpec(
        id: "frame-10inch-utility", name: "Atlas X4 Utility", frameClass: .cinematic,
        armCount: 4, motorMounts: quadMounts(arm: 0.260), armLengthM: 0.260,
        propMaxInch: 10.1, motorStatorMaxMm: 55,
        batteryTray: CodableVector3D(x: 0, y: 0.050, z: 0),
        fcBay: CodableVector3D(x: 0, y: 0.012, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.035, z: 0.155),
        massKg: 0.680, sizeMeters: CodableVector3D(x: 0.52, y: 0.16, z: 0.52))

    /// Efficient hand/catapult-launch survey airframe. The single tractor
    /// power unit points along the aircraft's longitudinal axis; the three
    /// servo positions represent two ailerons and an elevator/rudder bay.
    static let surveyFixedWing = WorkbenchFrameSpec(
        id: "frame-fixedwing-survey-s1",
        name: "Surveyor S1",
        frameClass: .fixedWing,
        architecture: .fixedWing,
        armCount: 1,
        motorMounts: [CodableVector3D(x: 0, y: 0.015, z: 0.455)],
        propulsionAxes: [CodableVector3D(x: 0, y: 0, z: 1)],
        liftMotorCount: 0,
        servoMounts: [
            CodableVector3D(x: -0.480, y: 0.018, z: 0.015),
            CodableVector3D(x: 0.480, y: 0.018, z: 0.015),
            CodableVector3D(x: 0, y: 0.025, z: -0.345),
        ],
        wingAreaM2: 0.48,
        armLengthM: 0.455,
        propMaxInch: 12.0,
        motorStatorMaxMm: 52,
        batteryTray: CodableVector3D(x: 0, y: 0.055, z: -0.055),
        fcBay: CodableVector3D(x: 0, y: 0.040, z: 0.045),
        cameraMount: CodableVector3D(x: 0, y: -0.035, z: 0.315),
        massKg: 1.08,
        sizeMeters: CodableVector3D(x: 1.62, y: 0.19, z: 0.91))

    /// Lift+cruise mapping platform: four vertical lift motors followed by
    /// one forward cruise propulsor. Its ordering intentionally matches
    /// `liftMotorCount`, so old consumers can still iterate `motorMounts`.
    static let liftCruiseVTOL = WorkbenchFrameSpec(
        id: "frame-vtol-lift-cruise-v1",
        name: "Aquila LC-4",
        frameClass: .vtol,
        architecture: .liftCruiseVTOL,
        armCount: 5,
        motorMounts: [
            CodableVector3D(x: -0.455, y: 0.025, z: 0.205),
            CodableVector3D(x: 0.455, y: 0.025, z: 0.205),
            CodableVector3D(x: -0.455, y: 0.025, z: -0.205),
            CodableVector3D(x: 0.455, y: 0.025, z: -0.205),
            CodableVector3D(x: 0, y: 0.030, z: 0.485),
        ],
        propulsionAxes: [
            CodableVector3D(x: 0, y: 1, z: 0),
            CodableVector3D(x: 0, y: 1, z: 0),
            CodableVector3D(x: 0, y: 1, z: 0),
            CodableVector3D(x: 0, y: 1, z: 0),
            CodableVector3D(x: 0, y: 0, z: 1),
        ],
        liftMotorCount: 4,
        servoMounts: [
            CodableVector3D(x: -0.430, y: 0.020, z: -0.020),
            CodableVector3D(x: 0.430, y: 0.020, z: -0.020),
            CodableVector3D(x: 0, y: 0.028, z: -0.370),
        ],
        wingAreaM2: 0.43,
        armLengthM: 0.50,
        propMaxInch: 12.0,
        motorStatorMaxMm: 52,
        batteryTray: CodableVector3D(x: 0, y: 0.060, z: -0.075),
        fcBay: CodableVector3D(x: 0, y: 0.042, z: 0.015),
        cameraMount: CodableVector3D(x: 0, y: -0.045, z: 0.325),
        massKg: 1.54,
        sizeMeters: CodableVector3D(x: 1.48, y: 0.24, z: 1.02))
}
