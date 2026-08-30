import Foundation

/// Which limit an aircraft is up against.
///
/// The reason this is an enum rather than a boolean is the plan's requirement that the
/// operator be told *why* they are being limited. "Overspeed" is not an answer when
/// there are five different ways to be going too fast and they need opposite responses:
/// too much Mach is solved by slowing down, too much dynamic pressure is solved by
/// climbing, too much load factor is solved by unloading, and too much skin temperature
/// is solved by doing any of those but only slowly.
enum FlightEnvelopeLimit: String, Hashable, CaseIterable {
    case mach
    case dynamicPressure
    case loadFactor
    case angleOfAttack
    case thermal
    case inlet

    var localizationKey: String { "envelope.limit.\(rawValue)" }

    /// What the operator should actually do about it. Distinct per limit because the
    /// corrections genuinely differ, and because two of them point in opposite
    /// directions: climbing is the answer to over-q and makes a Mach limit worse.
    var remedyKey: String { "envelope.remedy.\(rawValue)" }
}

/// One aircraft's high-speed limits.
///
/// Every value has a default derived from figures the catalogue already carries, so an
/// aircraft gains an envelope without anyone editing its entry — and the derived values
/// are the honest reading of what those figures mean rather than invented ceilings. A
/// supersonic profile overrides what it knows.
struct FlightEnvelopeLimits: Hashable {
    /// Never-exceed Mach.
    var maxMach: Float
    /// Never-exceed dynamic pressure, Pa. This is the structural limit proper: what
    /// actually breaks an airframe is the pressure on it, and an aircraft can be well
    /// below its Mach limit and far past this one down low.
    var maxDynamicPressurePa: Float
    var maxPositiveLoadFactor: Float
    /// Negative limit, as a positive magnitude. Always much lower than the positive one:
    /// wings are built to be pulled on, not pushed.
    var maxNegativeLoadFactor: Float
    var maxAngleOfAttackRad: Float
    /// Mach at which the flutter margin vanishes at the never-exceed dynamic pressure.
    /// `nil` where it is genuinely not known, which is most aircraft — a fabricated
    /// flutter boundary is worse than an absent one, because it would be believed.
    var flutterBoundaryMach: Float?
    /// Skin temperature at which the structure starts losing strength, K.
    var maxSkinTemperatureK: Float

    /// Derives an envelope from what an airframe already declares.
    ///
    /// **The Mach limit and the dynamic-pressure limit must not come from the same
    /// number.** The first version of this derived both from the declared maximum
    /// airspeed, and the envelope probe caught the consequence immediately: reading one
    /// airspeed at five altitudes, the Mach limit bound at every one of them and the
    /// dynamic-pressure limit could not bind anywhere. That is arithmetic, not physics —
    /// climb at constant true airspeed and Mach rises while `q` falls, so if the two
    /// limits are equal at sea level the Mach one wins for ever afterwards. An envelope
    /// like that cannot tell an overspeed from an over-`q`, which is the one thing the
    /// plan asks it to do.
    ///
    /// They are independent quantities in a real aircraft and they are independent here:
    ///
    /// - `maxDynamicPressurePa` comes from the declared maximum airspeed read as an
    ///   **equivalent** airspeed — the pressure the structure is cleared to. This is what
    ///   a VNE actually is, and it binds down low.
    /// - `maxMach` comes from the **planform**, not from the declared speed: an airframe's
    ///   aerodynamic ceiling is where its own drag rise makes it unflyable, which is a
    ///   property of its shape. For a slow aircraft this is unreachable and `q` always
    ///   binds — which is correct, a survey wing is never Mach-limited. For a fast one the
    ///   declared speed wins instead, so a supersonic profile is not held below Mach 1 by
    ///   a subsonic planform's drag divergence.
    ///
    /// The two now cross at an altitude, which is the whole point: below it the structure
    /// binds and the answer is to slow down; above it Mach binds and climbing makes it
    /// worse.
    ///
    /// Load factors follow the normal-category convention, scaled by the airframe's own
    /// build-quality factor so a research airframe and a foam survey wing are not given
    /// the same structure.
    static func derived(
        maxAirspeedMps: Float,
        stallAlphaRad: Float,
        dragDivergenceMach: Float,
        structuralQualityFactor: Float,
        skinMaterial: UAVSkinMaterial
    ) -> FlightEnvelopeLimits {
        let vne = max(10.0, maxAirspeedMps)
        let quality = max(0.4, structuralQualityFactor)
        let declaredMach = vne / AtmosphereState.seaLevelStandard.speedOfSoundMps
        return FlightEnvelopeLimits(
            maxMach: max(0.25, max(declaredMach, dragDivergenceMach + 0.05)),
            maxDynamicPressurePa: 0.5 * AtmosphereModel.seaLevelDensity * vne * vne,
            maxPositiveLoadFactor: (3.8 * quality).clamped(to: 2.0...12.0),
            maxNegativeLoadFactor: (1.5 * quality).clamped(to: 1.0...6.0),
            // Past the stall there is no more lift to be had, so the aerodynamic limit
            // is the stall itself plus the small overshoot a real aircraft survives.
            maxAngleOfAttackRad: stallAlphaRad + Float(4.0) * .pi / 180.0,
            flutterBoundaryMach: nil,
            maxSkinTemperatureK: skinMaterial.workingLimitK
        )
    }

