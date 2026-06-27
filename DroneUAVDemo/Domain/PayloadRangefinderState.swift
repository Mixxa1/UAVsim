import Foundation

struct PayloadRangefinderOpticsState: Codable, Equatable {
    var isAvailable: Bool
    var isPowered: Bool
    var isArmed: Bool
    var measuredDistanceMeters: Double?

    var minRangeMeters: Double
    var maxRangeMeters: Double

    var zoomLevel: Double
    var minZoom: Double
    var maxZoom: Double
    var baseFieldOfViewDegrees: Double
    var currentFieldOfViewDegrees: Double

    var gimbalYawDegrees: Double
    var gimbalPitchDegrees: Double

    var feedLabel: String

    init(
        isAvailable: Bool = true,
        isPowered: Bool = true,
        isArmed: Bool = false,
        measuredDistanceMeters: Double? = nil,
        minRangeMeters: Double = 2.0,
        maxRangeMeters: Double = 1500.0,
        zoomLevel: Double = 1.0,
        minZoom: Double = 1.0,
        maxZoom: Double = 50.0,
        baseFieldOfViewDegrees: Double = 45.0,
        currentFieldOfViewDegrees: Double = 45.0,
        gimbalYawDegrees: Double = 0.0,
        gimbalPitchDegrees: Double = -12.0,
        feedLabel: String = "LRF"
    ) {
        self.isAvailable = isAvailable
        self.isPowered = isPowered
        self.isArmed = isArmed
        self.measuredDistanceMeters = measuredDistanceMeters
        self.minRangeMeters = minRangeMeters
        self.maxRangeMeters = maxRangeMeters
        self.zoomLevel = zoomLevel
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.baseFieldOfViewDegrees = baseFieldOfViewDegrees
        self.currentFieldOfViewDegrees = currentFieldOfViewDegrees
        self.gimbalYawDegrees = gimbalYawDegrees
        self.gimbalPitchDegrees = gimbalPitchDegrees
        self.feedLabel = feedLabel
    }
}
