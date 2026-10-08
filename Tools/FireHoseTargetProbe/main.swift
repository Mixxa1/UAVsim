import Foundation
import simd

@main struct FireHoseTargetProbe {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }
        let flame = FireHoseAimTargeting.Flame(index: 0, centre: SIMD3<Float>(0, 10, -12), height: 10, radius: 2.5)
        func aim(_ point: SIMD3<Float>, blocker: Float? = nil, tree: Int? = nil, flames: [FireHoseAimTargeting.Flame]? = nil) -> Int? {
            FireHoseAimTargeting.hit(origin: SIMD3<Float>(0, 10, 0), direction: point - SIMD3<Float>(0, 10, 0),
                reach: 16, flames: flames ?? [flame], blockingDistance: blocker, blockingTreeIndex: tree)?.index
        }
        check(aim(flame.centre) == 0, "Direct nozzle aim must hit visible flame")
        check(aim(flame.centre + SIMD3<Float>(2, 0, 0)) == 0, "Flame edge outside a narrow tree collider must count")
        check(aim(flame.centre + SIMD3<Float>(0, 4, 0)) == 0, "Upper visible flame must be extinguishable")
        check(aim(flame.centre + SIMD3<Float>(0, -4, 0)) == 0, "Lower visible flame must be extinguishable")
        check(aim(flame.centre, blocker: 5) == nil, "A wall must still block foam")
        check(aim(flame.centre, blocker: 5, tree: 0) == 0, "The burning tree's own collider must not conceal its flame")
        check(aim(SIMD3<Float>(12, 10, -12)) == nil, "A clear miss must not extinguish a nearby fire")
        check(aim(flame.centre, flames: []) == nil, "Non-burning trees must not consume nozzle targeting")
        let far = FireHoseAimTargeting.Flame(index: 1, centre: SIMD3<Float>(0, 10, -40), height: 10, radius: 2.5)
        check(aim(far.centre, flames: [far]) == nil, "Fire outside nozzle throw must remain unreachable")
        let configuration = MissionScenarioConfiguration(parameters: MissionScenarioParameters(kind: .fireResponse,
            terrain: .forest, terrainDensity: .sparse, difficulty: .easy, seed: 1), selectedUAVProfileID: "test", payloadType: .fireHose)
        let placement = FireZonePlacement(zoneCenter: .zero, zoneRadius: 4, treePositions: [.zero],
            initiallyBurningIndices: [0], truckStandoffMeters: 4)
        var runtime = FireResponseRuntime(configuration: configuration, placement: placement)
        runtime.tick(deltaTime: 1, aimedFireIndex: 0, isSpraying: true)
        let progress = runtime.suppressionProgress(for: 0)
        runtime.tick(deltaTime: 0.1, aimedFireIndex: nil, isSpraying: true)
        check(runtime.suppressionProgress(for: 0) == progress, "Brief hand jitter must not erase foam progress")
        runtime.tick(deltaTime: 0.4, aimedFireIndex: nil, isSpraying: false)
        check(runtime.suppressionProgress(for: 0) < progress && runtime.burningCount == 1,
            "Off-target progress decays and cannot complete suppression automatically")
        runtime.tick(deltaTime: 1.4, aimedFireIndex: 0, isSpraying: true)
        check(runtime.burningCount == 0 && runtime.charredCount == 1, "Returning the foam jet to the fire completes suppression")
        var paused = FireResponseRuntime(configuration: configuration, placement: placement)
        paused.tick(deltaTime: 10, aimedFireIndex: 0, isSpraying: false)
        check(paused.burningCount == 1 && paused.suppressionProgress(for: 0) == 0,
            "Pointing the camera alone must not extinguish fire")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(InterceptMissionConfiguration())) as! [String: Any]
        json["targetKind"] = "groundVehicle"; json["groundVehicleModel"] = "cabover"
        let legacy = try JSONDecoder().decode(InterceptMissionConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        let normalized = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        check(normalized["targetKind"] == nil && normalized["groundVehicleModel"] == nil,
            "An old saved setup must not restore ground interception")
        check(MissionScenarioKind.vehiclePursuit.isGroundVehicleMission && MissionScenarioKind.vehicleEscort.isGroundVehicleMission,
            "Both unarmed vehicle missions remain available")
        print("PASS: \(checks) foam targeting, suppression and legacy mission checks")
    }
}