    init(
        maxMach: Float,
        maxDynamicPressurePa: Float,
        maxPositiveLoadFactor: Float,
        maxNegativeLoadFactor: Float,
        maxAngleOfAttackRad: Float,
        flutterBoundaryMach: Float?,
        maxSkinTemperatureK: Float
    ) {
        self.maxMach = max(0.1, maxMach)
        self.maxDynamicPressurePa = max(50.0, maxDynamicPressurePa)
        self.maxPositiveLoadFactor = max(1.2, maxPositiveLoadFactor)
        self.maxNegativeLoadFactor = max(0.5, maxNegativeLoadFactor)
        self.maxAngleOfAttackRad = max(0.05, maxAngleOfAttackRad)
        self.flutterBoundaryMach = flutterBoundaryMach
        self.maxSkinTemperatureK = max(300.0, maxSkinTemperatureK)
    }
}

/// What the airframe is made of, and therefore how hot it may get.
///
/// The single number that decides whether an aircraft can hold a high Mach number for
/// minutes or only dash through it. It is why the Firebee II's Mach 1.5 is quoted as a
/// four-minute dash and why an aircraft meant to cruise at Mach 3 is built of something
/// other than aluminium.
enum UAVSkinMaterial: String, Hashable, CaseIterable, Codable {
    /// Ordinary aircraft aluminium. Loses strength quickly past about 400 K, which
    /// corresponds to sustained flight around Mach 2 at altitude.
    case aluminium
    /// Titanium alloy — the answer for sustained Mach 2–3.
    case titanium
    /// Stainless steel structure, as used where weight matters less than heat.
    case stainlessSteel
    /// Composite skins. Light and strong, and worse in heat than aluminium.
    case composite

    /// Temperature at which the material begins losing useful strength, K.
    var workingLimitK: Float {
        switch self {
        case .composite: return 380.0
        case .aluminium: return 420.0
        case .titanium: return 800.0
        case .stainlessSteel: return 950.0
        }
    }

    /// Specific heat capacity, J/(kg·K). Sets how quickly a node's temperature moves.
    var specificHeatJPerKgK: Float {
        switch self {
        case .composite: return 1_050.0
        case .aluminium: return 900.0
        case .titanium: return 520.0
        case .stainlessSteel: return 500.0
        }
    }

    /// Surface emissivity. A hot painted or oxidised skin radiates a useful fraction of
    /// what it absorbs, and at Mach 3 that radiation is most of what keeps it survivable.
    var emissivity: Float {
        switch self {
        case .composite: return 0.85
        case .aluminium: return 0.35
        case .titanium: return 0.55
        case .stainlessSteel: return 0.45
        }
    }

    var localizationKey: String { "uav.skin.material.\(rawValue)" }
}

/// Where the aircraft is inside its envelope right now.
///
/// Fractions rather than booleans, and they are allowed to exceed 1: the plan is
/// explicit that exceeding a limit must accumulate consequence rather than trigger a
/// scripted break, and something that reports only "exceeded" cannot express how badly
/// or for how long.
struct FlightEnvelopeState: Hashable {
    var machFraction: Float = 0.0
    var dynamicPressureFraction: Float = 0.0
    var loadFactorFraction: Float = 0.0
    var angleOfAttackFraction: Float = 0.0
    var thermalFraction: Float = 0.0
    /// Margin to the flutter boundary, 1 = no flutter risk, 0 = at the boundary.
    /// Negative past it. `nil` where the aircraft has no published boundary.
    var flutterMargin: Float?
    var inletWithinEnvelope: Bool = true
    /// The limit the aircraft is closest to, whether or not it has been exceeded.
    var bindingLimit: FlightEnvelopeLimit = .mach
    /// Seconds accumulated outside the envelope, decaying when back inside. What the
    /// structural model charges damage against, so that a brief excursion costs little
    /// and a sustained one costs a great deal.
    var exceedanceSeconds: Float = 0.0

    var isExceeded: Bool { worstFraction > 1.0 }

