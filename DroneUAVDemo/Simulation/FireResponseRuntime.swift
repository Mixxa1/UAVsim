import Foundation
import simd

/// Pure scenario logic for the fire-response mission: tracks per-tree burn state and spread
/// timers, and converts hose-aim + spray input into suppression progress each tick.
///
/// Holds no SceneKit state — the simulation view model feeds it the tree index the hose nozzle is
/// currently aimed at (or `nil`) plus whether the hose is actively spraying, each tick. Mirrors
/// `MissionScenarioRuntime`'s "pure struct, dwell-accumulator" philosophy, generalized to many
/// independently-tracked targets plus a spread mechanic SAR never needed.
struct FireResponseRuntime {
    let configuration: MissionScenarioConfiguration
    let placement: FireZonePlacement
    let hoseTuning: FireHoseTuning

    private(set) var treeStatuses: [FireTreeStatus]
    private(set) var objectiveState: FireResponseObjectiveState = .active
    private(set) var outcome: FireResponseOutcome?
    private(set) var remainingSeconds: Double
    private(set) var elapsedSeconds: Double = 0.0

    /// Per-tree-index countdown to the next spread ignition; only present for currently-burning
    /// trees.
    private var spreadCountdowns: [Int: Double] = [:]

    init(configuration: MissionScenarioConfiguration, placement: FireZonePlacement) {
        self.configuration = configuration
        self.placement = placement
        self.hoseTuning = .default
        self.remainingSeconds = configuration.parameters.timeLimitSeconds

        var statuses = [FireTreeStatus](repeating: .unburned, count: placement.treePositions.count)
        for index in placement.initiallyBurningIndices {
            statuses[index] = .burning(ignitedAtSeconds: 0, suppressionProgress: 0)
        }
        treeStatuses = statuses

        var countdowns: [Int: Double] = [:]
        for index in placement.initiallyBurningIndices {
            countdowns[index] = configuration.parameters.difficulty.fireSpreadIntervalSeconds
        }
        spreadCountdowns = countdowns
    }

    var isActive: Bool { outcome == nil }

    var burningCount: Int {
        treeStatuses.reduce(into: 0) { count, status in
            if case .burning = status { count += 1 }
        }
    }

    var charredCount: Int {
        treeStatuses.reduce(into: 0) { count, status in
            if case .charred = status { count += 1 }
        }
    }

    var remainingClampedSeconds: Double { max(0.0, remainingSeconds) }

    /// 0...1 suppression progress of a given tree (for HUD feedback on the tree currently in the
    /// hose's cone). Returns 0 for anything not currently burning.
    func suppressionProgress(for treeIndex: Int?) -> Double {
        guard let treeIndex, treeStatuses.indices.contains(treeIndex),
              case .burning(_, let progress) = treeStatuses[treeIndex] else { return 0.0 }
        return min(1.0, progress / hoseTuning.suppressionDwellSeconds)
    }

    mutating func tick(deltaTime: Double, aimedFireIndex: Int?, isSpraying: Bool) {
        guard isActive, objectiveState == .active, deltaTime > 0 else { return }

        elapsedSeconds += deltaTime
        remainingSeconds -= deltaTime

        applySuppression(deltaTime: deltaTime, aimedFireIndex: aimedFireIndex, isSpraying: isSpraying)
        applySpread(deltaTime: deltaTime)

        if burningCount == 0 {
            objectiveState = .allExtinguished
            outcome = .success(elapsedSeconds: elapsedSeconds)
            return
        }

        if remainingSeconds <= 0.0 {
            remainingSeconds = 0.0
            objectiveState = .failedTimeout
            outcome = .failureTimeout
        }
    }

    /// Marks the mission aborted (e.g. operator exits early) if it hasn't already concluded.
    mutating func abort() {
        guard isActive else { return }
        outcome = .aborted
    }

