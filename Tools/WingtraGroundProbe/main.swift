import Darwin
import Foundation
import simd

// DroneModelBuilder supports user workbench aircraft as well as catalog aircraft. The workbench
// renderer depends on presentation-only selection types and is intentionally absent from this
// headless target; the Wingtra catalog path never calls this shim.
enum WorkbenchModelBuilder {
    static func simulationVisual(for build: WorkbenchBuild) -> DroneVisualModel {
        fatalError("Workbench visuals are outside WingtraGroundProbe")
    }
}

// Headless regression probe for the Wingtra ground-pose contract.
//
// The probe builds the real catalog Wingtra visual and derives its production contact profile.
// It then verifies the three pieces that must agree for a tail-sitter at rest:
//
//   1. DroneState.position remains the legacy support-plane reference,
//   2. the shared body-origin lift puts the lowest collision sphere on that plane,
//   3. ground attitude severity is measured from quaternion directions, not singular Euler roll.
//
// It also compares ImpactResolutionService in two equivalent coordinate descriptions: a legacy
// state position plus bodyOriginWorldOffset, and a state position translated to the body origin
// with a zero offset. Their impulse response must match while their stored positions differ by
// exactly the body-origin translation.
//
// Run: Tools/WingtraGroundProbe/run.sh

private struct WingtraFixture {
    let runtimeProfile: DroneModelProfile
    let contactProfile: VehicleContactProfile
    let graph: VehicleComponentGraph
    let massProperties: VehicleMassProperties
    let restOrientation: simd_quatf
    let bodyLift: Float
}

private var failures: [String] = []

private func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        failures.append(message)
        print("FAIL: \(message)")
    }
}

private func approximatelyEqual(
    _ lhs: Float,
    _ rhs: Float,
    tolerance: Float = 0.0001
) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func approximatelyEqual(
    _ lhs: SIMD3<Float>,
    _ rhs: SIMD3<Float>,
    tolerance: Float = 0.0001
) -> Bool {
    simd_distance(lhs, rhs) <= tolerance
}

private func radians(_ degrees: Float) -> Float {
    degrees * .pi / 180.0
}

private func makeFixture() -> WingtraFixture? {
    let repository = LIPODroneModelRepository()
    guard let runtimeProfile = repository.allProfiles.first(where: {
        $0.id == "wingtraone-gen-ii"
    }) else {
        failures.append("WingtraOne GEN II runtime profile is missing")
        return nil
    }
    guard let uavProfile = runtimeProfile.resolvedUAVProfile else {
        failures.append("WingtraOne GEN II catalog profile is missing")
        return nil
    }

    let visual = DroneModelBuilder.build(profile: runtimeProfile)
    let geometry = DroneVisualGeometrySample.capture(from: visual)
    let massModel = VehicleMassModel.baseline(
        for: runtimeProfile,
        uavProfile: uavProfile
    )
    let physicalModel = VehicleComponentGraphBuilder.build(
        profile: runtimeProfile,
        vehicleMassModel: massModel,
        geometry: geometry
    )
    let restOrientation = VehicleContactProfile.restOrientation(
        for: runtimeProfile.airframeStyle
    )

    return WingtraFixture(
        runtimeProfile: runtimeProfile,
        contactProfile: physicalModel.contactProfile,
        graph: physicalModel.graph,
        massProperties: physicalModel.graph.massProperties,
        restOrientation: restOrientation,
        bodyLift: physicalModel.contactProfile.lowestPointOffset(
            orientation: restOrientation
        )
    )
}

