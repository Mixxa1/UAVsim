import Foundation
import AppKit
import SceneKit
import Metal
import simd

var checks = 0
var failures: [String] = []
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures.append(message) }
}
let flat: (SIMD3<Float>, Float) -> Float = { _, _ in 0 }
let p = GroundVehicleProfile()
let wall = CollisionObstacle(id: UUID(), center: SIMD3<Float>(0, 3, -45), radius: 22,
    source: "building", baseY: 0, topY: 6, planarHalfExtents: SIMD2<Float>(20, 4), yawRadians: 0)
var navigation = GroundVehicleNavigation()
let goal = SIMD2<Float>(0, -95)
let first = navigation.waypoint(position: .zero, goal: goal, clearance: 2.1,
    deltaTime: 0.05, obstacles: [wall], traversable: { _ in true })
check(first != nil, "a wall has a traversable detour")
check(navigation.expandedNodes <= GroundVehicleNavigation.maximumExpansions, "the search has a work limit")
let route = [SIMD2<Float>.zero] + navigation.path
check(zip(route, route.dropFirst()).allSatisfy { GroundVehicleNavigation.clear($0.0, $0.1, 2.1, [wall]) },
      "all route edges clear the obstacle footprint")

let truck = GroundVehicleRuntime(position: .zero, seed: 42)
var maximumSpeed: Float = 0
var penetrated = false
for _ in 0..<3000 {
    _ = truck.step(deltaTime: 0.05, destination: goal, threat: nil, evasive: false,
        origin: .zero, areaRadius: 220, grip: 1, obstacles: [wall], ground: flat)
    maximumSpeed = max(maximumSpeed, simd_length(truck.state.velocity))
    penetrated = penetrated || wall.planarSignedDistance(to: SIMD2<Float>(truck.state.position.x, truck.state.position.z)) < 1.3
}
check(!penetrated, "the truck never drives through a building")
check(simd_distance(SIMD2<Float>(truck.state.position.x, truck.state.position.z), goal) < 15,
      "the truck follows its detour and reaches the destination: \(truck.state.position)")
check(maximumSpeed <= truck.profile.maxSpeed + 0.01, "speed respects the vehicle limit")
check(abs(truck.state.position.y) < 0.01, "a road actor stays on the ground")

func trunk(_ x: Float, _ z: Float) -> CollisionObstacle {
    CollisionObstacle(id: UUID(), center: SIMD3<Float>(x, 2, z), radius: 0.3,
        source: "tree.trunk", baseY: 0, topY: 4, planarHalfExtents: SIMD2<Float>(repeating: 0.2))
}
let trunkField = GroundVehicleObstacleField(obstacles: [trunk(0, 0)], groundY: 0, height: p.size.y)
let contactSolver = CollisionAnalysisService()
let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
let hull = [VehicleContactSphere(componentID: "body", offset: .zero, radius: 1.5)]
let missedCorner = contactSolver.firstSweptVehicleCollision(contactSpheres: hull,
    fromPosition: SIMD3<Float>(1.65, 2, 3), toPosition: SIMD3<Float>(1.65, 2, 1.5),
    fromOrientation: identity, toOrientation: identity, obstacles: trunkField.collisionObstacles)
check(missedCorner == nil, "the trunk's padded box corner is not a physical contact")
let realContact = contactSolver.firstSweptVehicleCollision(contactSpheres: hull,
    fromPosition: SIMD3<Float>(0, 2, 20), toPosition: SIMD3<Float>(0, 2, -20),
    fromOrientation: identity, toOrientation: identity, obstacles: trunkField.collisionObstacles)
check(realContact != nil && abs(realContact!.contactPoint.z - 0.2) < 0.001,
    "a real high-speed trunk strike is still detected on its actual surface")
