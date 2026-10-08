import Foundation
import simd

enum InstructorLaunchMode {
    case flightCourse
    case appTour
}

enum TrainingAircraft: String {
    case copter, airplane, vtol, examination

    var profileID: String {
        switch self {
        case .copter, .examination: return "dji-matrice-350-rtk"
        case .airplane: return "sensefly-ebee-tac"
        case .vtol: return "quantum-systems-trinity-pro"
        }
    }

    var titleKey: String { "instructor.aircraft.\(rawValue)" }
}

enum FlightTrainingStep: String, CaseIterable {
    case copterIntro, flightPanel, arm, copterTakeoff, instruments, simulationPanels, copterManual
    case copterHover, cameraPanel, cameraView, missionMap, copterAutopilot, copterReturn
    case airplaneIntro, airplaneTakeoff, airplaneManual, airplaneAutopilot
    case vtolIntro, vtolTakeoff, vtolForward, vtolBack, vtolAutopilot
    case examinationIntro, examination

    var aircraft: TrainingAircraft {
        switch self {
        case .airplaneIntro, .airplaneTakeoff, .airplaneManual, .airplaneAutopilot: return .airplane
        case .vtolIntro, .vtolTakeoff, .vtolForward, .vtolBack, .vtolAutopilot: return .vtol
        case .examinationIntro, .examination: return .examination
        default: return .copter
        }
    }

    var isBriefing: Bool {
        switch self {
        case .copterIntro, .instruments, .simulationPanels, .airplaneIntro, .vtolIntro, .examinationIntro: return true
        default: return false
        }
    }

    var titleKey: String { "instructor.step.\(rawValue).title" }
    var detailKey: String { "instructor.step.\(rawValue).detail" }

    /// IDs shared with the view's spotlight anchors. The scoring runtime has no UI dependency.
    var spotlightTarget: String? {
        switch self {
        case .flightPanel: return "simulation.flightOps"
        case .arm: return "simulation.command.arm"
        case .copterTakeoff, .airplaneTakeoff, .vtolTakeoff: return "simulation.command.takeoff"
        case .copterHover, .vtolBack: return "simulation.command.hover"
        case .copterAutopilot, .vtolAutopilot: return "simulation.command.autoPath"
        case .copterReturn: return "simulation.command.returnHome"
        case .airplaneAutopilot: return "simulation.assist.altitudeHold"
        case .instruments: return "simulation.instruments"
        case .simulationPanels: return "simulation.toolbar"
        case .cameraPanel: return "simulation.camera"
        case .cameraView: return "simulation.camera.modes"
        case .missionMap: return "simulation.map"
        default: return nil
        }
    }

    var lessonStart: FlightTrainingStep {
        switch aircraft {
        case .copter: return .copterIntro
        case .airplane: return .airplaneIntro
        case .vtol: return .vtolIntro
        case .examination: return .examinationIntro
        }
    }
}

enum FlightTrainingPhase: Equatable {
    case briefing, flying, checkpoint, failed, completed
}

struct TrainingSphere: Equatable, Identifiable {
    let id: Int
    let center: SIMD3<Float>
    let radius: Float
}

struct FlightTrainingProgress: Equatable {
    var step: FlightTrainingStep
    var phase: FlightTrainingPhase
    var spheresPassed: Int = 0
    var objectiveProgress: Double = 0
    var manualControlRequired: Bool = false

    var stepNumber: Int { (FlightTrainingStep.allCases.firstIndex(of: step) ?? 0) + 1 }
    var stepCount: Int { FlightTrainingStep.allCases.count }
    var canContinue: Bool { phase == .briefing || phase == .checkpoint }
    var pausesFlight: Bool { phase != .flying }
    var showsSpheres: Bool { step.aircraft == .examination }
}

