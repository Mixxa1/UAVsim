import Foundation
import simd

// MARK: - Structural material

/// What an airframe's primary structure is built from. It decides *how* a part fails:
/// a carbon laminate stays straight and then snaps, an aluminium box buckles and creases
/// long before it tears, a moulded foam wing folds over and hangs on its skin.
///
/// ⚠️ Deliberately separate from `UAVSkinMaterial`, which exists for aerodynamic heating
/// and defaults to aluminium for the whole catalogue. Reading that default as structure
/// made an EPP-foam eBee and a carbon MQ-9 break like the same aluminium airframe.
enum VehicleStructuralMaterial: String, Hashable, Codable, CaseIterable {
    /// Moulded EPP/EPO foam around a spar (small survey wings).
    case expandedFoam
    case glassComposite
    case carbonComposite
    case aluminium
    case titanium
    case steel
    /// Injection-moulded shells over a light frame (consumer multirotors).
    case mouldedPolymer

    /// Extreme-fibre strain at the ultimate moment. Couples stiffness to strength:
    /// `EI = M_ult · (depth / 2) / ε`. Laminate failure strains (CFRP ≈ 1.2 %, GFRP ≈ 2 %),
    /// alloy yield strains σ_y/E (7075 ≈ 0.7 %, Ti-6Al-4V ≈ 0.77 %, 4130 HT ≈ 0.4 %),
    /// PC/ABS ≈ 2.5 %, foam-cored spar ≈ 3 %.
    var ultimateStrain: Float {
        switch self {
        case .expandedFoam: return 0.030
        case .glassComposite: return 0.020
        case .carbonComposite: return 0.012
        case .aluminium: return 0.0070
        case .titanium: return 0.0077
        case .steel: return 0.0040
        case .mouldedPolymer: return 0.025
        }
    }

    /// Fraction of the ultimate moment at which a joint stops being elastic. Laminates are
    /// linear almost to failure (first-ply failure at 85–90 %); thin-walled alloy sections
    /// buckle locally around three quarters. A foam wing bends on the carbon or glass spar
    /// buried in it, so in bending it yields like one; the foam's own early yield shows up in
    /// how easily it crushes (`crushStrengthPa`), not here.
    var yieldRatio: Float {
        switch self {
        case .expandedFoam: return 0.75
        case .glassComposite: return 0.85
        case .carbonComposite: return 0.90
        case .aluminium: return 0.75
        case .titanium: return 0.85
        case .steel: return 0.75
        case .mouldedPolymer: return 0.55
        }
    }

    /// Plastic hinge rotation a section absorbs between yield and rupture, radians. This is
    /// the material's toughness at structural scale: a creasing aluminium box turns through
    /// ~17° before it tears, a carbon spar barely 1.5°, a foam wing creases ~20° round its
    /// cracked spar before it lets go.
    var plasticRotationCapacity: Float {
        switch self {
        case .expandedFoam: return 0.35
        case .glassComposite: return 0.05
        case .carbonComposite: return 0.025
        case .aluminium: return 0.30
        case .titanium: return 0.25
        case .steel: return 0.40
        case .mouldedPolymer: return 0.35
        }
    }

    /// Share of a joint's shear/tension capacity that survives once its bending capacity is
    /// gone — torn skin, fabric and cabling that keep a broken panel hanging on the aircraft.
    var retainedSkinFraction: Float {
        switch self {
        case .expandedFoam: return 0.45
        case .glassComposite: return 0.25
        case .carbonComposite: return 0.15
        case .aluminium: return 0.30
        case .titanium: return 0.30
        case .steel: return 0.35
        case .mouldedPolymer: return 0.30
        }
    }

    /// Shear strength over normal strength. Sets torsion capacity of a closed box
    /// (`T/M = 2τ/σ`): ±45° plies leave laminates weak in shear, isotropic alloys follow
    /// von Mises (0.58).
    var shearToNormalStrength: Float {
        switch self {
        case .expandedFoam: return 0.50
        case .glassComposite: return 0.35
        case .carbonComposite: return 0.30
        case .aluminium, .titanium, .steel: return 0.58
        case .mouldedPolymer: return 0.50
        }
    }

    /// Structural damping ratio of the member.
    var dampingRatio: Float {
        switch self {
        case .expandedFoam: return 0.08
        case .glassComposite: return 0.025
        case .carbonComposite: return 0.020
        case .aluminium, .titanium, .steel: return 0.015
        case .mouldedPolymer: return 0.05
        }
    }

