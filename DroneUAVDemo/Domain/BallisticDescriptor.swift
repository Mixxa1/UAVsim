import Foundation
import simd

/// How a released object falls through air.
///
/// Everything that leaves an aircraft — a capsule, a cargo box, a rescue pack — needs three
/// numbers to have a real trajectory: mass, drag coefficient and frontal area. Mass the payload
/// catalog already knows; the other two did not exist anywhere in the project, because until now
/// nothing fell through air at all. Dropped objects moved on a hand-written `s = ½gt²` curve with
/// their horizontal position frozen at the release point.
///
/// Frontal area is derived from mass and a characteristic bulk density rather than stored as its
/// own constant. Storing it separately invites the two numbers to drift apart — a heavier rigged
/// capsule with the area of the light one — and the derivation is the same one a person would do
/// on paper: a 2.25 kg water capsule is 2.25 litres of water, which is a 16 cm sphere.
struct BallisticDescriptor: Hashable {
    /// Falling mass, kilograms. Never zero — a massless projectile has infinite deceleration.
    let massKg: Float
    /// Drag coefficient of the shape, dimensionless.
    let dragCoefficient: Float
    /// Frontal (reference) area presented to the airflow, m².
    let referenceAreaSqM: Float
    /// Fraction of the impact-normal speed retained in a bounce, 0...1.
    ///
    /// Zero means the object stops dead where it lands, which is what a water capsule bursting and
    /// a sandbagged rescue pack both do. A crate dropped onto tarmac does not.
    let restitution: Float
    /// Tumble rate the object picks up per unit airspeed, rad/s per m/s.
    ///
    /// A released object is not aerodynamically stable — it was never meant to fly — so it tumbles,
    /// faster the harder the air is hitting it. Purely presentational: the drag model here is
    /// orientation-independent, so tumbling does not feed back into the trajectory.
    let tumbleRatePerAirspeed: Float
    /// Optional recovery canopy.
    let parachute: Parachute?

    /// A canopy that opens partway down and changes what the object is, aerodynamically.
    struct Parachute: Hashable {
        /// Delay from release to inflation. Real canopies are set to clear the aircraft first.
        let deployDelaySeconds: Float
        let dragCoefficient: Float
        let areaSqM: Float

        /// Standard cargo canopy sized for the load, at roughly 6 m/s of descent.
        ///
        /// Solved from terminal velocity rather than picked: the area a canopy needs is
        /// `2mg / (ρ·Cd·v²)`, so sizing it by target descent rate is both the honest derivation and
        /// the one that keeps a heavy load under a correspondingly larger chute.
        static func standardCargo(massKg: Float, descentRateMps: Float = 6.0) -> Parachute {
            let dragCoefficient: Float = 1.4  // Round canopy.
            let area = 2.0 * massKg * AtmosphereModel.gravityMps2
                / (AtmosphereModel.seaLevelDensity * dragCoefficient
                   * max(1.0, descentRateMps * descentRateMps))
            return Parachute(
                deployDelaySeconds: 1.2,
                dragCoefficient: dragCoefficient,
                areaSqM: max(0.05, area)
            )
        }
    }

    init(
        massKg: Float,
        dragCoefficient: Float,
        referenceAreaSqM: Float,
        restitution: Float = 0.0,
        tumbleRatePerAirspeed: Float = 0.0,
        parachute: Parachute? = nil
    ) {
        self.massKg = max(0.01, massKg)
        self.dragCoefficient = max(0.0, dragCoefficient)
        self.referenceAreaSqM = max(0.0001, referenceAreaSqM)
        self.restitution = min(0.95, max(0.0, restitution))
        self.tumbleRatePerAirspeed = max(0.0, tumbleRatePerAirspeed)
        self.parachute = parachute
    }

    /// The same object once its canopy has inflated.
    func deployed() -> BallisticDescriptor {
        guard let parachute else {
            return self
        }
        return BallisticDescriptor(
            massKg: massKg,
            // The canopy dominates; the payload's own drag is inside the rounding.
            dragCoefficient: parachute.dragCoefficient,
            referenceAreaSqM: parachute.areaSqM,
            restitution: 0.0,        // A load under canopy settles, it does not bounce.
            tumbleRatePerAirspeed: 0.0,
            parachute: nil
        )
    }

    /// Ballistic coefficient in the drag-per-unit-mass sense: `Cd·A/m`, m²/kg.
    ///
    /// The only combination of the three that the equation of motion actually uses, so it is worth
    /// naming — a projectile with a low value here falls close to vacuum ballistics, a high one
    /// reaches terminal velocity almost at once.
    var dragAreaPerMass: Float {
        dragCoefficient * referenceAreaSqM / massKg
    }

    /// Steady-state fall speed in air of the given density, m/s.
    ///
    /// Diagnostic rather than simulation input — the integrator reaches this on its own. Printed by
    /// `Tools/BallisticDropProbe` so the numbers behind a drop are inspectable without flying one.
    func terminalVelocity(airDensity: Float) -> Float {
        let denominator = airDensity * dragCoefficient * referenceAreaSqM
        guard denominator > 1e-9 else {
            return .greatestFiniteMagnitude
        }
        return sqrt(2.0 * massKg * AtmosphereModel.gravityMps2 / denominator)
    }

    // MARK: - Shapes

