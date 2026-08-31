import Foundation
import simd

/// One physical contact, in the terms sound needs.
///
/// This is the boundary the audio plan draws: physics publishes this and stops thinking about
/// sound; audio consumes it and never asks whether a structural failure happened, because the
/// answer is already in `damageSeverity`. Nothing on either side of the line knows a file name.
struct ImpactAudioEvent {
    let worldPosition: SIMD3<Float>
    let surface: AcousticSurfaceMaterial
    let vehicleMaterial: VehicleAcousticMaterial
    /// Normal contact impulse, N·s. The loudness driver — see `impactGain`.
    let normalImpulse: Float
    /// Closing speed along the contact normal, m/s.
    let normalSpeed: Float
    /// Sliding speed in the contact plane, m/s.
    let tangentialSpeed: Float
    /// How much this contact broke, 0…1. Comes from the damage model, never inferred here.
    let damageSeverity: Float
    /// Whether the surface itself failed — glazing shattering, masonry coming away.
    let brokeSurface: Bool
    /// A part that has come off the aircraft and is making its own contacts.
    let isDetachedPart: Bool
    /// Deterministic identity, so a replay of this contact picks the same takes.
    let seed: UInt64
}

/// One sound the resolver wants played for a contact.
struct ImpactAudioRequest: Hashable {
    let id: AudioAssetID
    let gainDb: Float
    let pitchRatio: Float
    let variant: Int
    /// Seconds after the primary contact. The plan's layering is a sequence, not a chord: a
    /// façade strike is a hard hit, *then* glass, *then* debris.
    let delaySeconds: Float
}

/// Turns a contact into the layers that describe it.
///
/// Pure and stateless, which is what lets the whole mapping be checked in a probe: the
/// interesting failures here — a twig producing a metal crash, a light touch at full volume,
/// glass breaking when nothing broke — are all statements about this function's output.
enum ImpactAudioResolver {

    /// Reference impulse: about what a hand-sized part brushing a wall delivers. Below this a
    /// contact is a touch.
    static let referenceImpulseNs: Float = 0.6
    /// The impulse at which the level law saturates — a heavy airframe arriving hard. Beyond
    /// it a crash cannot get louder, only longer.
    static let maximumImpulseNs: Float = 400.0
    /// Below this a contact produces no sound at all. It is not the same as the physics
    /// solver's resting threshold: a contact can be worth damaging and not worth hearing.
    static let audibleImpulseNs: Float = 0.25
    /// Sliding faster than this makes a scrape.
    static let scrapeThresholdMps: Float = 0.8

    /// Normalised loudness from the contact impulse, 0…1.
    ///
    /// The plan specifies the shape and the reason: the energies here span from a wing tip
    /// touching a leaf to a 1,500 kg aircraft hitting a tower, which is five orders of
    /// magnitude, and a linear law spends its whole range on the top decade and leaves every
    /// ordinary contact inaudible.
    static func impactGain(normalImpulseNs: Float) -> Float {
        let impulse = max(0.0, normalImpulseNs)
        let numerator = log1p(impulse / referenceImpulseNs)
        let denominator = log1p(maximumImpulseNs / referenceImpulseNs)
        return min(1.0, max(0.0, numerator / denominator))
    }

    /// The same figure as a level. −34 dB at the threshold of audibility, 0 dB at saturation.
    static func impactGainDb(normalImpulseNs: Float) -> Float {
        -34.0 + 34.0 * impactGain(normalImpulseNs: normalImpulseNs)
    }

    /// Ceiling for any single layer.
    ///
    /// The impulse law already saturates at 0 dB, but the per-material trims sit on top of it
    /// and a couple of them are positive — rock is louder than concrete, metal scrapes louder
    /// than stone — so without this a heavy strike on rock asked for +1.5 dB and left the
    /// limiter to sort it out. A limiter that works on every big impact is not headroom, it
    /// is distortion with a safety net.
    private static func capped(_ gainDb: Float) -> Float { min(0.0, gainDb) }

