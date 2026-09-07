import AppKit
import SceneKit
import simd

// Where the authored launchers actually put the aircraft.
//
// ⚠️ This exists because both launcher collections were connected by assuming a height
// instead of reading one, and both put the aircraft somewhere it visibly was not standing.
// The catapult seated every airframe at a drafted 0.62 m deck while the four authored
// cradles sit at 1.49–3.20 m once scaled to the aircraft's own rail, so the aircraft was
// sunk into its launcher by up to 2.4 m — worst on the biggest one, which is why it read
// as "aircraft end up underneath them". The canister transports then repeated the shape of
// it three more times: a truck turned a half turn backwards so it fired through its own
// bed, a cover made of ten parts of which only one was ever faded, and an elevation sign
// that buried the muzzle instead of raising it.
//
// None of that is catchable by reasoning about the code — every version looked right — so
// the test is geometric: build the launcher and ask where its cradle or its cell ended up.

func bounds(_ node: SCNNode, _ reference: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
    var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    var found = false
    func walk(_ node: SCNNode) {
        if node.geometry != nil {
            let box = node.boundingBox
            let lo = SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z))
            let hi = SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))
            for corner in [lo, hi,
                           SIMD3<Float>(lo.x, lo.y, hi.z), SIMD3<Float>(lo.x, hi.y, lo.z),
                           SIMD3<Float>(hi.x, lo.y, lo.z), SIMD3<Float>(lo.x, hi.y, hi.z),
                           SIMD3<Float>(hi.x, lo.y, hi.z), SIMD3<Float>(hi.x, hi.y, lo.z)] {
                let inReference = reference.simdConvertPosition(corner, from: node)
                low = simd_min(low, inReference)
                high = simd_max(high, inReference)
            }
            found = true
        }
        for child in node.childNodes { walk(child) }
    }
    walk(node)
    return found ? (low, high) : nil
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let models = root.appendingPathComponent("DroneUAVDemo/Resources/Models")
var failures: [String] = []

// MARK: - Catapults

let catapults = CatapultAssetLoader(directory: models.appendingPathComponent("Launchers"))
print("Catapult cradles. The aircraft's origin is its belly, so the seat is the pad top.")
print(String(format: "  %-22@ %8@ %7@ %-14@ %9@",
             "aircraft" as NSString, "mass kg" as NSString, "rail m" as NSString,
             "launcher" as NSString, "seat y" as NSString))
// The six aircraft the catapult launches, each with the rail its own flight model asks for.
for (name, mass, rail, angle) in [("zipline-platform-1", Float(20.0), Float(4.2), Float(12.0)),
                                  ("aerosonde-mk-4-7", Float(36.3), Float(4.2), Float(12.0)),
                                  ("rq-21-integrator", Float(61.0), Float(4.2), Float(12.0)),
                                  ("ft5-los", Float(85.0), Float(5.4), Float(12.0)),
                                  ("rq-7b-shadow", Float(170.0), Float(6.5), Float(12.0)),
                                  ("hesa-karrar", Float(700.0), Float(9.0), Float(12.0))] {
    guard let node = catapults.makeLauncherNode(
        takeoffMassKg: mass, railLengthMeters: rail, railAngleDegrees: angle, deckHeight: 0.62)
    else { failures.append("\(name): no catapult built"); continue }
    guard let anchor = node.childNode(
        withName: CatapultAssetConstants.cradleAnchorNodeName, recursively: true)
    else { failures.append("\(name): catapult has no cradle anchor"); continue }
    let seat = node.simdConvertPosition(.zero, from: anchor)
    print(String(format: "  %-22@ %8.1f %7.1f %-14@ %9.3f", name as NSString, mass, rail,
                 (node.name ?? "-").replacingOccurrences(of: "catapult.catapult-", with: "") as NSString,
                 seat.y))
    // The cradle rides on top of the launcher, so the seat cannot be down at the drafted
    // deck height, and it cannot be above the launcher either.
    guard let whole = bounds(node, node) else { continue }
    if seat.y < 0.9 { failures.append(String(format: "%@: cradle at %.2f m is at ground level", name, seat.y)) }
    if seat.y > whole.max.y { failures.append(String(format: "%@: cradle at %.2f m is above the launcher", name, seat.y)) }
}

// MARK: - Canister transports

