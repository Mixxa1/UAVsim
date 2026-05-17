import Foundation

struct ReplayComparisonMetric: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var firstValue: Double?
    var secondValue: Double?
    var unit: String
    var delta: Double?
}

struct ReplayComparisonResult: Codable, Equatable {
    var firstReplayID: UUID
    var secondReplayID: UUID
    var metrics: [ReplayComparisonMetric]
    var summaryText: String
}