private func testRestOffset(_ fixture: WingtraFixture) {
    let profile = fixture.contactProfile
    let rest = fixture.restOrientation
    let supportY: Float = 87.35 // Deliberately non-zero: representative of mapped terrain.
    let statePosition = SIMD3<Float>(13.0, supportY, -21.0)
    let bodyOffset = SIMD3<Float>(0.0, fixture.bodyLift, 0.0)
    let bodyOrigin = statePosition + bodyOffset

    let rawLowest = profile.lowestPointY(
        position: statePosition,
        orientation: rest
    )
    let liftedLowest = profile.lowestPointY(
        position: bodyOrigin,
        orientation: rest
    )
    let sphereBottoms = profile.spheres.map { sphere in
        sphere.worldCenter(position: bodyOrigin, orientation: rest).y - sphere.radius
    }
    let lowestSphereBottom = sphereBottoms.min() ?? .greatestFiniteMagnitude

    check(fixture.runtimeProfile.airframeStyle == .tailsitterVTOL,
          "Wingtra fixture must remain a tailsitter")
    check(!profile.spheres.isEmpty, "Wingtra contact profile must not be empty")
    check(fixture.bodyLift > 0.25,
          "Wingtra rest lift unexpectedly small; probe no longer exercises tail penetration")
    check(fixture.bodyLift < 1.0,
          "Wingtra rest lift is implausibly large")
    check(approximatelyEqual(rawLowest, supportY - fixture.bodyLift, tolerance: 0.0002),
          "unlifted profile penetration must equal the shared rest offset")
    check(approximatelyEqual(liftedLowest, supportY, tolerance: 0.0002),
          "body-origin lift must place the profile's lowest point on the support plane")
    check(approximatelyEqual(lowestSphereBottom, supportY, tolerance: 0.0002),
          "the lowest Wingtra contact sphere must touch, not penetrate, mapped terrain")
    check(sphereBottoms.allSatisfy { $0 >= supportY - 0.0002 },
          "a Wingtra contact sphere remains below ground after the shared body lift")
    check(approximatelyEqual(
        profile.groundClearanceOffset(orientation: rest, restOrientation: rest),
        0.0
    ), "rest-normalized physics clearance must preserve state.position.y == supportY")

    print(String(
        format: "rest-offset: %d spheres, lift %.4f m, raw penetration %.4f m, lifted clearance %+.6f m",
        profile.spheres.count,
        fixture.bodyLift,
        supportY - rawLowest,
        liftedLowest - supportY
    ))
}

/// Same physical measure used by DroneSimulationViewModel: where the rest attitude says the
/// sky-facing direction lives in body coordinates, transformed by the current quaternion.
private func groundRestAttitudeDeviation(
    orientation: simd_quatf,
    restOrientation: simd_quatf
) -> Float {
    let worldUp = SIMD3<Float>(0.0, 1.0, 0.0)
    let restUpBody = simd_act(restOrientation.inverse, worldUp)
    let currentUp = simd_act(orientation, restUpBody)
    return acos(min(Float(1.0), max(Float(-1.0), currentUp.y)))
}

private func quaternionFromFlightEuler(_ euler: SIMD3<Float>) -> simd_quatf {
    simd_quatf(angle: euler.z, axis: SIMD3<Float>(0.0, 1.0, 0.0))
        * simd_quatf(angle: euler.y, axis: SIMD3<Float>(1.0, 0.0, 0.0))
        * simd_quatf(angle: euler.x, axis: SIMD3<Float>(0.0, 0.0, 1.0))
}

private func testQuaternionRestAttitude(_ fixture: WingtraFixture) {
    let rest = fixture.restOrientation
    let exactRest = groundRestAttitudeDeviation(
        orientation: rest,
        restOrientation: rest
    )
    let yawedRest = simd_quatf(
        angle: radians(137.0),
        axis: SIMD3<Float>(0.0, 1.0, 0.0)
    ) * rest
    let yawedDeviation = groundRestAttitudeDeviation(
        orientation: yawedRest,
        restOrientation: rest
    )

    // Captured failure shape from the original arm bug: near the Euler pitch singularity the
    // display decomposition reported ~70 degrees of roll although the body was only ~5 degrees
    // away from its valid tail-standing attitude.
    let singularEuler = SIMD3<Float>(
        radians(70.2),
        radians(85.3),
        radians(70.1)
    )
    let singularQuaternion = quaternionFromFlightEuler(singularEuler)
    let singularDeviation = groundRestAttitudeDeviation(
        orientation: singularQuaternion,
        restOrientation: rest
    )

    let sideTipped = simd_quatf(
        angle: .pi / 2,
        axis: SIMD3<Float>(0.0, 0.0, 1.0)
    ) * rest
    let sideDeviation = groundRestAttitudeDeviation(
        orientation: sideTipped,
        restOrientation: rest
    )

    check(exactRest < radians(0.05), "exact Wingtra rest attitude must have zero deviation")
    check(yawedDeviation < radians(0.05), "heading changes must not look like a ground tip-over")
    check(abs(singularEuler.x) > 1.22,
          "captured sample must still demonstrate the old Euler crash threshold")
    check(singularDeviation < radians(8.0),
          "near-vertical Wingtra attitude must remain safe across the Euler singularity")
    check(approximatelyEqual(sideDeviation, .pi / 2, tolerance: radians(0.05)),
          "a real 90-degree side tip must still be detected")

    print(String(
        format: "rest-attitude: exact %.3f deg, yaw-only %.3f deg, singular sample %.3f deg (Euler roll %.1f deg), side-tip %.3f deg",
        exactRest * 180.0 / .pi,
        yawedDeviation * 180.0 / .pi,
        singularDeviation * 180.0 / .pi,
        singularEuler.x * 180.0 / .pi,
        sideDeviation * 180.0 / .pi
    ))
}

