import Foundation
import simd

@main
enum InstructorProbe {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("Instructor probe: \(message)") }
    }

    static func observation(for step: FlightTrainingStep, index: Int) -> FlightTrainingObservation {
        var sample = FlightTrainingObservation(position: SIMD3(0, 20, -Float(index) * 0.8))
        sample.heightAboveGround = 20
        sample.airspeed = 16
        sample.isArmed = true
        sample.isAirborne = true
        sample.isManualControl = true
        sample.hasManualInput = true
        sample.openPanel = step == .cameraPanel ? "camera" : "flightOps"
        sample.hoverActive = true
        sample.autoPathActive = true
        sample.returnHomeActive = true
        sample.altitudeHoldActive = true
        sample.isMapOpen = true
        sample.cameraChanged = true
        sample.vtolProgress = step == .vtolForward ? 1 : 0
        return sample
    }

    static func courseAtExamination() -> FlightTrainingSession {
        var session = FlightTrainingSession()
        var visited: [FlightTrainingStep] = []
        while session.progress.step != .examination {
            let step = session.progress.step
            visited.append(step)
            if session.progress.phase == .briefing {
                check(session.continueCourse(), "briefing should continue")
            } else {
                check(!session.continueCourse(), "an objective must not be skippable: \(step)")
                for index in 0..<500 {
                    session.observe(observation(for: step, index: index), deltaTime: 0.05)
                    if session.progress.phase == .checkpoint { break }
                }
                check(session.progress.phase == .checkpoint, "objective cannot finish: \(step)")
                check(session.continueCourse(), "completed objective should continue")
            }
        }
        check(visited == Array(FlightTrainingStep.allCases.dropLast()), "all lessons must run in order")
        return session
    }

    static func move(_ session: inout FlightTrainingSession, from: SIMD3<Float>, to: SIMD3<Float>, manual: Bool) {
        let count = max(1, Int(ceil(simd_distance(from, to) / 0.5)))
        for index in 0...count {
            let t = Float(index) / Float(count)
            var sample = FlightTrainingObservation(position: from + (to - from) * t)
            sample.heightAboveGround = sample.position.y
            sample.airspeed = 10
            sample.isArmed = true
            sample.isAirborne = true
            sample.isManualControl = manual
            sample.hasManualInput = manual
            session.observe(sample, deltaTime: 0.05)
        }
    }

    static func main() {
        let sphere = TrainingSphere(id: 0, center: .zero, radius: 2)
        check(FlightTrainingSession.entryFraction(from: SIMD3(-3, 0, 0), to: SIMD3(3, 0, 0), sphere: sphere) != nil,
              "fast crossing with both samples outside must count")
        check(FlightTrainingSession.entryFraction(from: SIMD3(-3, 3, 0), to: SIMD3(3, 3, 0), sphere: sphere) == nil,
              "passing near a sphere must not count")
        check(FlightTrainingSession.entryFraction(from: .zero, to: SIMD3(3, 0, 0), sphere: sphere) == nil,
              "spawn or handover inside a sphere must not count")

        var briefing = FlightTrainingSession()
        briefing.observe(observation(for: .copterTakeoff, index: 0), deltaTime: 100)
        check(briefing.progress.step == .copterIntro && briefing.progress.phase == .briefing,
              "briefing must pause objective evaluation")

        var session = courseAtExamination()
        check(session.spheres.count == 5, "final course needs exactly five spheres")
        let targets = session.spheres
        let start = SIMD3<Float>(0, 10, 0)
        move(&session, from: start, to: targets[1].center, manual: true)
        check(session.progress.spheresPassed == 0, "out-of-order spheres must not count")

        session = courseAtExamination()
        move(&session, from: start, to: targets[0].center, manual: false)
        check(session.progress.spheresPassed == 0 && session.progress.manualControlRequired,
              "autopilot crossing must not count")
        move(&session, from: targets[0].center, to: targets[0].center + SIMD3(0, 0, -1), manual: true)
        check(session.progress.spheresPassed == 0, "manual handover inside a sphere must not count")

        session = courseAtExamination()
        var cursor = start
        for target in targets {
            let entry = target.center + SIMD3<Float>(0, 0, target.radius + 1)
            let exit = target.center - SIMD3<Float>(0, 0, target.radius + 1)
            move(&session, from: cursor, to: entry, manual: true)
            move(&session, from: entry, to: exit, manual: true)
            check(session.progress.spheresPassed == target.id + 1, "sphere \(target.id + 1) must be counted once")
            cursor = exit
        }
        check(session.progress.phase == .completed, "five manual passes must complete the course")
        session.restartLesson()
        check(session.progress.step == .examinationIntro && session.progress.spheresPassed == 0,
              "retry must reset the final lesson and all sphere progress")
        check(session.continueCourse(), "final retry briefing should continue")
        var invalid = observation(for: .examination, index: 0)
        invalid.position.x = .nan
        session.observe(invalid, deltaTime: 0.05)
        check(session.progress.spheresPassed == 0 && session.progress.phase == .flying,
              "non-finite input must not corrupt progress")
        var crashed = observation(for: .examination, index: 0)
        crashed.crashed = true
        session.observe(crashed, deltaTime: 0.05)
        check(session.progress.phase == .failed, "crash must offer retry without success")
        check(!session.continueCourse(), "crash cannot skip the objective")

        var hold = FlightTrainingSession()
        while hold.progress.step != .copterHover {
            if hold.progress.canContinue { _ = hold.continueCourse() }
            else {
                for index in 0..<500 {
                    hold.observe(observation(for: hold.progress.step, index: index), deltaTime: 0.05)
                    if hold.progress.canContinue { break }
                }
            }
        }
        hold.observe(observation(for: .copterHover, index: 0), deltaTime: 100)
        check(hold.progress.phase == .flying, "long elapsed wall time must not complete a hold")
        var unstable = observation(for: .copterHover, index: 0)
        unstable.verticalSpeed = 3
        hold.observe(unstable, deltaTime: 0.05)
        check(hold.progress.objectiveProgress == 0, "unstable hover resets the consecutive hold")
        hold.restartLesson()
        check(hold.progress.step == .copterIntro, "retry returns to the current aircraft lesson")

        let suite = "uavsim.instructor.probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(!defaults.bool(forKey: InstructorProgressStore.flightCourseCompletedKey), "new user is not complete")
        defaults.set(true, forKey: InstructorProgressStore.appTourSeenKey)
        check(!defaults.bool(forKey: InstructorProgressStore.flightCourseCompletedKey), "tour dismissal cannot complete flight training")
        InstructorProgressStore.markFlightCourseCompleted(defaults: defaults)
        check(defaults.bool(forKey: InstructorProgressStore.flightCourseCompletedKey), "completion must persist")

        print("Instructor probe passed: \(checks) checks; \(FlightTrainingStep.allCases.count) steps; copter, airplane, VTOL; five ordered manual sphere passes.")
    }
}