    /// How much ultimate strength a section loses per unit of its plastic capacity already
    /// spent: delaminated laminates lose a lot, work-hardening alloys very little.
    var strengthLossPerPlasticCapacity: Float {
        switch self {
        case .expandedFoam: return 0.35
        case .glassComposite: return 0.45
        case .carbonComposite: return 0.50
        case .aluminium, .titanium: return 0.10
        case .steel: return 0.05
        case .mouldedPolymer: return 0.30
        }
    }

    /// Effective crushing pressure of the built-up structure, Pa — what a skin-and-core or
    /// skin-and-stringer panel sustains while it folds up locally under a blunt contact.
    /// It bounds the force a strike can put into the airframe before the struck part simply
    /// crushes: honeycomb and foam-cored laminates crush at 2–5 MPa, stiffened aluminium
    /// panels around 2.5 MPa, EPP foam at a quarter of a megapascal.
    var crushStrengthPa: Float {
        switch self {
        case .expandedFoam: return 0.25e6
        case .glassComposite: return 3.0e6
        case .carbonComposite: return 4.0e6
        case .aluminium: return 2.5e6
        case .titanium: return 4.0e6
        case .steel: return 5.0e6
        case .mouldedPolymer: return 1.5e6
        }
    }

    /// Ultimate over limit load for a structure of this material. Airworthiness rules ask
    /// for 1.5 and also for no permanent deformation at limit load, so a material that
    /// yields at `yieldRatio` of its ultimate has to be built to `1/yieldRatio` of the limit
    /// load instead whenever that is larger.
    var ultimateOverLimit: Float {
        max(1.5, 1 / max(0.05, yieldRatio))
    }

    /// Slope of the normalised S–N curve, `S = 1 − b·log10(N)`: about 9 % of ultimate per
    /// decade of cycles for aerospace laminates and alloys at structural detail level.
    var fatigueSlopePerDecade: Float {
        switch self {
        case .expandedFoam, .mouldedPolymer: return 0.11
        case .glassComposite: return 0.10
        case .carbonComposite: return 0.08
        case .aluminium, .titanium, .steel: return 0.09
        }
    }

    /// The catalogue's known airframes. Everything else is inferred in `resolve`.
    private static let catalogue: [String: VehicleStructuralMaterial] = [
        // Moulded EPP/EPO survey wings.
        "sensefly-ebee-tac": .expandedFoam,
        "epfl-delta-wing-uav": .expandedFoam,
        "quantum-systems-trinity-pro": .expandedFoam,
        "zipline-platform-1": .expandedFoam,
        "wingtraone-gen-ii": .glassComposite,
        // Composite tactical and MALE airframes.
        "aerosonde-mk-4-7": .glassComposite,
        "rq-21-integrator": .glassComposite,
        "rq-7b-shadow": .glassComposite,
        "ft5-los": .glassComposite,
        "ncstate-bwb-delta": .glassComposite,
        "iai-harpy": .glassComposite,
        "iai-harop": .glassComposite,
        "iai-harpy-ng": .glassComposite,
        "mq-9a-reaper": .carbonComposite,
        "mq-9b-skyguardian": .carbonComposite,
        "hermes-900": .carbonComposite,
        "wingcopter-198": .carbonComposite,
        "rockwell-himat": .carbonComposite,
        // Metal target drones and research aircraft.
        "ryan-bqm-34f-firebee-ii": .aluminium,
        "northrop-aqm-35a": .aluminium,
        "northrop-aqm-35b": .aluminium,
        "hesa-karrar": .aluminium,
        "north-american-x-10": .aluminium,
        "hermeus-quarterhorse-mk21": .titanium,
        // Consumer multirotors: moulded shells, plastic or magnesium arms.
        "dji-mavic-3t": .mouldedPolymer,
        "dji-mavic-4-pro": .mouldedPolymer,
        "dji-neo": .mouldedPolymer,
        "dji-phantom-3-standard": .mouldedPolymer,
        "dji-matrice-4t": .mouldedPolymer,
        "dji-matrice-4td-dock-3": .mouldedPolymer,
        "fotokite-sigma": .mouldedPolymer,
        "brinc-lemur-2": .mouldedPolymer,
        "fpv-tiny-whoop-65": .mouldedPolymer
    ]