    /// Everything that should be heard for this contact, in the order it happens.
    static func resolve(_ event: ImpactAudioEvent) -> [ImpactAudioRequest] {
        guard event.normalImpulse >= audibleImpulseNs || event.damageSeverity > 0.05 else {
            return []
        }
        let level = impactGainDb(normalImpulseNs: event.normalImpulse)
        let jitter = AudioAssetCatalog.jitter(seed: event.seed)
        var requests: [ImpactAudioRequest] = []

        // 1 — the surface. What was struck decides the fundamental character, so this layer
        // is the one that must never be wrong.
        let primaryChoice = primaryAsset(for: event.surface)
        var primaryVariant = 1
        if let primary = primaryChoice {
            primaryVariant = AudioAssetCatalog.variantIndex(seed: event.seed, variants: primary.variants)
            requests.append(ImpactAudioRequest(
                id: primary.id,
                gainDb: capped(level + primary.trimDb + jitter.gainDb),
                pitchRatio: jitter.pitchRatio * primary.pitchScale,
                variant: primaryVariant,
                delaySeconds: 0.0
            ))
        }

        // 2 — the aircraft's own response, underneath. Quieter than the surface: the operator
        // is listening to a collision, not to an inventory of what the airframe is made of.
        // A hard contact is needed before it is worth hearing at all — a gear leg settling
        // onto grass does not make the airframe ring.
        //
        // Skipped when it would be the same clip as the surface layer: an aluminium airframe
        // against a steel container resolved both sides to the same recording, and the same
        // sample twelve milliseconds apart is a flam, not a doubling.
        if event.normalImpulse > referenceImpulseNs * 4.0,
           let response = vehicleResponseAsset(for: event.vehicleMaterial),
           response.id != primaryChoice?.id {
            requests.append(ImpactAudioRequest(
                id: response.id,
                gainDb: capped(level + response.trimDb + jitter.gainDb),
                pitchRatio: jitter.pitchRatio * response.pitchScale,
                variant: 1,
                delaySeconds: 0.012
            ))
        }

        // 3 — what broke on the aircraft. Driven by the damage model's own verdict, which is
        // the plan's rule: audio does not decide whether a structural failure happened.
        if event.damageSeverity > 0.2, let damage = damageAsset(for: event.vehicleMaterial) {
            requests.append(ImpactAudioRequest(
                id: damage.id,
                gainDb: capped(level + damage.trimDb + 6.0 * log10(max(0.2, event.damageSeverity))),
                pitchRatio: jitter.pitchRatio,
                variant: 1,
                delaySeconds: 0.035
            ))
        }

        // 4 — what came off the environment. Later still, because it does.
        if event.brokeSurface, let environment = surfaceFailureAsset(for: event.surface) {
            let variant = AudioAssetCatalog.variantIndex(
                seed: event.seed &+ 7,
                variants: environment.variants
            )
            // A different take of the same material is more of the same rustle and is wanted;
            // the identical take again is not.
            let duplicatesPrimary = environment.id == primaryChoice?.id && variant == primaryVariant
            if !duplicatesPrimary {
                requests.append(ImpactAudioRequest(
                    id: environment.id,
                    gainDb: capped(level + environment.trimDb),
                    pitchRatio: jitter.pitchRatio,
                    variant: variant,
                    delaySeconds: environment.delaySeconds
                ))
            }
        }

        return requests
    }