// Ordinary routing must avoid slender trunks as well as wide walls. Include turns where
// the centre line is clear but the long body's front/rear overhang sweeps towards a tree.
let treeRoutes: [(String, [CollisionObstacle], SIMD2<Float>)] = [
    ("straight trunk", [trunk(0, -30)], SIMD2<Float>(0, -90)),
    ("offset trunk", [trunk(2.7, -30), trunk(-2.7, -45)], SIMD2<Float>(0, -90)),
    ("grove", [-12, -6, 0, 6, 12].map { trunk(Float($0), -35) }
        + [trunk(-5, -55), trunk(5, -55)], SIMD2<Float>(0, -90)),
    ("turn beside trunk", [trunk(3, -12), trunk(10, -22)], SIMD2<Float>(35, -55))
]
for (name, trees, destination) in treeRoutes {
    for grip: Float in [1, 0.45] {
        let car = GroundVehicleRuntime(position: .zero, seed: 63)
        var hits = 0
        for step in 0..<1800 {
            let before = car.state
            let reports = car.step(deltaTime: 1.0 / 30, destination: destination, threat: nil, evasive: false,
                origin: .zero, areaRadius: 220, grip: grip, obstacles: trees, ground: flat)
            hits += reports.count
            if !reports.isEmpty { print("TREE HIT: \(name), t \(Float(step) / 30), from \(before.position), velocity \(before.velocity), yaw \(before.orientation.z), steering \(car.steering), route \(car.navigation.path), closing \(reports[0].normalClosingSpeed)") }
        }
        let range = simd_distance(SIMD2<Float>(car.state.position.x, car.state.position.z), destination)
        print("TREE ROUTE: \(name), grip \(grip), hits \(hits), remaining \(range)m, \(car.state.position)")
        check(hits == 0 && car.damage.functionalState == .nominal,
            "ordinary routing avoids \(name) without damage at grip \(grip)")
        check(range < 12, "the truck completes \(name) detour at grip \(grip)")
    }
}

let unavoidable = GroundVehicleRuntime(position: .zero, seed: 71)
unavoidable.state.velocity = SIMD3<Float>(0, 0, -20)
var unavoidableHits = 0
for _ in 0..<90 {
    unavoidableHits += unavoidable.step(deltaTime: 1.0 / 60, destination: SIMD2<Float>(0, -90), threat: nil,
        evasive: false, origin: .zero, areaRadius: 150, grip: 1, obstacles: [trunk(0, -6)], ground: flat).count
}
check(unavoidableHits > 0 && unavoidable.damage.functionalState != .nominal,
    "an unavoidable impact still damages a car; navigation does not disable collisions")

let floor0 = CollisionMeshTriangle(point0: SIMD3<Float>(-120, 0, -120),
    point1: SIMD3<Float>(120, 0, -120), point2: SIMD3<Float>(120, 0, 120), supportsLandingSurface: true)!
let floor1 = CollisionMeshTriangle(point0: SIMD3<Float>(-120, 0, -120),
    point1: SIMD3<Float>(120, 0, 120), point2: SIMD3<Float>(-120, 0, 120), supportsLandingSurface: true)!
let facade0 = CollisionMeshTriangle(point0: SIMD3<Float>(-20, 0, -45),
    point1: SIMD3<Float>(20, 0, -45), point2: SIMD3<Float>(20, 20, -45))!
let facade1 = CollisionMeshTriangle(point0: SIMD3<Float>(-20, 0, -45),
    point1: SIMD3<Float>(20, 20, -45), point2: SIMD3<Float>(-20, 20, -45))!
let importedCell = CollisionObstacle(id: UUID(), center: SIMD3<Float>(0, 10, 0), radius: 170,
    source: "world.mesh.cell.0.0", baseY: 0, topY: 20, planarHalfExtents: SIMD2<Float>(120, 120),
    meshTriangles: [floor0, floor1, facade0, facade1])