    static func resolve(profile: DroneModelProfile) -> VehicleStructuralMaterial {
        if let known = catalogue[profile.id] { return known }
        switch profile.skinMaterial {
        case .composite: return .carbonComposite
        case .titanium: return .titanium
        case .stainlessSteel: return .steel
        case .aluminium: break
        }
        // No explicit construction: infer from class and size. Multirotor frames are carbon
        // plate/tube except the smallest, which are moulded; small fixed wings are foam,
        // tactical ones composite, heavy ones metal.
        let mass = max(profile.takeoffMassKg, 0.01)
        switch profile.airframeClass {
        case .multirotor:
            return mass < 0.25 ? .mouldedPolymer : .carbonComposite
        case .fixedWing, .hybridVTOL:
            if mass < 8.0 { return .expandedFoam }
            return mass < 400.0 ? .glassComposite : .aluminium
        }
    }
}

// MARK: - Joint section

/// The physical section a joint carries: where it is, which way it is loaded, how much it
/// can take in every direction, and how stiff it is. Every structural connection has one,
/// so a single load path — the flight solver and the impact solver alike — evaluates the
/// whole airframe the same way.
///
/// Local axes: `spanAxis` runs parent→child along the member, `normalAxis` is the surface
/// normal (the direction lift pushes a wing), `chordAxis = span × normal`. Flap bending
/// (tip toward ±normal) turns about the chord axis, lag bending about the normal, torsion
/// about the span.
struct VehicleJointSection: Hashable {
    var anchor: SIMD3<Float>
    var spanAxis: SIMD3<Float>
    var normalAxis: SIMD3<Float>

    /// Ultimate moments/forces, SI units.
    var flapUltimateNm: Float
    var flapNegativeUltimateNm: Float
    var lagUltimateNm: Float
    var torsionUltimateNm: Float
    var shearUltimateN: Float
    var axialUltimateN: Float

    /// Discrete-beam spring constants of the joint: rotational N·m/rad, translational N/m.
    var flapStiffness: Float
    var lagStiffness: Float
    var torsionStiffness: Float
    var shearStiffness: Float
    var axialStiffness: Float

    var material: VehicleStructuralMaterial
    /// Part of a slender member discretised into stations (wing, tail surface, boom, arm).
    /// Those are solved as a flexible chain on impact; other joints as rigid attachments.
    var isMemberStation: Bool
    /// Which member the station belongs to ("wing.left", "arm.FL"...); empty otherwise.
    var memberID: String = ""

    var chordAxis: SIMD3<Float> {
        let raw = simd_cross(spanAxis, normalAxis)
        return simd_length_squared(raw) > 1e-10 ? simd_normalize(raw) : SIMD3<Float>(1, 0, 0)
    }

    /// Local load components of a joint load, given as the force and moment the parent must
    /// apply to the child subtree (body frame, moment about the anchor). Every moment
    /// component is signed as the *applied* load, the direction the child is being pushed:
    /// lift on a wing gives positive flap, and a plastic hinge turns the same way.
    func localLoad(force: SIMD3<Float>, moment: SIMD3<Float>) -> VehicleJointLoad {
        let chord = chordAxis
        return VehicleJointLoad(
            axial: -simd_dot(force, spanAxis),
            shearNormal: -simd_dot(force, normalAxis),
            shearChord: -simd_dot(force, chord),
            torsion: -simd_dot(moment, spanAxis),
            flap: -simd_dot(moment, chord),
            lag: -simd_dot(moment, normalAxis)
        )
    }

    /// Combined utilisation of the section (1 = ultimate), quadratic interaction of bending
    /// about both axes with torsion, plus the transverse and axial force terms.
    func utilisation(of load: VehicleJointLoad, residual: Float) -> Float {
        let scale = max(0.005, residual)
        let flapCapacity = (load.flap >= 0 ? flapUltimateNm : flapNegativeUltimateNm) * scale
        let bending = load.flap / max(0.001, flapCapacity)
        let lag = load.lag / max(0.001, lagUltimateNm * scale)
        let torsion = load.torsion / max(0.001, torsionUltimateNm * scale)
        let shear = load.shear / max(0.001, shearUltimateN * scale)
        let tension = max(0, load.axial) / max(0.001, axialUltimateN * scale)
        return sqrt(bending * bending + lag * lag + torsion * torsion + shear * shear + tension * tension)
    }

