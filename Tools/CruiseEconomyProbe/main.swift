// Headless check of what a fuel aircraft actually does in level cruise under the autopilot.
//
// `FuelAtmosphereProbe` multiplies a tank by a cruise throttle and compares the answer with the
// brochure. This one flies the aircraft: a speed loop asks for the published cruise speed, an
// altitude loop holds the height, and the solver applies whatever floor it applies to a guided
// fixed wing. What comes out is the speed the aircraft settles at, the lever it is held at, the
// shaft power that costs and how long the tanks last there.
//
// It was written because five new airframes emptied their tanks in a third of their published
// endurance and nothing in the fuel model was wrong. The speed loop was asking for a closed
// throttle and being overruled: a guided fixed wing is not allowed below its class's
// `minimumSafeFlightThrottle`, 0.38–0.47 of the lever, and an AR5 holds its cruise on 0.31.
// The fuel fixed wings of the expansion now carry levers worked out from their own engine and
// propeller (`AirframePerformanceEstimate`), and this probe is what holds them to it. The older
// profiles are still on class figures; they are listed with what those figures cost them.
import Foundation
import simd

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let burnService = FuelBurnService()
let dt: Float = 1.0 / 60.0
var failures: [String] = []
var classHeld: [String] = []
print("Level cruise at 300 m, tanks half full, the speed loop asking for the published cruise speed")
print(String(repeating: "-", count: 118))
print("profile                     Vcr  V held   ×Vcr  lever asked  lever held  floor  shaft kW  rated  kg/h   tanks h  declared h")
for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard let wing = profile.fixedWingParameters, let uav = profile.resolvedUAVProfile,
          let powerplant = uav.powerplant, powerplant.energySource == .fuel, let fuel = powerplant.fuel,
          powerplant.totalRatedShaftPowerKW != nil else { continue }
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: uav)
    var fuelState = FuelSystemState.full(capacityKg: fuel.usableFuelMassKg, reserveFraction: fuel.reserveFraction)
    fuelState.remainingKg = fuel.usableFuelMassKg * 0.5
    let backend = FuelPropulsionBackend(powerplant: powerplant, cruiseSpeedMps: wing.cruiseSpeedMps)
    let baseline = FlightBaselineResolver.resolve(runtimeProfile: profile, activeUAVProfile: uav, vehicleMassModel: massModel, flightMode: .autoPath)
    let altitude: Float = 300
    var state = DroneState(position: SIMD3<Float>(0, altitude, 0), velocity: SIMD3<Float>(0, 0, -wing.cruiseSpeedMps), orientation: .zero,
                           angularVelocity: .zero, throttle: 0.5, motorThrottle: 0.5, rotorAngularSpeed: .zero,
                           forwardAirspeed: wing.cruiseSpeedMps, physicalState: .airborne, mode: .autoPath)
    state.armState = .armed
    state.mechanization.gearExtension = 0
    if let backend {
        var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        warm.runState = .ready
        warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6000.0) * 0.7
        warm.temperatureC = EngineOperatingEnvelope.envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = warm
    }
    var pitchTrim: Float = 0.03, throttleTrim: Float = baseline.cruiseReferenceThrottle
    var speedSum: Float = 0, motorSum: Float = 0, commandSum: Float = 0, powerSum: Float = 0, n: Float = 0
    for tick in 0..<(60 * 150) {
        let altitudeError: Float = altitude - state.position.y
        let trimStep: Float = altitudeError * 0.0006 * dt
        pitchTrim = min(0.30, max(-0.15, pitchTrim + trimStep))
        let pitchRaw: Float = pitchTrim + altitudeError * 0.006 - state.velocity.y * 0.012
        let pitch: Float = min(0.30, max(-0.20, pitchRaw))
        let speedError: Float = wing.cruiseSpeedMps - state.forwardAirspeed
        let throttleStep: Float = speedError * 0.01 * dt
        throttleTrim = min(1, max(0, throttleTrim + throttleStep))
        let throttleRaw: Float = throttleTrim + speedError * 0.05
        let throttle: Float = min(1, max(0, throttleRaw))
        let control = DroneControlInput(targetPosition: SIMD3<Float>(state.position.x, altitude, state.position.z - 500),
                                        targetOrientation: SIMD3<Float>(0, pitch, 0), yawIntent: 0, throttle: throttle,
                                        isArmed: true, mode: .autoPath, controlMode: .stabilized, landingGearDownCommand: false)
        let context = DroneSimulationContext(profile: profile, activeUAVProfile: uav, weather: .normal, damageState: .pristine,
                                             batteryState: .full, collisionRisk: 0, windVector: .zero, vehicleMassModel: massModel,
                                             fuelState: fuelState, engineState: state.engineRuntime, fuelPropulsion: backend)
        state = engine.step(state: state, control: control, context: context, deltaTime: dt)
        if tick >= 60 * 110 {
            speedSum += state.forwardAirspeed; motorSum += state.motorThrottle; commandSum += throttle
            powerSum += (state.engineRuntime?.shaftPowerKW ?? 0) * Float(powerplant.engineCount); n += 1
        }
    }
    let shaftKW = powerSum / n
    let air = AtmosphereModel.standard.state(altitudeMeters: altitude)
    var probeFuel = FuelSystemState.full(capacityKg: fuel.usableFuelMassKg, reserveFraction: fuel.reserveFraction)
    probeFuel = burnService.update(current: probeFuel, input: FuelBurnInput(powerplant: powerplant, throttle: motorSum / n, engineRunning: true,
        atmosphere: air, leakKgPerSec: 0, shaftPowerKW: shaftKW / Float(powerplant.engineCount), thrustNewtons: nil), deltaTime: 1)
    let flow = probeFuel.flowKgPerHour
    print(profile.displayName.padding(toLength: 26, withPad: " ", startingAt: 0)
          + String(format: "%5.1f %7.1f %6.2f %12.2f %11.2f %6.2f %9.1f %6.0f %6.2f %8.1f %10.1f", wing.cruiseSpeedMps, speedSum / n,
                   speedSum / n / wing.cruiseSpeedMps, commandSum / n, motorSum / n, baseline.effectiveMinimumSafeFlightThrottle,
                   shaftKW, powerplant.totalRatedShaftPowerKW ?? 0, flow, fuel.usableFuelMassKg / max(0.001, flow), (uav.nominalFlightTimeSec ?? 0) / 3600))
    // The aircraft is allowed to fly its own cruise speed. Three per cent is the speed loop's
    // own settling band here; past it, something other than the loop is holding the lever.
    let held = speedSum / n
    if held > wing.cruiseSpeedMps * 1.03, commandSum / n < motorSum / n - 0.05 {
        let line = String(format: "%@ is held at %.0f %% of the lever while its speed loop asks for %.0f %%: it flies %.1f m/s against a cruise of %.1f",
                          profile.displayName, motorSum / n * 100, commandSum / n * 100, held, wing.cruiseSpeedMps)
        // An airframe whose levers were worked out from its own engine has no excuse. One still
        // on its class's figures is doing what those figures say, and is listed, not failed.
        if baseline.tuningSource == .derived { failures.append(line) } else { classHeld.append(line) }
    }
}

print("")
if !classHeld.isEmpty {
    print("On class throttle figures, and held above their cruise by them:")
    classHeld.forEach { print("  \($0)") }
    print("")
}
if failures.isEmpty {
    print("RESULT: PASS - every aircraft with its own levers can be slowed to its own cruise speed")
} else {
    failures.forEach { print("FAIL: \($0)") }
    print("RESULT: FAIL")
    exit(1)
}