    /// Debug/test hook: extinguishes the nearest currently-burning tree outright, bypassing the
    /// hose-aim requirement. Used by increment 1's temporary manual-test key before the real hose
    /// payload (increment 2) exists.
    mutating func debugExtinguishNearestFire(to worldPosition2D: SIMD2<Float>) {
        guard isActive, objectiveState == .active else { return }
        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for index in treeStatuses.indices {
            guard case .burning = treeStatuses[index] else { continue }
            let distance = simd_distance(worldPosition2D, placement.treePositions[index])
            guard distance < bestDistance else { continue }
            bestDistance = distance
            bestIndex = index
        }
        guard let index = bestIndex else { return }
        treeStatuses[index] = .charred
        spreadCountdowns.removeValue(forKey: index)
    }

    /// Instant area-of-effect suppression for the fire-capsule payload: a capsule bursts on impact
    /// and clears everything burning within its blast radius at once, unlike the hose's single
    /// continuously-aimed target. Trees are planted flat (`groundY = 0.0` in
    /// `DroneSceneController.spawnFireResponseScenario`), so a pure 2D XZ distance check is exactly
    /// right — no canopy-height/raycast concern.
    mutating func extinguishTreesInRadius(center: SIMD2<Float>, radiusMeters: Float) {
        guard isActive, objectiveState == .active else { return }
        for index in treeStatuses.indices {
            guard case .burning = treeStatuses[index] else { continue }
            guard simd_distance(center, placement.treePositions[index]) <= radiusMeters else { continue }
            treeStatuses[index] = .charred
            spreadCountdowns.removeValue(forKey: index)
        }
    }

    // MARK: - Suppression

    private mutating func applySuppression(deltaTime: Double, aimedFireIndex: Int?, isSpraying: Bool) {
        for index in treeStatuses.indices {
            guard case .burning(let ignitedAt, let progress) = treeStatuses[index] else { continue }

            let isBeingSuppressed = isSpraying && aimedFireIndex == index
            if isBeingSuppressed {
                let newProgress = progress + deltaTime
                if newProgress >= hoseTuning.suppressionDwellSeconds {
                    treeStatuses[index] = .charred
                    spreadCountdowns.removeValue(forKey: index)
                } else {
                    treeStatuses[index] = .burning(ignitedAtSeconds: ignitedAt, suppressionProgress: newProgress)
                }
            } else if progress > 0 {
                // Not currently held in the hose's aim — decay back toward zero so partial
                // progress can't be "banked" by strafing between multiple fires.
                let decayed = max(0.0, progress - deltaTime)
                treeStatuses[index] = .burning(ignitedAtSeconds: ignitedAt, suppressionProgress: decayed)
            }
        }
    }

    // MARK: - Spread

    private mutating func applySpread(deltaTime: Double) {
        let burningIndices = treeStatuses.indices.filter {
            if case .burning = treeStatuses[$0] { return true }
            return false
        }

        for index in burningIndices {
            guard var countdown = spreadCountdowns[index] else { continue }
            countdown -= deltaTime
            if countdown > 0 {
                spreadCountdowns[index] = countdown
                continue
            }

            spreadCountdowns.removeValue(forKey: index)
            guard let targetIndex = nearestUnburnedTree(to: index) else { continue }
            treeStatuses[targetIndex] = .burning(ignitedAtSeconds: elapsedSeconds, suppressionProgress: 0)
            spreadCountdowns[targetIndex] = configuration.parameters.difficulty.fireSpreadIntervalSeconds
        }
    }

    private func nearestUnburnedTree(to sourceIndex: Int) -> Int? {
        let sourcePosition = placement.treePositions[sourceIndex]
        let spreadRadius = configuration.parameters.difficulty.fireSpreadRadiusMeters

        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for index in treeStatuses.indices where treeStatuses[index] == .unburned {
            let distance = simd_distance(sourcePosition, placement.treePositions[index])
            guard distance <= spreadRadius, distance < bestDistance else { continue }
            bestDistance = distance
            bestIndex = index
        }
        return bestIndex
    }
}