    /// Bending/torsion part of the utilisation only — what drives plastic hinge rotation.
    func momentUtilisation(of load: VehicleJointLoad, residual: Float) -> Float {
        let scale = max(0.005, residual)
        let flapCapacity = (load.flap >= 0 ? flapUltimateNm : flapNegativeUltimateNm) * scale
        let bending = load.flap / max(0.001, flapCapacity)
        let lag = load.lag / max(0.001, lagUltimateNm * scale)
        let torsion = load.torsion / max(0.001, torsionUltimateNm * scale)
        return sqrt(bending * bending + lag * lag + torsion * torsion)
    }

    /// Transverse/axial part — sections fail in shear or tension without a plastic hinge.
    func forceUtilisation(of load: VehicleJointLoad, residual: Float) -> Float {
        let scale = max(0.005, residual)
        let shear = load.shear / max(0.001, shearUltimateN * scale)
        let tension = max(0, load.axial) / max(0.001, axialUltimateN * scale)
        return max(shear, tension)
    }

    /// Body-frame rotation vector from local hinge components (torsion, flap, lag). Positive
    /// flap rotation turns the tip toward +normal.
    func bodyRotation(torsion: Float, flap: Float, lag: Float) -> SIMD3<Float> {
        spanAxis * torsion + chordAxis * flap + normalAxis * lag
    }

    /// Local components (torsion, flap, lag) of a body-frame rotation vector.
    func localRotation(_ rotation: SIMD3<Float>) -> (torsion: Float, flap: Float, lag: Float) {
        (simd_dot(rotation, spanAxis), simd_dot(rotation, chordAxis), simd_dot(rotation, normalAxis))
    }
}

struct VehicleJointLoad: Hashable {
    var axial: Float
    var shearNormal: Float
    var shearChord: Float
    var torsion: Float
    var flap: Float
    var lag: Float

    var shear: Float { sqrt(shearNormal * shearNormal + shearChord * shearChord) }
    static let zero = VehicleJointLoad(axial: 0, shearNormal: 0, shearChord: 0, torsion: 0, flap: 0, lag: 0)

    static func + (lhs: VehicleJointLoad, rhs: VehicleJointLoad) -> VehicleJointLoad {
        VehicleJointLoad(axial: lhs.axial + rhs.axial, shearNormal: lhs.shearNormal + rhs.shearNormal,
                         shearChord: lhs.shearChord + rhs.shearChord, torsion: lhs.torsion + rhs.torsion,
                         flap: lhs.flap + rhs.flap, lag: lhs.lag + rhs.lag)
    }
}

/// The largest load of each kind a joint sees across a set of design cases.
struct VehicleJointEnvelope: Hashable {
    var flapPositive: Float = 0
    var flapNegative: Float = 0
    var lag: Float = 0
    var torsion: Float = 0
    var shear: Float = 0
    var tension: Float = 0
    /// Every design load the envelope was built from. The component maxima alone are not
    /// enough to size a section: the check is a combined one, and a case at full bending and
    /// full torsion together is √2 over a section that only covers each of them apart.
    var cases: [VehicleJointLoad] = []

    mutating func include(_ load: VehicleJointLoad) {
        cases.append(load)
        flapPositive = max(flapPositive, load.flap)
        flapNegative = max(flapNegative, -load.flap)
        lag = max(lag, abs(load.lag))
        torsion = max(torsion, abs(load.torsion))
        shear = max(shear, load.shear)
        tension = max(tension, load.axial)
    }
}