let field = GroundVehicleObstacleField(obstacles: [importedCell], groundY: 0, height: p.size.y)
check(field.index.clear(.zero, .zero, p.clearance), "a mesh bucket containing road is not a solid block")
check(!field.index.clear(.zero, goal, p.clearance), "a facade inside a mesh bucket remains an obstacle")
check(field.collisionObstacles.first?.meshTriangles?.count == 2, "road support does not become repeated tyre contacts")
let importedTruck = GroundVehicleRuntime(position: .zero, seed: 41)
for _ in 0..<3000 {
    _ = importedTruck.step(deltaTime: 0.05, destination: goal, threat: nil, evasive: false,
        origin: .zero, areaRadius: 220, grip: 1, obstacles: [importedCell], ground: flat)
}
check(simd_distance(SIMD2<Float>(importedTruck.state.position.x, importedTruck.state.position.z), goal) < 15,
    "the truck drives over imported road and around its facade: \(importedTruck.state.position)")
let cliffTruck = GroundVehicleRuntime(position: .zero, seed: 4)
for _ in 0..<500 {
    _ = cliffTruck.step(deltaTime: 0.05, destination: goal, threat: nil, evasive: false,
        origin: .zero, areaRadius: 220, grip: 1, obstacles: [], ground: { p, _ in p.z < -25 ? .nan : 0 })
}
check(cliffTruck.state.position.z >= -25 && cliffTruck.state.attitudeQuat.vector.x.isFinite,
    "missing terrain cannot become a hovering road or corrupt the vehicle attitude")
let outline = [SIMD2<Float>(-20, -20), SIMD2<Float>(20, -20), SIMD2<Float>(20, 20),
    SIMD2<Float>(5, 20), SIMD2<Float>(5, -5), SIMD2<Float>(-20, -5)]
let concave = CollisionObstacle(id: UUID(), center: SIMD3<Float>(0, 3, 0), radius: 30,
    source: "world.building", baseY: 0, topY: 6, planarHalfExtents: SIMD2<Float>(20, 20), planarFootprint: outline)
check(GroundVehicleNavigation.clear(SIMD2<Float>(-15, 5), SIMD2<Float>(0, 5), 2, [concave]),
    "a concave building's open courtyard is not replaced by its bounding rectangle")

var damage = GroundVehicleDamage()
damage.impact(energyJ: 75_000, bodyPoint: GroundVehiclePart.wheelFrontLeft.position(in: p), profile: p)
check(damage.condition(.wheelFrontLeft) < 0.2 && damage.condition(.wheelFrontRight) == 1,
      "a wheel strike is localised to the struck wheel")
check(damage.steeringFactor < 1 && damage.brakeFactor < 1 && damage.wheelFactor < 1,
      "wheel damage changes grip, brakes and steering")
check(damage.condition(.engine) == 1, "a rear/side wheel hit does not invoke an aircraft power failure")
damage.impact(energyJ: 500_000, bodyPoint: GroundVehiclePart.engine.position(in: p), profile: p)
check(damage.functionalState.isTerminal, "an engine disabled by contact stops the vehicle")
var net = GroundVehicleDamage()
net.overturn()
check(net.functionalState == .disabled, "an overturned vehicle is disabled")
check(GroundVehicleRuntime.surfaceGrip(WeatherModel(preset: .snow, intensity: 1,
    windDirectionDeg: 0, windSpeedMps: 0, gusts: 0)) < 0.4, "snow reduces tyre grip")

func impactReport(_ energy: Float, _ point: SIMD3<Float>, _ normal: SIMD3<Float>) -> ImpactReport {
    ImpactReport(componentID: GroundVehiclePart.body.rawValue, obstacleID: UUID(), obstacleSource: "fixture",
        material: .metalVehicle, acousticSurface: .metal, vehicleMaterial: .steel, impactEnergyJ: energy,
        normalClosingSpeed: 10, tangentialSpeed: 0, tier: .criticalImpact, damage: [], connectionDamage: [],
        contactPoint: point, contactNormal: normal, appliedImpulse: 0, detachedPartMotions: [])
}
let rollover = GroundVehicleRuntime(position: .zero, seed: 19)
check(abs(rollover.componentGraph().massProperties.totalMassKg - p.massKg) < 0.1,
    "the road contact graph conserves the configured vehicle mass")
