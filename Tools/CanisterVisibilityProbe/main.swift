import SceneKit

// Regression: returning to offline mode while enclosed previously revealed the
// unfolded airframe, and a camera refresh could reveal a spectator's airframe.
var visibility = LocalAircraftPresentationVisibility()
let aircraft = SCNNode()
var failures: [String] = []
func check(_ expected: Bool, _ label: String) {
    aircraft.isHidden = visibility.isHidden
    if aircraft.isHidden != expected { failures.append(label) }
}
visibility.enclosed = true
check(true, "enclosed immediately")
visibility.spectator = false
check(true, "offline fleet refresh must preserve enclosure")
visibility.spectator = true
check(true, "spectator while enclosed")
visibility.enclosed = false
check(true, "camera/cover refresh must preserve spectator")
visibility.spectator = false
check(false, "ordinary visible aircraft after both constraints clear")
visibility.enclosed = true
check(true, "reset/rearm encloses again")
visibility.enclosed = false
check(false, "removing enclosure restores ordinary visibility")
if !failures.isEmpty { fatalError(failures.joined(separator: "\n")) }
print("PASS: enclosure, offline/fleet refresh, spectator, reset and restore")