    /// The sliding sound, or nil when this contact is not sliding.
    ///
    /// Level follows the normal load — press harder and the scrape is louder — and pitch
    /// follows the sliding speed, which is what makes a skid audibly slow down as it stops.
    static func scrape(
        surface: AcousticSurfaceMaterial,
        normalImpulseNs: Float,
        tangentialSpeedMps: Float
    ) -> ImpactAudioRequest? {
        guard surface.supportsScrape, tangentialSpeedMps > scrapeThresholdMps else { return nil }
        let speedFraction = min(1.0, tangentialSpeedMps / 12.0)
        let loadFraction = impactGain(normalImpulseNs: normalImpulseNs)
        let gain = -30.0 + 22.0 * loadFraction + 8.0 * speedFraction + surfaceScrapeTrimDb(surface)
        return ImpactAudioRequest(
            id: .scrapeMetalConcrete,
            gainDb: capped(gain),
            pitchRatio: min(1.35, max(0.75, 0.75 + speedFraction * 0.6)),
            variant: 1,
            delaySeconds: 0.0
        )
    }

    /// Whether the struck surface itself gave way.
    ///
    /// This project models damage to the *aircraft* in detail and damage to the *environment*
    /// not at all — a wall is immovable however hard it is hit. So there is no verdict to ask
    /// for, and rather than have the audio layer invent one implicitly wherever it happens to
    /// need it, the threshold lives here, once, and is named for what it is.
    ///
    /// The thresholds are per material because they are the same question asked of different
    /// things: glazing gives up early and completely, masonry needs a genuine crash to shed
    /// anything, and a branch snaps at loads a trunk shrugs off.
    static func surfaceFails(
        surface: AcousticSurfaceMaterial,
        normalImpulseNs: Float,
        normalSpeedMps: Float
    ) -> Bool {
        switch surface {
        case .glass, .ice:
            // A pane that is merely touched must not shatter — the plan makes this an
            // acceptance check of its own.
            return normalSpeedMps > 4.0 && normalImpulseNs > 6.0
        case .concrete, .asphalt, .rock:
            return normalImpulseNs > 120.0
        case .treeTrunk:
            return normalImpulseNs > 45.0
        case .wood:
            return normalImpulseNs > 25.0
        case .foliage:
            // Twigs break constantly and quietly; that is what flying through a canopy is.
            return normalSpeedMps > 3.0
        case .metal:
            return normalImpulseNs > 90.0
        case .soil, .grass, .snow, .water, .generic:
            return false
        }
    }

    // MARK: Material → asset

    private struct AssetChoice {
        let id: AudioAssetID
        var trimDb: Float = 0.0
        var pitchScale: Float = 1.0
        var variants: Int = 1
        var delaySeconds: Float = 0.0
    }

    private static func primaryAsset(for surface: AcousticSurfaceMaterial) -> AssetChoice? {
        switch surface {
        case .concrete:
            return AssetChoice(id: .concreteHit)
        case .asphalt:
            // Dry and short. Asphalt is softer than a wall and does not ring.
            return AssetChoice(id: .concreteHit, trimDb: -2.0, pitchScale: 0.94)
        case .rock:
            return AssetChoice(id: .concreteHit, trimDb: 1.0, pitchScale: 0.9)
        case .metal:
            return AssetChoice(id: .impactMetalHeavy)
        case .glass:
            // The hit itself is a hard contact; the glass breaking is layer 4 and only if it
            // actually broke. A pane that survives must not shatter on the soundtrack.
            return AssetChoice(id: .concreteHit, trimDb: -3.0, pitchScale: 1.12)
        case .treeTrunk:
            return AssetChoice(id: .treeTrunkImpact, variants: 5)
        case .foliage:
            // Deliberately far down. The plan's second acceptance check is that brushing a
            // branch does not sound like hitting a wall, and this trim is that check.
            return AssetChoice(id: .foliageBranchImpact, trimDb: -8.0, variants: 5)
        case .wood:
            return AssetChoice(id: .treeTrunkImpact, trimDb: -2.0, pitchScale: 1.1, variants: 5)
        case .soil, .grass:
            return AssetChoice(id: .groundDirtThud, trimDb: surface == .grass ? -2.0 : 0.0)
        case .snow:
            // Muffled and lower: snow takes the top off everything.
            return AssetChoice(id: .groundDirtThud, trimDb: -7.0, pitchScale: 0.85)
        case .ice:
            return AssetChoice(id: .concreteHit, trimDb: -4.0, pitchScale: 1.2)
        case .water:
            return AssetChoice(id: .waterImpact)
        case .generic:
            return AssetChoice(id: .impactMechanicalShort)
        }
    }