extension VehicleJointSection {
    /// This section with every capacity raised to at least the envelope times `factor`.
    /// Stiffness follows strength (the failure strain is a property of the material), so
    /// each spring is raised by the same ratio as the capacity it belongs to.
    func raised(to envelope: VehicleJointEnvelope, factor: Float) -> VehicleJointSection {
        var section = self
        func raise(_ current: Float, _ demand: Float) -> (value: Float, ratio: Float) {
            let target = max(current, demand * factor)
            return (target, current > 1e-6 ? target / current : 1)
        }
        let flap = raise(flapUltimateNm, envelope.flapPositive)
        let flapNeg = raise(flapNegativeUltimateNm, envelope.flapNegative)
        let lag = raise(lagUltimateNm, envelope.lag)
        let torsion = raise(torsionUltimateNm, envelope.torsion)
        let shear = raise(shearUltimateN, envelope.shear)
        let axial = raise(axialUltimateN, envelope.tension)
        section.flapUltimateNm = flap.value
        section.flapNegativeUltimateNm = flapNeg.value
        section.lagUltimateNm = lag.value
        section.torsionUltimateNm = torsion.value
        section.shearUltimateN = shear.value
        section.axialUltimateN = axial.value
        section.flapStiffness *= max(flap.ratio, flapNeg.ratio)
        section.lagStiffness *= lag.ratio
        section.torsionStiffness *= torsion.ratio
        section.shearStiffness *= shear.ratio
        section.axialStiffness *= axial.ratio
        // Then the combined check, case by case: wherever a design case still exceeds the
        // section under the interaction the airframe is judged by, the whole section grows
        // by that ratio. Uniformly, because which of spar cap and skin a designer thickens is
        // not knowable here — only that the combination has to pass.
        let worst = envelope.cases.reduce(Float(0)) { max($0, section.utilisation(of: $1, residual: 1)) } * factor
        if worst > 1 {
            section.flapUltimateNm *= worst
            section.flapNegativeUltimateNm *= worst
            section.lagUltimateNm *= worst
            section.torsionUltimateNm *= worst
            section.shearUltimateN *= worst
            section.axialUltimateN *= worst
            section.flapStiffness *= worst
            section.lagStiffness *= worst
            section.torsionStiffness *= worst
            section.shearStiffness *= worst
            section.axialStiffness *= worst
        }
        return section
    }
}

/// What happened to a joint's bending capacity.
enum VehicleJointFracture: String, Hashable, Codable {
    case intact
    /// Bending capacity gone; torn skin still holds the child on — a folded, hanging panel.
    case hinged
    case separated
}

// MARK: - Section design

/// Sizes the sections of a discretised member from the loads the airframe is designed to
/// carry, so the strength of every station is a consequence of physics rather than a table.
///
/// ⚠️ Every number here is a stated design rule, not a tuning knob:
/// - Ultimate load factor 3.75 = 2.5 g limit (CS-25/FAR-25, the lowest civil category) ×
///   1.5 ultimate factor — the same pair `VehicleComponentGraph.makeConnections` uses.
/// - Negative flap capacity 0.4 × positive: the negative limit load factor of the normal
///   category (−0.4 n) — structures designed to it are weaker bending tip-down, which is
///   why hard landings, not upward strikes, fold wings down.
/// - Minimum gauge `φ = 0.5`: a skin of constant thickness gives flange area ∝ chord and
///   lever ∝ depth, so an outboard section keeps `φ · M_root · (c·h)/(c₀·h₀)` however
///   little design load reaches it. φ = 0.5 says half the root's material is gauge-driven
///   and half load-driven — typical of small and tactical composite wings.
/// - Fitting factor 1.15 on the root attachment (CS-25.625): fittings are stronger than the
///   structure next to them, so a wing breaks just outboard of its root, not at the bolt.
/// - Lag capacity `max(1, 0.35·c/h)` × flap: the in-plane section modulus is set by the box
///   width (≈ half chord) instead of its depth.
enum VehicleSectionDesign {
    /// Transport-category floor used where nothing better is known.
    static let ultimateLoadFactor: Float = 3.75
    static let negativeFlapRatio: Float = 0.4

    /// Positive limit manoeuvring load factor of the normal category (CS-23.337, adopted by
    /// STANAG 4671 for unmanned aircraft): `2.1 + 24000/(W + 10000)` with W in pounds, not
    /// less than 2.5 and not more than 3.8. A 20 kg survey wing is a 3.8 g airframe, an
    /// MQ-9B about 3.2 g, a 19-tonne X-10 2.6 g.
    static func manoeuvreLimitLoadFactor(designMassKg: Float) -> Float {
        let pounds = max(0, designMassKg) * 2.20462
        return min(3.8, max(2.5, 2.1 + 24_000 / (pounds + 10_000)))
    }