rollover.receive(impactReport(200_000, SIMD3<Float>(1.6, 2.8, 0), SIMD3<Float>(1, 0, 0)))
_ = rollover.step(deltaTime: 0.05, destination: goal, threat: nil, evasive: false, origin: .zero,
    areaRadius: 150, grip: 1, obstacles: [], ground: flat)
check(rollover.damage.rolledOver && abs(simd_act(rollover.state.attitudeQuat, SIMD3<Float>(0, 1, 0)).y) < 0.01,
    "a sufficiently energetic high side impact rolls the truck onto its side")
check(abs(rollover.state.position.y - p.size.x * 0.5) < 0.01,
    "an overturned body rests on its side rather than intersecting the road")
let burning = GroundVehicleRuntime(position: .zero, seed: 20)
burning.receive(impactReport(2_000_000, GroundVehiclePart.engine.position(in: p), SIMD3<Float>(0, 0, -1)))
check(burning.damage.burning && Set(burning.effects.map(\.kind.rawValue)) == Set(["fire", "smoke"]),
    "a burning engine publishes both fire and smoke for rendering and recording")
for _ in 0..<2400 { _ = burning.step(deltaTime: 0.05, destination: goal, threat: nil, evasive: false,
    origin: .zero, areaRadius: 150, grip: 1, obstacles: [], ground: flat) }
check(burning.effects.isEmpty, "damage effects expire on simulation time and cannot keep a recording open forever")

func tick(_ mission: inout GroundVehicleMissionRuntime, dt: Double, camera: Bool = true,
          los: Bool = true, car: SIMD2<Float> = .zero, condition: InterceptFunctionalState = .nominal) {
    mission.tick(deltaTime: dt, playerAirborne: true, playerLost: false, carPosition: car,
        carCondition: condition, distance: 40, inCamera: camera, lineOfSight: los)
}

var pursuit = GroundVehicleMissionRuntime(escort: false, difficulty: .easy, timeLimit: 120, route: [])
tick(&pursuit, dt: 20, camera: false)
check(pursuit.observedSeconds == 0, "proximity alone does not advance pursuit")
tick(&pursuit, dt: 45)
check(pursuit.result == .tracked, "pursuit succeeds on accumulated visible camera observation")
var lost = GroundVehicleMissionRuntime(escort: false, difficulty: .hard, timeLimit: 120, route: [])
tick(&lost, dt: 13, los: false)
check(lost.result == .vehicleLost, "occlusion beyond the loss limit fails pursuit")
var escort = GroundVehicleMissionRuntime(escort: true, difficulty: .medium, timeLimit: 120,
    route: [SIMD2<Float>(0, -40), SIMD2<Float>(40, -80)])
tick(&escort, dt: 35, camera: false)
check(escort.result == nil && escort.destination == SIMD2<Float>(0, -40), "escort waits for route progress, not camera dwell")
tick(&escort, dt: 1, camera: false, car: SIMD2<Float>(0, -40))
tick(&escort, dt: 35, camera: false, car: SIMD2<Float>(40, -80))
check(escort.result == .arrived, "escort succeeds after a safely accompanied arrival")
var broken = GroundVehicleMissionRuntime(escort: true, difficulty: .medium, timeLimit: 120, route: [goal])
tick(&broken, dt: 1, condition: .disabled)
check(broken.result == .vehicleDisabled && broken.result?.isSuccess == false,
      "damage never wins a pursuit or escort mission")

// Existing saved interception configuration has no ground-target fields.
let encoded = try JSONEncoder().encode(InterceptMissionConfiguration())
var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
object["targetKind"] = "groundVehicle"; object["groundVehicleModel"] = "cabover"
let legacy = try JSONDecoder().decode(InterceptMissionConfiguration.self,
    from: JSONSerialization.data(withJSONObject: object))
let migrated = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
check(migrated["targetKind"] == nil && migrated["groundVehicleModel"] == nil, "legacy ground interception fields cannot restore the removed mode")