    private static func vehicleResponseAsset(for material: VehicleAcousticMaterial) -> AssetChoice? {
        switch material {
        case .steel:
            return AssetChoice(id: .impactMetalHeavy, trimDb: -8.0, pitchScale: 0.95)
        case .aluminum:
            return AssetChoice(id: .impactMetalHeavy, trimDb: -10.0, pitchScale: 1.08)
        case .composite:
            return AssetChoice(id: .impactMechanicalShort, trimDb: -7.0, pitchScale: 1.05)
        case .plastic:
            return AssetChoice(id: .impactMechanicalShort, trimDb: -9.0, pitchScale: 1.18)
        case .wood:
            return AssetChoice(id: .treeWoodCrack, trimDb: -10.0)
        case .rubber:
            // A tyre absorbs its own contact. There is nothing to hear over the surface.
            return nil
        }
    }

    private static func damageAsset(for material: VehicleAcousticMaterial) -> AssetChoice? {
        switch material {
        case .steel, .aluminum:
            return AssetChoice(id: .damageMetalBend, trimDb: -4.0)
        case .composite:
            return AssetChoice(id: .damageCompositeBreak, trimDb: -4.0)
        case .wood:
            return AssetChoice(id: .treeWoodCrack, trimDb: -3.0)
        case .plastic:
            // A moulded plastic fairing and a composite one fail the same way — a polymer
            // shell cracking — so plastic borrows the composite break rather than asking for
            // a recording nobody has. Higher and shorter, because a plain plastic cover has
            // no fibre in it to hold the crack together.
            return AssetChoice(id: .damageCompositeBreak, trimDb: -6.0, pitchScale: 1.15)
        case .rubber:
            return nil
        }
    }

    private static func surfaceFailureAsset(for surface: AcousticSurfaceMaterial) -> AssetChoice? {
        switch surface {
        case .glass, .ice:
            return AssetChoice(id: .glassShatter, trimDb: -2.0, delaySeconds: 0.05)
        case .concrete, .asphalt, .rock:
            return AssetChoice(id: .damageStoneCrash, trimDb: -4.0, delaySeconds: 0.10)
        case .treeTrunk, .wood:
            return AssetChoice(id: .treeWoodCrack, trimDb: -2.0, delaySeconds: 0.04)
        case .foliage:
            return AssetChoice(id: .foliageBranchImpact, trimDb: -12.0, variants: 5, delaySeconds: 0.06)
        case .metal:
            return AssetChoice(id: .buildingDebris, trimDb: -8.0, delaySeconds: 0.12)
        case .soil, .grass, .snow, .water, .generic:
            return nil
        }
    }