/// Only measurements enter the instructor. It never flies the aircraft or edits its physics.
struct FlightTrainingObservation {
    var position: SIMD3<Float>
    var heightAboveGround: Float = 0
    var airspeed: Float = 0
    var verticalSpeed: Float = 0
    var isArmed: Bool = false
    var isAirborne: Bool = false
    var isManualControl: Bool = false
    var hasManualInput: Bool = false
    var hoverActive: Bool = false
    var autoPathActive: Bool = false
    var returnHomeActive: Bool = false
    var altitudeHoldActive: Bool = false
    var openPanel: String? = nil
    var isMapOpen: Bool = false
    var cameraChanged: Bool = false
    var vtolProgress: Float = 0
    var crashed: Bool = false
}

/// A deterministic course. Objectives cannot be acknowledged away; checkpoints give the pilot
/// time to read the next instruction before physics resumes. Segment/sphere scoring also catches
/// a fast crossing whose two frame positions are both outside the sphere.
struct FlightTrainingSession {
    private(set) var progress = FlightTrainingProgress(step: .copterIntro, phase: .briefing)
    private(set) var spheres: [TrainingSphere] = []
    private var previousPosition: SIMD3<Float>?
    private var previousManualControl = false
    private var heldTime: Float = 0
    private var manualInputTime: Float = 0
    private var manualDistance: Float = 0

    init(origin: SIMD3<Float> = .zero) {
        configureSpheres(origin: origin)
    }

    mutating func configureSpheres(origin: SIMD3<Float>) {
        let offsets: [SIMD3<Float>] = [
            SIMD3(0, 10, -22), SIMD3(16, 14, -48), SIMD3(-12, 18, -76),
            SIMD3(14, 12, -102), SIMD3(0, 10, -130)
        ]
        spheres = offsets.enumerated().map { TrainingSphere(id: $0.offset, center: origin + $0.element, radius: 6) }
        previousPosition = nil
        previousManualControl = false
    }

    @discardableResult
    mutating func continueCourse() -> Bool {
        guard progress.canContinue else { return false }
        let steps = FlightTrainingStep.allCases
        guard let index = steps.firstIndex(of: progress.step), index + 1 < steps.count else { return false }
        enter(steps[index + 1])
        return true
    }

    mutating func restartLesson() {
        enter(progress.step.lessonStart)
    }

    private mutating func enter(_ step: FlightTrainingStep) {
        progress = FlightTrainingProgress(step: step, phase: step.isBriefing ? .briefing : .flying)
        previousPosition = nil
        previousManualControl = false
        heldTime = 0
        manualInputTime = 0
        manualDistance = 0
    }

