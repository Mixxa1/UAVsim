import Foundation

/// The fiber-optic reel as physical onboard equipment — mass, a mount point, removable/replaceable —
/// independent of `PayloadConfiguration`. By *purpose* the fiber is a control link (see
/// `UAVControlLinkType`), not mission payload, so it occupies its own equipment slot and can be
/// carried alongside a camera/sprayer/etc. rather than competing with them for the one payload bay.
struct FiberSpoolModule: Hashable {
    var reelClass: FiberOpticReelClass
    /// The reel's *rigged* capacity — immutable at runtime. Payout is tracked separately in
    /// `deployedLengthMeters`: an earlier version drained mass by overwriting this field with the
    /// remaining length every tick, which silently compounded the consumption math (each tick's
    /// cumulative payout was re-subtracted from an already-reduced total), burning a 0.5 km reel
    /// in seconds of flight.
    var totalLengthMeters: Float
    /// Fiber already paid out this sortie — drives the live mass drain below without ever
    /// touching the rigged capacity.
    var deployedLengthMeters: Float = 0.0

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

    /// Live mass (hardware + fiber still wound on the drum) — drains toward
    /// `reelClass.hardwareOverheadKg` as fiber pays out.
    var spoolMassKg: Float {
        reelClass.massForLength(max(0.0, totalLengthMeters - deployedLengthMeters))
    }
}