    /// Layers for damage that did not come from a contact this tick.
    ///
    /// The plan's rule is that damage audio follows the damage *model*, not the fact of a
    /// collision, and this is where that becomes true: a joint weakened by an earlier impact
    /// that finally lets go three minutes later, in a turn, with nothing touching the
    /// aircraft, still makes the noise of something letting go.
    ///
    /// Contact-caused damage is voiced by `resolve` as part of the impact's own layers, so
    /// this deliberately says nothing about it — otherwise every collision would play its
    /// damage twice.
    static func resolveDamage(
        type: UAVDamageEventType,
        material: VehicleAcousticMaterial,
        severity: Float,
        seed: UInt64
    ) -> [ImpactAudioRequest] {
        let jitter = AudioAssetCatalog.jitter(seed: seed)
        let severityDb = 12.0 * log10(max(0.08, min(1.0, severity)))

        switch type {
        case .componentDeformed, .connectionLoosened:
            // Metal bends and complains; composite and wood crack instead. Scaled by how much
            // strength the joint actually lost, which is what the load solver reports.
            guard let choice = deformationAsset(for: material) else { return [] }
            return [ImpactAudioRequest(
                id: choice.id,
                gainDb: capped(-14.0 + severityDb + choice.trimDb + jitter.gainDb),
                pitchRatio: jitter.pitchRatio,
                variant: 1,
                delaySeconds: 0.0
            )]

        case .componentDamaged:
            // A tick, not a crash. The plan is explicit that minor damage must not reach for
            // the heavy impact sound.
            guard severity > 0.02 else { return [] }
            return [ImpactAudioRequest(
                id: .impactMechanicalShort,
                gainDb: capped(-22.0 + severityDb + jitter.gainDb),
                pitchRatio: jitter.pitchRatio * 1.1,
                variant: 1,
                delaySeconds: 0.0
            )]

        case .componentFailed:
            guard let choice = deformationAsset(for: material) else { return [] }
            return [
                ImpactAudioRequest(
                    id: choice.id,
                    gainDb: capped(-6.0 + choice.trimDb + jitter.gainDb),
                    pitchRatio: jitter.pitchRatio,
                    variant: 1,
                    delaySeconds: 0.0
                ),
                ImpactAudioRequest(
                    id: .impactMechanicalShort,
                    gainDb: -12.0,
                    pitchRatio: jitter.pitchRatio * 0.95,
                    variant: 1,
                    delaySeconds: 0.04
                )
            ]

        case .componentDetached:
            // Snap, then the part leaving, then what it took with it. Several events rather
            // than one — the plan asks specifically that a breakup is not a single
            // Hollywood explosion.
            var requests: [ImpactAudioRequest] = []
            if let choice = deformationAsset(for: material) {
                requests.append(ImpactAudioRequest(
                    id: choice.id,
                    gainDb: capped(-4.0 + choice.trimDb),
                    pitchRatio: jitter.pitchRatio,
                    variant: 1,
                    delaySeconds: 0.0
                ))
            }
            requests.append(ImpactAudioRequest(
                id: .impactMechanicalShort,
                gainDb: -10.0,
                pitchRatio: jitter.pitchRatio * 1.05,
                variant: 1,
                delaySeconds: 0.05
            ))
            requests.append(ImpactAudioRequest(
                id: .buildingDebris,
                gainDb: -20.0,
                pitchRatio: 1.15,
                variant: 1,
                delaySeconds: 0.12
            ))
            return requests

        case .impact, .secondaryImpact, .subsystemFailed, .massPropertiesChanged,
             .controlAuthorityReduced, .controlAuthorityLost, .vehicleSettled:
            // Impacts have their own resolver; the rest are state changes with no sound of
            // their own. A subsystem failure changes the propulsion loop instead, which is
            // the plan's rule — it must not be replaced by a generic impact.
            return []
        }
    }

    private static func deformationAsset(for material: VehicleAcousticMaterial) -> AssetChoice? {
        switch material {
        case .steel, .aluminum:
            return AssetChoice(id: .damageMetalBend)
        case .composite:
            return AssetChoice(id: .damageCompositeBreak)
        case .wood:
            return AssetChoice(id: .treeWoodCrack)
        case .plastic:
            return AssetChoice(id: .damageCompositeBreak, trimDb: -2.0, pitchScale: 1.15)
        case .rubber:
            return nil
        }
    }

    private static func surfaceScrapeTrimDb(_ surface: AcousticSurfaceMaterial) -> Float {
        switch surface {
        case .concrete, .asphalt, .rock: return 0.0
        case .metal: return 2.0
        case .glass, .ice: return -3.0
        case .treeTrunk, .wood: return -4.0
        case .soil, .grass: return -8.0
        case .snow: return -12.0
        case .generic: return -4.0
        case .water, .foliage: return -60.0
        }
    }
}