    /// Gust limit load factor (CS-23.341): a 50 ft/s derived gust at cruise speed,
    /// `n = 1 + K_g·ρ₀·U·V·a / (2·W/S)`, alleviated by `K_g = 0.88μ/(5.3 + μ)` with the mass
    /// ratio `μ = 2(W/S)/(ρ c̄ a g)`. Light, slow, lightly loaded wings — most small UAVs — are
    /// sized by this rather than by manoeuvre, which is why they are so much stronger than
    /// their weight suggests.
    static func gustLimitLoadFactor(wingLoadingPa: Float, meanChordM: Float, liftSlopePerRad: Float, speedMps: Float) -> Float {
        let rho: Float = 1.225
        let loading = max(1, wingLoadingPa)
        let slope = max(1, liftSlopePerRad)
        let mu = 2 * loading / (rho * max(0.02, meanChordM) * slope * 9.81)
        let alleviation = 0.88 * mu / (5.3 + mu)
        return 1 + alleviation * rho * 15.24 * max(1, speedMps) * slope / (2 * loading)
    }
    static let minimumGaugeFraction: Float = 0.5
    static let rootFittingFactor: Float = 1.15
    static let lagInPlaneEfficiency: Float = 0.35

    struct Station {
        let id: String
        /// Inboard joint on the elastic axis, body frame.
        let anchor: SIMD3<Float>
        let spanAxis: SIMD3<Float>
        let normalAxis: SIMD3<Float>
        /// Joint-to-joint length along the span.
        let length: Float
        let chord: Float
        let depth: Float
        /// Mass carried outboard of the joint that is not part of later stations
        /// (station structure plus anything mounted on it), and its centre.
        let mass: Float
        let massCenter: SIMD3<Float>
        /// Design ultimate force this station contributes (lift on a lifting surface, rotor
        /// thrust on an arm), along +normal, and where it acts.
        let designForce: Float
        let designForceCenter: SIMD3<Float>
    }

    /// Sections for a chain of stations ordered root → tip.
    static func sections(
        for stations: [Station],
        memberID: String,
        material: VehicleStructuralMaterial,
        ultimateLoadFactor: Float,
        constantSection: Bool,
        symmetricFlap: Bool,
        scatter: (String) -> Float
    ) -> [String: VehicleJointSection] {
        guard !stations.isEmpty else { return [:] }
        let g: Float = 9.81
        // Design moment/shear at each joint: outboard forces minus outboard inertia at the
        // ultimate load factor, taken about the joint along the member. The design forces
        // arrive already at ultimate.
        var designMoment: [Float] = []
        var designShear: [Float] = []
        for (index, joint) in stations.enumerated() {
            var moment: Float = 0
            var shear: Float = 0
            for outboard in stations[index...] {
                let designForce = outboard.designForce
                let force = designForce - ultimateLoadFactor * outboard.mass * g
                let leverForce = simd_dot(outboard.designForceCenter - joint.anchor, joint.spanAxis)
                let leverMass = simd_dot(outboard.massCenter - joint.anchor, joint.spanAxis)
                moment += designForce * max(0, leverForce)
                    - ultimateLoadFactor * outboard.mass * g * max(0, leverMass)
                shear += force
            }
            designMoment.append(max(0, moment))
            designShear.append(abs(shear))
        }
        let root = stations[0]
        let rootMoment = max(0.01, designMoment[0])
        let rootSection = max(1e-6, root.chord * root.depth)
        let span = stations.reduce(Float(0)) { $0 + $1.length }

        var result: [String: VehicleJointSection] = [:]
        for (index, station) in stations.enumerated() {
            let sectionRatio = constantSection ? 1 : max(0.02, station.chord * station.depth / rootSection)
            let gauge = minimumGaugeFraction * rootMoment * sectionRatio
            let jitter = scatter(station.id)
            let fitting: Float = index == 0 ? rootFittingFactor : 1
            let flap = max(designMoment[index], gauge, constantSection ? rootMoment : 0) * jitter * fitting
            let flapNegative = symmetricFlap ? flap : max(negativeFlapRatio * designMoment[index], gauge,
                                   constantSection ? rootMoment : 0) * jitter * fitting
            // A section can always pass on the load its own skin bears before it crushes:
            // its shear area (about half the cross-section) at the material's shear share of
            // the crush strength, and that force over one section depth in bending. Without
            // this floor a tip with almost no design load is paper, and every wingtip would
            // shear off before it could even dent.
            let sectionShear = material.shearToNormalStrength * material.crushStrengthPa
                * max(0.001, station.chord) * max(0.001, station.depth) * 0.5 * jitter
            let sectionMoment = sectionShear * max(0.001, station.depth)
            let flapFloored = max(flap, sectionMoment)
            let flapNegativeFloored = max(flapNegative, sectionMoment)
            let lag = flapFloored * max(1, lagInPlaneEfficiency * station.chord / max(0.001, station.depth))
            let torsion = flapFloored * 2 * material.shearToNormalStrength
            let outboardLength = max(station.length, span - stations[..<index].reduce(Float(0)) { $0 + $1.length })
            // A point load halfway out that reaches the moment capacity sets the shear the
            // webs must carry; distributed design shear is the floor.
            let shearCapacity = max(designShear[index] * jitter * fitting, flapFloored / max(0.01, 0.5 * outboardLength),
                                    sectionShear)
            let axial = shearCapacity * 2

            // Stiffness follows strength through the failure strain: EI = M·(h/2)/ε, and the
            // discrete joint spring is EI/ℓ. Torsion: closed box GJ ≈ T·(w·h)/((w+h)·γ),
            // γ ≈ 2ε. Shear/axial springs from the same strain over the station length.
            let strain = material.ultimateStrain
            let length = max(0.005, station.length)
            let depth = max(0.002, station.depth)
            let width = max(0.004, station.chord * 0.5)
            let flapEI = flapFloored * (depth * 0.5) / strain
            let lagEI = lag * (width * 0.5) / strain
            let torsionGJ = torsion * (width * depth) / ((width + depth) * 2 * strain)
            result[station.id] = VehicleJointSection(
                anchor: station.anchor,
                spanAxis: station.spanAxis,
                normalAxis: station.normalAxis,
                flapUltimateNm: flapFloored,
                flapNegativeUltimateNm: flapNegativeFloored,
                lagUltimateNm: lag,
                torsionUltimateNm: torsion,
                shearUltimateN: shearCapacity,
                axialUltimateN: axial,
                flapStiffness: flapEI / length,
                lagStiffness: lagEI / length,
                torsionStiffness: torsionGJ / length,
                shearStiffness: shearCapacity / (2 * strain * length),
                axialStiffness: axial / (strain * length),
                material: material,
                isMemberStation: true,
                memberID: memberID
            )
        }
        return result
    }