    mutating func observe(_ observation: FlightTrainingObservation, deltaTime: Float) {
        guard progress.phase == .flying, deltaTime.isFinite, deltaTime > 0,
              observation.position.x.isFinite, observation.position.y.isFinite, observation.position.z.isFinite,
              observation.heightAboveGround.isFinite, observation.airspeed.isFinite,
              observation.verticalSpeed.isFinite, observation.vtolProgress.isFinite else { return }
        // The app passes integration time; a paused/background interval cannot finish a hold.
        let dt = min(deltaTime, 0.1)
        if observation.crashed {
            progress.phase = .failed
            return
        }
        let distance = previousPosition.map { simd_distance($0, observation.position) } ?? 0
        let continuousMovement = distance <= max(4, observation.airspeed * dt * 3 + 2)
        if observation.isManualControl, observation.hasManualInput {
            manualInputTime += dt
        }
        if observation.isManualControl, previousManualControl, observation.isAirborne, continuousMovement {
            manualDistance += distance
        }

        let achieved: Bool
        switch progress.step {
        case .flightPanel:
            achieved = observation.openPanel == "flightOps"
        case .arm:
            achieved = observation.isArmed
        case .copterTakeoff:
            achieved = hold(observation.isAirborne && observation.heightAboveGround >= 6, for: 1, dt: dt)
        case .copterManual:
            progress.objectiveProgress = Double(min(1, manualDistance / 15))
            achieved = manualInputTime >= 0.25 && manualDistance >= 15 && observation.heightAboveGround >= 3
        case .copterHover:
            achieved = hold(observation.hoverActive && observation.isAirborne && abs(observation.verticalSpeed) < 1,
                            for: 2, dt: dt)
        case .cameraPanel:
            achieved = observation.openPanel == "camera"
        case .cameraView:
            achieved = observation.cameraChanged
        case .missionMap:
            achieved = observation.isMapOpen
        case .copterAutopilot, .vtolAutopilot:
            achieved = hold(observation.autoPathActive && observation.isAirborne, for: 4, dt: dt)
        case .copterReturn:
            achieved = hold(observation.returnHomeActive && observation.isAirborne, for: 2, dt: dt)
        case .airplaneTakeoff:
            achieved = hold(observation.isAirborne && observation.heightAboveGround >= 10 && observation.airspeed >= 9,
                            for: 1, dt: dt)
        case .airplaneManual:
            progress.objectiveProgress = Double(min(1, manualDistance / 60))
            achieved = manualInputTime >= 0.25 && manualDistance >= 60 && observation.heightAboveGround >= 6
        case .airplaneAutopilot:
            achieved = hold(observation.altitudeHoldActive && observation.isAirborne, for: 4, dt: dt)
        case .vtolTakeoff:
            achieved = hold(observation.isAirborne && observation.heightAboveGround >= 15, for: 1, dt: dt)
        case .vtolForward:
            achieved = hold(observation.isAirborne && observation.vtolProgress >= 0.85 && observation.airspeed >= 10,
                            for: 1, dt: dt)
        case .vtolBack:
            achieved = hold(observation.isAirborne && observation.vtolProgress <= 0.08 && abs(observation.verticalSpeed) < 2,
                            for: 2, dt: dt)
        case .examination:
            progress.manualControlRequired = !observation.isManualControl && observation.isAirborne
            if observation.isManualControl, previousManualControl, observation.isArmed,
               observation.isAirborne, continuousMovement, let previousPosition {
                scoreSpheres(from: previousPosition, to: observation.position)
            }
            progress.objectiveProgress = Double(progress.spheresPassed) / Double(spheres.count)
            achieved = progress.spheresPassed == spheres.count
        default:
            achieved = false
        }
        previousPosition = observation.position
        previousManualControl = observation.isManualControl
        if achieved {
            progress.objectiveProgress = 1
            progress.phase = progress.step == .examination ? .completed : .checkpoint
        }
    }

    private mutating func hold(_ condition: Bool, for duration: Float, dt: Float) -> Bool {
        heldTime = condition ? heldTime + dt : 0
        progress.objectiveProgress = Double(min(1, heldTime / duration))
        return heldTime >= duration
    }

    private mutating func scoreSpheres(from start: SIMD3<Float>, to end: SIMD3<Float>) {
        var lastEntry: Float = -1
        while progress.spheresPassed < spheres.count {
            let sphere = spheres[progress.spheresPassed]
            guard let entry = Self.entryFraction(from: start, to: end, sphere: sphere), entry > lastEntry else { break }
            progress.spheresPassed += 1
            lastEntry = entry
        }
    }

    static func entryFraction(from start: SIMD3<Float>, to end: SIMD3<Float>, sphere: TrainingSphere) -> Float? {
        let offset = start - sphere.center
        let direction = end - start
        let a = simd_dot(direction, direction)
        let c = simd_dot(offset, offset) - sphere.radius * sphere.radius
        // Merely appearing inside a sphere, including a reset or an autopilot handover, is not a pass.
        guard a > 1e-8, c > 0 else { return nil }
        let b = 2 * simd_dot(offset, direction)
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }
        let entry = (-b - sqrt(discriminant)) / (2 * a)
        return entry >= 0 && entry <= 1 ? entry : nil
    }
}