private func makeImpactState(
    position: SIMD3<Float>,
    orientation: simd_quatf,
    contactNormal: SIMD3<Float>
) -> DroneState {
    var state = DroneState.initial
    state.position = position
    state.velocity = -contactNormal * 7.5 + SIMD3<Float>(0.4, -0.2, 0.7)
    state.fixedWingOrientationQuat = orientation
    state.bodyAngularVelocity = SIMD3<Float>(0.31, -0.22, 0.17)
    state.angularVelocity = state.bodyAngularVelocity
    state.physicalState = .airborne
    state.motionState = .airborne
    state.armState = .armed
    return state
}

private func compareImpactResults(
    offsetState: DroneState,
    shiftedState: DroneState,
    offsetReport: ImpactReport,
    shiftedReport: ImpactReport,
    bodyOffset: SIMD3<Float>,
    context: String
) {
    check(approximatelyEqual(offsetState.position + bodyOffset, shiftedState.position),
          "\(context): state-frame positions must differ only by bodyOriginWorldOffset")
    check(approximatelyEqual(offsetState.velocity, shiftedState.velocity),
          "\(context): linear impulse response changed across equivalent frames")
    check(approximatelyEqual(offsetState.bodyAngularVelocity, shiftedState.bodyAngularVelocity),
          "\(context): angular impulse response changed across equivalent frames")
    check(approximatelyEqual(offsetState.angularVelocity, shiftedState.angularVelocity),
          "\(context): mirrored angular velocity changed across equivalent frames")
    check(approximatelyEqual(offsetReport.normalClosingSpeed, shiftedReport.normalClosingSpeed),
          "\(context): contact velocity changed across equivalent frames")
    check(approximatelyEqual(offsetReport.impactEnergyJ, shiftedReport.impactEnergyJ),
          "\(context): impact energy changed across equivalent frames")
    check(approximatelyEqual(offsetReport.appliedImpulse, shiftedReport.appliedImpulse),
          "\(context): applied impulse changed across equivalent frames")
    check(offsetReport.componentID == shiftedReport.componentID,
          "\(context): body-frame component localization changed across equivalent frames")
    check(offsetReport.tier.rawValue == shiftedReport.tier.rawValue,
          "\(context): impact tier changed across equivalent frames")
}