if CommandLine.arguments.count > 2 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    for model in GroundVehicleModel.allCases {
        let visual = GroundVehicleVisual(model: model, directory: directory)
        var wheelMeshes = 0
        visual.rootNode.enumerateChildNodes { node, _ in
            if node.name?.hasPrefix("Tyre_") == true { wheelMeshes += 1 }
        }
        check(wheelMeshes == 6, "\(model.rawValue) loads the actual USDZ's six tyres")
        var treadCount = 0
        var stationaryTreads = 0
        visual.rootNode.enumerateChildNodes { node, _ in
            if node.name?.hasPrefix("TreadBlock_") == true {
                treadCount += 1
                if GroundVehiclePart(rawValue: node.parent?.name ?? "")?.isWheel != true { stationaryTreads += 1 }
            }
        }
        check(treadCount == 384 && stationaryTreads == 0, "all visible tread blocks belong to rotating wheels")
        let tread = visual.rootNode.childNode(withName: "TreadBlock_01", recursively: true)!
        let treadCentre = (SIMD3<Float>(tread.boundingBox.min) + SIMD3<Float>(tread.boundingBox.max)) * 0.5
        let treadBefore = visual.rootNode.simdConvertPosition(treadCentre, from: tread)
        for part in GroundVehiclePart.allCases where part.isWheel {
            let mount = visual.rootNode.childNode(withName: "wheel-mount-\(part.rawValue)", recursively: true)
            check(mount?.childNodes.first?.childNodes.isEmpty == false, "\(model.rawValue) rigs \(part.rawValue)")
            if let mount {
                check(simd_distance(mount.simdWorldPosition, part.position(in: p)) < 0.04,
                    "\(part.rawValue)'s visual axle agrees with its contact sphere")
            }
        }
        let driven = GroundVehicleRuntime(position: .zero, model: model, seed: 11)
        let recorder = MissionReplayRecorder(); recorder.startSession()
        let cameraNode = SCNNode(); cameraNode.camera = SCNCamera(); cameraNode.camera?.fieldOfView = 60
        cameraNode.simdPosition = SIMD3<Float>(0, 3.5, -3.85); visual.rootNode.addChildNode(cameraNode)
        let initial = MissionReplayVisualCapture.snapshot(id: "car", node: visual.rootNode,
            recorder: recorder, role: "target", displayName: model.rawValue, camera: cameraNode)
        for _ in 0..<80 { _ = driven.step(deltaTime: 0.05, destination: SIMD2<Float>(20, -60), threat: nil,
            evasive: false, origin: .zero, areaRadius: 150, grip: 1, obstacles: [], ground: flat) }
        _ = visual.update(driven)
        let treadAfter = visual.rootNode.simdConvertPosition(treadCentre, from: tread)
        let moving = MissionReplayVisualCapture.snapshot(id: "car", node: visual.rootNode,
            recorder: recorder, role: "target", camera: cameraNode)
        check(moving.assetID == initial.assetID && moving.nodeStates?.isEmpty == false,
            "wheel movement alone reuses the intact car archive")
        check(simd_distance(treadBefore, treadAfter) > 0.08, "the actual tread geometry moves, not just an empty axle node")
        check(abs(visual.rootNode.childNode(withName: GroundVehiclePart.wheelFrontLeft.rawValue,
            recursively: true)!.eulerAngles.x) > 0.1, "the actual wheel meshes roll with road movement")
        let scene = SCNScene()
        scene.rootNode.addChildNode(visual.rootNode)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.fieldOfView = 44
        camera.simdPosition = driven.state.position + SIMD3<Float>(11, 8, -13)
        camera.look(at: SCNVector3(driven.state.position + SIMD3<Float>(0, 1.5, 0)))
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 700
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-0.8, -0.6, 0); scene.rootNode.addChildNode(sun)
        scene.background.contents = NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.19, alpha: 1)
        if let device = MTLCreateSystemDefaultDevice() {
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene; renderer.pointOfView = camera
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1000, height: 700), antialiasingMode: .multisampling4X)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(model.rawValue + ".png"))
            }
        }
        let wheelPoint = driven.state.position + simd_act(driven.state.attitudeQuat,
            GroundVehiclePart.wheelFrontLeft.position(in: p))
        driven.receive(ImpactReport(componentID: GroundVehiclePart.wheelFrontLeft.rawValue,
            obstacleID: UUID(), obstacleSource: "fixture", material: .metalVehicle, acousticSurface: .metal,
            vehicleMaterial: .steel, impactEnergyJ: 80_000, normalClosingSpeed: 4, tangentialSpeed: 0,
            tier: .heavyImpact, damage: [], connectionDamage: [], contactPoint: wheelPoint,
            contactNormal: SIMD3<Float>(1, 0, 0), appliedImpulse: 0, detachedPartMotions: []))
        let pieces = visual.update(driven)
        check(pieces.count == 1 && pieces[0].childNodes.first?.childNodes.isEmpty == false,
            "a lost wheel separates with its actual tyre, rim and hub")
        check(!driven.contactProfile.spheres.contains { $0.componentID == GroundVehiclePart.wheelFrontLeft.rawValue },
            "a separated wheel no longer collides on the car")
        check(visual.update(driven).isEmpty, "the same wheel cannot detach twice")
        let chargeVisual = GroundVehicleVisual(model: model, directory: directory)
        let cleanCharge = MissionReplayVisualCapture.snapshot(id: "wreck", node: chargeVisual.rootNode, recorder: recorder)
        let blown = GroundVehicleRuntime(position: .zero, model: model, seed: 44)
        blown.receive(impactReport(2_000_000, GroundVehiclePart.engine.position(in: p), SIMD3<Float>(0, 0, -1)))
        let chargePieces = chargeVisual.update(blown)
        check(blown.damage.condition(.wheelFrontLeft) == 1 && blown.damage.condition(.wheelFrontRight) == 1,
            "An engine impact must not apply the removed radial wheel-destruction rule")
        check(chargeVisual.update(blown).isEmpty, "accident debris cannot be duplicated on following frames")
        for _ in 0..<600 { _ = blown.step(deltaTime: 0.05, destination: goal, threat: nil, evasive: false,
            origin: .zero, areaRadius: 150, grip: 1, obstacles: [], ground: flat) }
        _ = chargeVisual.update(blown)
        check(blown.effects.contains { $0.kind == .smoke } && blown.burnAge >= 29,
            "the wreck is still visibly burning/smoking after the previous effects would have disappeared")
        let burntCharge = MissionReplayVisualCapture.snapshot(id: "wreck", node: chargeVisual.rootNode, recorder: recorder)
        check(burntCharge.assetID != cleanCharge.assetID || burntCharge.nodeStates?.values.contains { ($0.materialTint?.x ?? 1) < 0.5 } == true,
            "charring is recorded in the changed mesh or material deltas")
        let wreckReplay = MissionReplayWorldVisuals(), wreckScene = SCNScene(), wreckRoot = SCNNode()
        wreckScene.rootNode.addChildNode(wreckRoot)
        wreckReplay.load(assets: recorder.currentSession!.visualAssets!, scene: wreckScene, playerRoot: wreckRoot)
        wreckReplay.update(MissionReplayWorldSnapshot(nodes: [burntCharge], effects: []))
        let burntMesh = wreckReplay.node(for: "wreck")!.childNode(withName: "CabLower_01", recursively: true)!
        let burntTint = (burntMesh.geometry?.firstMaterial?.multiply.contents as? NSColor)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1
        check(burntTint < 0.6, "a replay restores the charred paint on the real car")
        wreckReplay.update(MissionReplayWorldSnapshot(nodes: [cleanCharge], effects: []))
        let cleanMesh = wreckReplay.node(for: "wreck")!.childNode(withName: "CabLower_01", recursively: true)!
        let restoredTint = (cleanMesh.geometry?.firstMaterial?.multiply.contents as? NSColor)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1
        check(restoredTint > 0.9, "backward seeking restores the original paint, not a permanently burnt asset")
        let damaged = MissionReplayVisualCapture.snapshot(id: "car", node: visual.rootNode,
            recorder: recorder, role: "target", displayName: model.rawValue, camera: cameraNode)
        let fragment = MissionReplayVisualCapture.snapshot(id: "wheel", node: pieces[0], recorder: recorder)
        check(initial.assetID != damaged.assetID || damaged.nodeStates?.isEmpty == false,
            "mesh deformations create geometry versions while pose changes remain compact deltas")
        let world0 = MissionReplayWorldSnapshot(nodes: [initial], effects: [])
        let world1 = MissionReplayWorldSnapshot(nodes: [damaged, fragment], effects: [])
        let replayScene = SCNScene(), playerRoot = SCNNode()
        replayScene.rootNode.addChildNode(playerRoot)
        let replay = MissionReplayWorldVisuals()
        replay.load(assets: recorder.currentSession!.visualAssets!, scene: replayScene, playerRoot: playerRoot)
        replay.update(world1)
        let replayCar = replay.node(for: "car")!
        check(!replay.assetFailures && replay.node(for: "wheel") != nil,
            "the native car and separated wheel restore from recording assets")
        check(replayCar.childNode(withName: "wheel-mount-wheelFrontLeft", recursively: true)?.isHidden == true,
            "the lost wheel stays hidden on the restored car")
        check(damaged.camera != nil && simd_distance(damaged.camera!.pose.position,
            cameraNode.simdWorldPosition) < 0.001, "the car's own camera viewpoint is preserved")
        replay.update(world0)
        check(replay.node(for: "wheel") == nil &&
            replay.node(for: "car")!.childNode(withName: "wheel-mount-wheelFrontLeft", recursively: true)?.isHidden == false,
            "backward seeking restores the intact car and removes future wheel debris")
    }
}