    /// A rigid attachment (motor mount, gear leg, internal equipment) described with the
    /// scalar limits the graph already derives for it.
    static func attachment(
        parent: VehicleComponent,
        child: VehicleComponent,
        tensileLimitN: Float,
        shearLimitN: Float,
        bendingLimitNm: Float,
        torsionLimitNm: Float,
        material: VehicleStructuralMaterial
    ) -> VehicleJointSection {
        let raw = child.localPosition - parent.localPosition
        let span = simd_length_squared(raw) > 1e-8 ? simd_normalize(raw) : SIMD3<Float>(0, -1, 0)
        let up = SIMD3<Float>(0, 1, 0)
        var normal = up - span * simd_dot(up, span)
        if simd_length_squared(normal) < 1e-6 {
            let forward = SIMD3<Float>(0, 0, -1)
            normal = forward - span * simd_dot(forward, span)
        }
        normal = simd_normalize(normal)
        // The attachment face: the point of the child's box nearest the parent's centre.
        let half = child.boundingHalfExtents
        let anchor = simd_clamp(parent.localPosition, child.localPosition - half, child.localPosition + half)
        let length = max(0.01, simd_length(raw))
        let strain = material.ultimateStrain
        let characteristic = max(0.01, min(half.x, half.y, half.z) * 2)
        let bendingEI = bendingLimitNm * characteristic * 0.5 / strain
        return VehicleJointSection(
            anchor: anchor,
            spanAxis: span,
            normalAxis: normal,
            flapUltimateNm: bendingLimitNm,
            flapNegativeUltimateNm: bendingLimitNm,
            lagUltimateNm: bendingLimitNm,
            torsionUltimateNm: torsionLimitNm,
            shearUltimateN: shearLimitN,
            axialUltimateN: tensileLimitN,
            flapStiffness: bendingEI / length,
            lagStiffness: bendingEI / length,
            torsionStiffness: bendingEI / length,
            shearStiffness: shearLimitN / (2 * strain * length),
            axialStiffness: tensileLimitN / (strain * length),
            material: material,
            isMemberStation: false
        )
    }
}