private func testImpactFrameEquivalence(_ fixture: WingtraFixture) {
    let service = ImpactResolutionService()
    let bodyOffset = SIMD3<Float>(0.0, fixture.bodyLift, 0.0)
    let orientation = simd_quatf(
        angle: radians(24.0),
        axis: simd_normalize(SIMD3<Float>(0.6, 0.3, -0.7))
    )
    let normal = simd_normalize(SIMD3<Float>(0.82, 0.18, -0.54))
    let legacyPrevious = SIMD3<Float>(3.2, 5.4, -7.1)
    let legacyCurrent = SIMD3<Float>(3.0, 5.1, -6.8)
    let hitFraction: Float = 0.43
    let stateAtHit = legacyPrevious + (legacyCurrent - legacyPrevious) * hitFraction
    let localContact = SIMD3<Float>(0.38, -0.09, 0.17)
    let worldContact = stateAtHit + bodyOffset + simd_act(orientation, localContact)
    let sphere = fixture.contactProfile.spheres.first
    let componentID = sphere?.componentID ?? "probe.contact"
    let sphereRadius = sphere?.radius ?? 0.08
    let obstacle = CollisionObstacle(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        center: worldContact - normal,
        radius: 1.0,
        source: "world.building.probe"
    )
    let contact = VehicleSweptContact(
        obstacle: obstacle,
        componentID: componentID,
        contactPoint: worldContact,
        contactNormal: normal,
        hitFraction: hitFraction,
        isSupportSurfaceContact: false,
        sphereOffset: sphere?.offset ?? localContact,
        sphereRadius: sphereRadius
    )

    var offsetState = makeImpactState(
        position: legacyCurrent,
        orientation: orientation,
        contactNormal: normal
    )
    var shiftedState = offsetState
    shiftedState.position += bodyOffset
    var offsetGraph = fixture.graph
    var shiftedGraph = fixture.graph

    let offsetReport = service.resolve(
        contact: contact,
        previousPosition: legacyPrevious,
        state: &offsetState,
        graph: &offsetGraph,
        massProperties: fixture.massProperties,
        airframeClass: .hybridVTOL,
        bodyOriginWorldOffset: bodyOffset,
        rotorsSpinning: false,
        deltaTime: 1.0 / 60.0,
        applyDamage: false
    )
    let shiftedReport = service.resolve(
        contact: contact,
        previousPosition: legacyPrevious + bodyOffset,
        state: &shiftedState,
        graph: &shiftedGraph,
        massProperties: fixture.massProperties,
        airframeClass: .hybridVTOL,
        rotorsSpinning: false,
        deltaTime: 1.0 / 60.0,
        applyDamage: false
    )
    compareImpactResults(
        offsetState: offsetState,
        shiftedState: shiftedState,
        offsetReport: offsetReport,
        shiftedReport: shiftedReport,
        bodyOffset: bodyOffset,
        context: "swept resolve"
    )

    // Negative control: omitting the offset from an unshifted state must measurably change the
    // lever arm, proving this scenario would catch a regression that silently ignored the API.
    var wrongFrameState = makeImpactState(
        position: legacyCurrent,
        orientation: orientation,
        contactNormal: normal
    )
    var wrongFrameGraph = fixture.graph
    let wrongFrameReport = service.resolve(
        contact: contact,
        previousPosition: legacyPrevious,
        state: &wrongFrameState,
        graph: &wrongFrameGraph,
        massProperties: fixture.massProperties,
        airframeClass: .hybridVTOL,
        rotorsSpinning: false,
        deltaTime: 1.0 / 60.0,
        applyDamage: false
    )
    let negativeControlDifference = abs(
        wrongFrameReport.appliedImpulse - offsetReport.appliedImpulse
    ) + simd_distance(
        wrongFrameState.bodyAngularVelocity,
        offsetState.bodyAngularVelocity
    )
    check(negativeControlDifference > 0.001,
          "impact equivalence scenario is not sensitive to a missing body-origin offset")

    var penetrationOffsetState = makeImpactState(
        position: legacyCurrent,
        orientation: orientation,
        contactNormal: normal
    )
    var penetrationShiftedState = penetrationOffsetState
    penetrationShiftedState.position += bodyOffset
    var penetrationOffsetGraph = fixture.graph
    var penetrationShiftedGraph = fixture.graph
    let penetrationOffsetReport = service.resolvePenetration(
        penetrationDepth: 0.12,
        contactNormal: normal,
        contactPoint: worldContact,
        obstacle: obstacle,
        componentID: componentID,
        sphereRadius: sphereRadius,
        state: &penetrationOffsetState,
        graph: &penetrationOffsetGraph,
        massProperties: fixture.massProperties,
        airframeClass: .hybridVTOL,
        bodyOriginWorldOffset: bodyOffset,
        rotorsSpinning: false,
        deltaTime: 1.0 / 60.0,
        applyDamage: false
    )
    let penetrationShiftedReport = service.resolvePenetration(
        penetrationDepth: 0.12,
        contactNormal: normal,
        contactPoint: worldContact,
        obstacle: obstacle,
        componentID: componentID,
        sphereRadius: sphereRadius,
        state: &penetrationShiftedState,
        graph: &penetrationShiftedGraph,
        massProperties: fixture.massProperties,
        airframeClass: .hybridVTOL,
        rotorsSpinning: false,
        deltaTime: 1.0 / 60.0,
        applyDamage: false
    )
    compareImpactResults(
        offsetState: penetrationOffsetState,
        shiftedState: penetrationShiftedState,
        offsetReport: penetrationOffsetReport,
        shiftedReport: penetrationShiftedReport,
        bodyOffset: bodyOffset,
        context: "penetration resolve"
    )

    print(String(
        format: "impact-frames: swept impulse %.5f Ns, penetration impulse %.5f Ns, negative-control delta %.5f",
        offsetReport.appliedImpulse,
        penetrationOffsetReport.appliedImpulse,
        negativeControlDifference
    ))
}

if let fixture = makeFixture() {
    testRestOffset(fixture)
    testQuaternionRestAttitude(fixture)
    testImpactFrameEquivalence(fixture)
}

if failures.isEmpty {
    print("RESULT: PASS - Wingtra ground/body-origin contract holds")
} else {
    print("RESULT: FAIL - \(failures.count) assertion(s) failed")
    exit(EXIT_FAILURE)
}