// The burst is reconstructed from recorded age, including seeking backwards. It uses a
// bounded number of nodes and no actions or wall-clock particle emitters in the recorder.
let blastScene = SCNScene(), blastPlayer = SCNNode()
blastScene.rootNode.addChildNode(blastPlayer)
let blastReplay = MissionReplayWorldVisuals()
blastReplay.load(assets: [:], scene: blastScene, playerRoot: blastPlayer)
let blastID = UUID()
let burst = MissionReplayEffectSnapshot(id: blastID, kind: "explosion", position: .zero,
    normal: SIMD3<Float>(0, 1, 0), age: 0.12, lifetime: ChargeDetonation.effectLifetime)
let burstWorld = MissionReplayWorldSnapshot(nodes: [], effects: [burst])
blastReplay.update(burstWorld)
let burstNode = blastScene.rootNode.childNode(withName: "replay.effect.\(blastID)", recursively: true)!
let burstTransforms = burstNode.childNodes.map(\.simdTransform)
check(burstNode.childNodes.count <= 64 && burstNode.childNodes[0].opacity > 0,
    "a recorded detonation restores a visible core and a bounded fragment burst")
check(burstNode.childNodes.allSatisfy { $0.light == nil && ($0.particleSystems?.isEmpty ?? true) && !$0.hasActions },
    "the recorded burst cannot accumulate lights or wall-clock particle emitters")
blastReplay.update(burstWorld)
check(zip(burstNode.childNodes.map(\.simdTransform), burstTransforms).allSatisfy { simd_equal($0.0, $0.1) },
    "a paused detonation does not drift on wall-clock time")
blastReplay.update(MissionReplayWorldSnapshot(nodes: [], effects: []))
check(blastScene.rootNode.childNode(withName: "replay.effect.\(blastID)", recursively: true) == nil,
    "a detonation retires every visual node")
blastReplay.update(burstWorld)
let restoredBurst = blastScene.rootNode.childNode(withName: "replay.effect.\(blastID)", recursively: true)!
check(zip(restoredBurst.childNodes.map(\.simdTransform), burstTransforms).allSatisfy { simd_equal($0.0, $0.1) },
    "seeking backwards restores the same flash and fragment positions")

if failures.isEmpty { print("Ground vehicle probe: \(checks) checks passed") }
else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