let canisters = CanisterAssetLoader(directory: models.appendingPathComponent("CanisterLaunchers"))
print("")
print("Canister transports. The scene's launch heading runs along -Z, so a correctly")
print("turned truck has the launch cell's cover at that end and the round behind it.")
print(String(format: "  %-14@ %5@ %-24@ %-24@",
             "aircraft" as NSString, "elev" as NSString, "seat" as NSString, "cover centre" as NSString))
for (profile, cell) in [("iai-harpy", "Cell_2_1"), ("iai-harpy-ng", "Cell_2_1"),
                        ("iai-harop", "Cell_2_2")] {
    for elevation in [Float(0.0), Float(18.0)] {
        guard let node = canisters.makeLauncherNode(profileID: profile, elevationDegrees: elevation)
        else { failures.append("\(profile): no transport built"); continue }
        guard let seatNode = node.childNode(
                withName: CanisterAssetConstants.launchCellAnchorNodeName, recursively: true),
              let muzzleNode = node.childNode(
                withName: CanisterAssetConstants.muzzleAnchorNodeName, recursively: true)
        else { failures.append("\(profile): transport has no launch anchors"); continue }
        let seat = node.simdConvertPosition(.zero, from: seatNode)
        let muzzle = node.simdConvertPosition(.zero, from: muzzleNode)

        var cellLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var cellHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var cap: SCNNode?
        node.enumerateHierarchy { child, _ in
            if child.name == "canister_muzzle_cap" { cap = child }
            guard let name = child.name, name.hasPrefix(cell), child.geometry != nil,
                  let box = bounds(child, node) else { return }
            cellLow = simd_min(cellLow, box.min)
            cellHigh = simd_max(cellHigh, box.max)
        }
        guard let cap, let capBox = bounds(cap, node) else {
            failures.append("\(profile): no canister_muzzle_cap"); continue
        }
        let capCentre = (capBox.min + capBox.max) * 0.5
        print(String(format: "  %-14@ %4.0f° (%6.2f,%6.2f,%6.2f)   (%6.2f,%6.2f,%6.2f)",
                     profile as NSString, elevation, seat.x, seat.y, seat.z,
                     capCentre.x, capCentre.y, capCentre.z))

        // The cover is on the muzzle face, so it has to sit at the cell's -Z half: this is
        // what catches a truck turned backwards. Comparing the muzzle anchor to the cell's
        // own minimum Z would prove nothing — the anchor is defined as that minimum.
        if capCentre.z > (cellLow.z + cellHigh.z) * 0.5 {
            failures.append("\(profile) at \(Int(elevation))°: cover faces away from the launch heading")
        }
        if seat.z <= muzzle.z {
            failures.append("\(profile) at \(Int(elevation))°: round is at or ahead of the muzzle")
        }
        if seat.y < cellLow.y || seat.y > cellHigh.y {
            failures.append("\(profile) at \(Int(elevation))°: round is outside its own cell")
        }
        // One cover, not ten loose parts: the presentation fades a single named node.
        if cap.childNodes.count < 2 {
            failures.append("\(profile): cover is \(cap.childNodes.count) part, expected the whole cover")
        }
    }
}

// Elevation has to raise the muzzle. Both launchers had this backwards.
for profile in ["iai-harpy", "iai-harop"] {
    guard let level = canisters.makeLauncherNode(profileID: profile, elevationDegrees: 0.0),
          let raised = canisters.makeLauncherNode(profileID: profile, elevationDegrees: 18.0),
          let levelCap = level.childNode(withName: "canister_muzzle_cap", recursively: true),
          let raisedCap = raised.childNode(withName: "canister_muzzle_cap", recursively: true),
          let levelBox = bounds(levelCap, level), let raisedBox = bounds(raisedCap, raised)
    else { continue }
    let rise = (raisedBox.min.y + raisedBox.max.y) * 0.5 - (levelBox.min.y + levelBox.max.y) * 0.5
    print(String(format: "  %-14@ muzzle rise at 18°: %+.3f m", profile as NSString, rise))
    if rise <= 0.05 {
        failures.append(String(format: "%@: elevating to 18° moved the muzzle %+.2f m", profile, rise))
    }
}

print("")
if failures.isEmpty {
    print("OK — every launcher seats its aircraft where its own geometry says it should")
} else {
    print("\(failures.count) placement problem(s):")
    for line in failures { print("  \(line)") }
    exit(1)
}
