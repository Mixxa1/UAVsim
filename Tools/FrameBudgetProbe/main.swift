import Foundation

// Deterministic workloads exercise the production budget policy without depending on CPU speed.
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

func run(steps: Int, cost: Double, finalCost: Double = 0.001) -> (steps: Int, seconds: Double) {
    let budget = SimulationFrameBudget(maximumSteps: steps, seconds: (1.0 / 60.0) * 0.65)
    var elapsed = 0.0
    var presentations = 0
    var completed = 0
    for index in 0..<steps {
        let present = budget.shouldPresent(stepIndex: index, elapsed: elapsed)
        elapsed += cost + (present ? finalCost : 0)
        completed += 1
        if present {
            presentations += 1
            break
        }
    }
    check(presentations == 1, "\(steps)x must present exactly once")
    check(completed <= steps, "\(steps)x must never add a tick after reaching its limit")
    return (completed, elapsed)
}

for steps in [1, 2, 4, 8, 16, 32, 64] {
    let cheap = run(steps: steps, cost: 0.00001)
    check(cheap.steps == steps, "\(steps)x should deliver all requested cheap steps")
    let loaded = run(steps: steps, cost: 0.001)
    check(loaded.seconds < 1.0 / 60.0, "\(steps)x must leave room in a 60 Hz frame")
    print(String(format: "%2dx: %2d steps, %.2f ms at 1 ms/step", steps, loaded.steps, loaded.seconds * 1000))
}

let overloaded = run(steps: 64, cost: 0.020)
check(overloaded.steps == 2, "An expensive tick must immediately select the next step for presentation")
let zeroBudget = SimulationFrameBudget(maximumSteps: 64, seconds: 0)
check(zeroBudget.shouldPresent(stepIndex: 1, elapsed: 0.001), "An exhausted budget must present")
if !failures.isEmpty {
    failures.forEach { print("FAIL: \($0)") }
    exit(1)
}
print("PASS: requested speed, frame budget, overload recovery and one final presentation")