    /// Characteristic shape of a released object, supplying the drag coefficient and the way its
    /// frontal area follows from its mass.
    ///
    /// These are textbook coefficients for the bluff bodies involved, not measured values for any
    /// specific product — a dropped payload is not an aerodynamic object and there is nothing to
    /// look up. The bulk densities are the assumption doing the real work: they set how large the
    /// object is for its mass, and therefore how much of its fall is drag-limited.
    enum Shape {
        /// A liquid-filled sphere: fire capsules. Water-dense, so it is small and falls near-ballistically.
        case liquidSphere
        /// A packed crate: cargo boxes. Light for its size, so drag matters much sooner.
        case crate
        /// A soft, loosely packed bundle: rescue packs, kit bags.
        case softPack
        /// Fallback for payloads with no specific shape — a compact instrument case.
        case compactCase
        /// A fragment thrown off by a collision: irregular, light for its size, bounces.
        case debris

        var dragCoefficient: Float {
            switch self {
            case .liquidSphere: return 0.47   // sphere
            case .crate: return 1.05          // cube, face-on
            case .softPack: return 0.80       // rounded, deformable bundle
            case .compactCase: return 0.90
            case .debris: return 1.20         // irregular, tumbling
            }
        }

        /// How much of the impact-normal speed survives a bounce.
        var restitution: Float {
            switch self {
            case .liquidSphere: return 0.0    // A water capsule bursts.
            case .crate: return 0.32
            case .softPack: return 0.12       // Lands soft, barely moves.
            case .compactCase: return 0.25
            case .debris: return 0.45
            }
        }

        /// Tumble rate per unit airspeed, rad/s per m/s.
        var tumbleRatePerAirspeed: Float {
            switch self {
            case .liquidSphere: return 0.05   // Near-symmetric; barely tumbles.
            case .crate: return 0.22
            case .softPack: return 0.16
            case .compactCase: return 0.20
            case .debris: return 0.55         // Fragments spin hard.
            }
        }

        /// Bulk density used to turn a mass into a size, kg/m³.
        var bulkDensityKgPerCubicMeter: Float {
            switch self {
            case .liquidSphere: return 1000.0 // water
            case .crate: return 250.0         // packed goods in a box
            case .softPack: return 200.0      // clothing, blankets, kit
            case .compactCase: return 600.0   // instrument in a padded case
            case .debris: return 400.0        // torn structure, mostly voids
            }
        }

        /// Frontal area for a body of this shape at the given mass, m².
        func referenceArea(massKg: Float) -> Float {
            let volume = max(1e-6, massKg / bulkDensityKgPerCubicMeter)
            switch self {
            case .liquidSphere:
                // Sphere: V = 4/3·π·r³ → frontal area π·r².
                let radius = cbrt(3.0 * volume / (4.0 * Float.pi))
                return Float.pi * radius * radius
            case .crate, .softPack, .compactCase, .debris:
                // Cube: V = s³ → frontal area s².
                let side = cbrt(volume)
                return side * side
            }
        }
    }

    init(massKg: Float, shape: Shape, parachute: Parachute? = nil) {
        self.init(
            massKg: massKg,
            dragCoefficient: shape.dragCoefficient,
            referenceAreaSqM: shape.referenceArea(massKg: max(0.01, massKg)),
            restitution: shape.restitution,
            tumbleRatePerAirspeed: shape.tumbleRatePerAirspeed,
            parachute: parachute
        )
    }
}

extension PayloadType {
    /// Shape a released unit of this payload falls with.
    ///
    /// Most entries never fall — a gimbal or a LiDAR module is bolted on for the whole sortie — but
    /// `releasePayloadVisual()` will drop whatever is mounted, so every case needs an answer rather
    /// than an optional the caller has to handle.
    var ballisticShape: BallisticDescriptor.Shape {
        switch self {
        case .cargoBox:
            return .crate
        case .rescuePack:
            return .softPack
        case .fireCapsuleLauncher:
            // The launcher itself, if the whole rack is jettisoned. Individual capsules use
            // `FireCapsuleSize.ballisticDescriptor` instead.
            return .compactCase
        case .cameraGimbal, .thermalCamera, .lidarModule, .laserRangefinder,
             .fireHose, .agriculturalSprayer, .sensorModule, .radioRelay, .custom:
            return .compactCase
        }
    }

    /// Whether a released unit of this payload comes down under a canopy.
    ///
    /// A rescue pack does: that is the whole point of it — the contents are meant to survive, and
    /// the people it is dropped near are meant not to be hit by it at 30 m/s. Nothing else in the
    /// catalogue is rigged for recovery.
    var hasRecoveryParachute: Bool {
        self == .rescuePack
    }

    /// Fall characteristics for a released unit of this payload at its configured mass.
    func ballisticDescriptor(massKg: Float) -> BallisticDescriptor {
        BallisticDescriptor(
            massKg: massKg,
            shape: ballisticShape,
            parachute: hasRecoveryParachute
                ? BallisticDescriptor.Parachute.standardCargo(massKg: massKg)
                : nil
        )
    }
}

extension FireCapsuleSize {
    /// Fall characteristics of one capsule of this size.
    ///
    /// A fire capsule is a water-filled sphere, so its size follows from `massKg` directly: the
    /// medium 2.25 kg round is 2.25 litres, a 16 cm ball. At the 30-60 m an aerial firefighter
    /// works from, drag changes the fall by only a few percent — what actually moves the impact
    /// point is the carrier's own velocity at release, which the old drop path ignored entirely.
    var ballisticDescriptor: BallisticDescriptor {
        BallisticDescriptor(massKg: massKg, shape: .liquidSphere)
    }
}