    var worstFraction: Float {
        max(
            max(machFraction, dynamicPressureFraction),
            max(max(loadFactorFraction, angleOfAttackFraction), thermalFraction)
        )
    }

    static let nominal = FlightEnvelopeState()
}

/// Evaluates where an aircraft sits in its envelope.
///
/// Deliberately observational. It reports, warns and accumulates; it never reaches into
/// the controls. The plan forbids holding an aircraft to a speed with a clamp instead of
/// with the physical balance of thrust and drag, and a monitor that quietly limited
/// anything would be that clamp wearing a different name. What consumes this is the
/// autopilot's choice of *target*, the warning surface, and the structural model.
struct FlightEnvelopeMonitor {
    let limits: FlightEnvelopeLimits

    func evaluate(
        previous: FlightEnvelopeState,
        mach: Float,
        dynamicPressurePa: Float,
        loadFactor: Float,
        angleOfAttackRad: Float,
        skinTemperatureK: Float,
        inletWithinEnvelope: Bool,
        deltaTime: Float
    ) -> FlightEnvelopeState {
        var next = FlightEnvelopeState()
        next.machFraction = safeFraction(mach, limits.maxMach)
        next.dynamicPressureFraction = safeFraction(dynamicPressurePa, limits.maxDynamicPressurePa)
        next.loadFactorFraction = loadFactor >= 0.0
            ? safeFraction(loadFactor, limits.maxPositiveLoadFactor)
            : safeFraction(-loadFactor, limits.maxNegativeLoadFactor)
        // Angle of attack means nothing without flow over the wing. A parked aircraft's
        // airflow vector is whatever rounding left in it, and the angle derived from it was
        // being reported as a bound limit — three times over, on a machine that was sitting
        // still with the engine off. Nor is it only cosmetic: a stationary aircraft cannot
        // stall, because stalling is the loss of a lift it is not producing.
        //
        // Faded in over the first one percent of the never-exceed dynamic pressure, which
        // is a tenth of the never-exceed *speed* and so sits far below any airframe's stall
        // — the limit is at full strength long before the aircraft can reach a condition
        // where it binds, and this cannot hide a real low-speed stall.
        let aeroAngleCredibility = (dynamicPressurePa / max(1.0, limits.maxDynamicPressurePa * 0.01))
            .clamped(to: 0.0...1.0)
        next.angleOfAttackFraction = safeFraction(abs(angleOfAttackRad), limits.maxAngleOfAttackRad)
            * aeroAngleCredibility
        // Referenced to the working limit above ambient rather than to absolute zero, so
        // an aircraft sitting on a warm apron does not report a third of its thermal
        // budget already spent.
        let thermalHeadroom = max(1.0, limits.maxSkinTemperatureK - 288.15)
        next.thermalFraction = safeFraction(max(0.0, skinTemperatureK - 288.15), thermalHeadroom)
        next.inletWithinEnvelope = inletWithinEnvelope

        if let boundary = limits.flutterBoundaryMach {
            // Flutter is a q-and-Mach phenomenon, not a Mach one: the same Mach number at
            // half the dynamic pressure is half the excitation. Published boundaries are
            // quoted at a reference condition, so the margin scales with how much q the
            // aircraft is actually carrying against the limit it was cleared to.
            let qShare = safeFraction(dynamicPressurePa, limits.maxDynamicPressurePa)
            let machShare = safeFraction(mach, boundary)
            next.flutterMargin = 1.0 - machShare * max(0.25, qShare)
        }

        next.bindingLimit = binding(next)

        let excursion = next.worstFraction > 1.0 || !inletWithinEnvelope
        // Accumulates four times faster than it decays. An airframe does not forget an
        // overload as quickly as it took it.
        next.exceedanceSeconds = excursion
            ? previous.exceedanceSeconds + max(0.0, deltaTime)
            : max(0.0, previous.exceedanceSeconds - max(0.0, deltaTime) * 0.25)
        return next
    }

    private func binding(_ state: FlightEnvelopeState) -> FlightEnvelopeLimit {
        guard state.inletWithinEnvelope else { return .inlet }
        let candidates: [(FlightEnvelopeLimit, Float)] = [
            (.mach, state.machFraction),
            (.dynamicPressure, state.dynamicPressureFraction),
            (.loadFactor, state.loadFactorFraction),
            (.angleOfAttack, state.angleOfAttackFraction),
            (.thermal, state.thermalFraction)
        ]
        return candidates.max { $0.1 < $1.1 }?.0 ?? .mach
    }

    private func safeFraction(_ value: Float, _ limit: Float) -> Float {
        guard value.isFinite, limit > 1.0e-6 else { return 0.0 }
        return max(0.0, value) / limit
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
