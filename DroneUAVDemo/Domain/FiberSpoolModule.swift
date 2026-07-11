import Foundation

/// The fiber-optic reel as physical onboard equipment — mass, a mount point, removable/replaceable —
/// independent of `PayloadConfiguration`. By *purpose* the fiber is a control link (see
/// `UAVControlLinkType`), not mission payload, so it occupies its own equipment slot and can be
/// carried alongside a camera/sprayer/etc. rather than competing with them for the one payload bay.
struct FiberSpoolModule: Hashable {
    var reelClass: FiberOpticReelClass
    var totalLengthMeters: Float

    init(
        reelClass: FiberOpticReelClass = .medium,
        totalLengthMeters: Float = 5000.0
    ) {
        self.reelClass = reelClass
        self.totalLengthMeters = min(
            max(totalLengthMeters, reelClass.lengthRangeMeters.lowerBound),
            reelClass.lengthRangeMeters.upperBound
        )
    }

    /// Full-reel mass (hardware + un-payed-out fiber) — drains toward `reelClass.hardwareOverheadKg`
    /// at runtime as fiber pays out (see `FiberLinkState`).
    var spoolMassKg: Float {
        reelClass.massForLength(totalLengthMeters)
    }
}
