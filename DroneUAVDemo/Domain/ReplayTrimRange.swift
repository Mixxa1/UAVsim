import Foundation

struct ReplayTrimRange: Codable, Equatable {
    var startTime: TimeInterval
    var endTime: TimeInterval

    init(startTime: TimeInterval, endTime: TimeInterval) {
        let safeStart = max(0, startTime.isFinite ? startTime : 0)
        let safeEnd = max(safeStart, endTime.isFinite ? endTime : safeStart)
        self.startTime = safeStart
        self.endTime = safeEnd
    }

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }

    func clamped(to duration: TimeInterval) -> ReplayTrimRange {
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        let start = min(max(0, startTime), safeDuration)
        let end = min(max(start, endTime), safeDuration)
        return ReplayTrimRange(startTime: start, endTime: end)
    }

    func contains(_ timestamp: TimeInterval) -> Bool {
        timestamp >= startTime && timestamp <= endTime
    }
}
