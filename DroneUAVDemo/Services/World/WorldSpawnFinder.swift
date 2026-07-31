import simd

/// Chooses where an aircraft starts in an imported world.
///
/// Extracted from `MeshWorldRuntime` because it never depended on photogrammetry: everything it
/// asks is answered by a collision index — how high the surface is, what stands nearby, whether the
/// patch is flat. A world built from open vector data has exactly the same questions and would
/// otherwise have grown a second, subtly different copy of this search, which is how the criteria
/// below were learned in the first place: each one is here because a flight test found the aircraft
/// somewhere it should never have started.
struct WorldSpawnFinder {

    let collision: MeshCollisionIndex

    /// The world's water, if it has any. Used only to keep the search off it.
    var water: WaterSurfaceModel?

    /// Lowest surface elevation the search will accept.
    ///
    /// A hardcoded 0.6 m used to stand here, meaning "above sea level so we do not start on the
    /// water". That is right for a photogrammetric city referenced to a real vertical datum and
    /// badly wrong for a world built from open vector data, whose ground is a plane at exactly
    /// zero — the filter rejected *all* of it and the search returned the only thing left, a
    /// rooftop four metres up. The floor now comes from the water when there is water, and does not
    /// exist when there is none.
    private var minimumSurface: Float {
        guard let water else { return -.greatestFiniteMagnitude }
        return water.level + 0.6
    }

    /// A clear spot to start from: a level patch of ground away from walls, with headroom.
    ///
    /// Searched outward from the tile centre in a spiral rather than taken at the centre itself,
    /// because the middle of a 2 km tile is as likely to be a rooftop, a tree or open water as a
    /// usable apron.
    func find(clearanceRadius: Float = 3.0) -> SIMD3<Float>? {
        let centre = (collision.bounds.minimum + collision.bounds.maximum) * 0.5
        let maximumRadius = min(
            collision.bounds.maximum.x - collision.bounds.minimum.x,
            collision.bounds.maximum.z - collision.bounds.minimum.z
        ) * 0.45

        var candidates: [Candidate] = []
        var radius: Float = 0
        while radius < maximumRadius {
            let samples = max(8, Int(radius / 12) * 8)
            for sample in 0..<samples {
                let angle = Float(sample) / Float(samples) * 2 * .pi
                let x = centre.x + cos(angle) * radius
                let z = centre.z + sin(angle) * radius
                guard let candidate = evaluate(x: x, z: z, clearanceRadius: clearanceRadius) else {
                    continue
                }
                candidates.append(candidate)
                // Keep looking until there are enough *ground-level* options, not merely enough
                // options: the first candidates found are near the tile centre, which in a city
                // centre means rooftops, and stopping there is what parked the launch pad 19 m up.
                if candidates.filter(\.isGroundLevel).count >= 24 { return bestCandidate(candidates) }
            }
            radius += 12
        }
        return bestCandidate(candidates)
    }

    /// Every criterion a start point must satisfy, applied to one spot.
    ///
    /// Factored out of `find()` unchanged so that a point the *operator* picks is judged by exactly
    /// the same rules as one the search picks — there is no second, laxer standard for manual
    /// placement, which is how an operator ends up standing inside a building.
    func evaluate(
        x: Float,
        z: Float,
        clearanceRadius: Float = 3.0,
        minimumClearance: Float = WorldSpawnFinder.minimumLateralClearance
    ) -> Candidate? {
        guard let surface = collision.highestSurface(x: x, z: z) else { return nil }
        guard surface > minimumSurface else { return nil }

        // Level: the four neighbours must sit at a similar height.
        for offset in [SIMD2<Float>(clearanceRadius, 0), SIMD2<Float>(-clearanceRadius, 0),
                       SIMD2<Float>(0, clearanceRadius), SIMD2<Float>(0, -clearanceRadius)] {
            guard let neighbour = collision.highestSurface(x: x + offset.x, z: z + offset.y),
                  abs(neighbour - surface) < 0.6 else {
                return nil
            }
        }

        // Headroom: nothing directly overhead for a comfortable climb-out.
        guard collision.raycast(
            origin: SIMD3<Float>(x, surface + 1.0, z),
            direction: SIMD3<Float>(0, 1, 0),
            maxDistance: 45
        ) == nil else { return nil }

        guard footprintSpread(x: x, z: z, surface: surface) <= Self.maximumFootprintSpread else {
            return nil
        }
        let survey = surroundings(x: x, z: z, surface: surface)
        guard survey.openness >= minimumClearance else { return nil }

        return Candidate(
            point: SIMD3<Float>(x, surface, z),
            openness: survey.openness,
            standsAbove: surface - survey.lowestNeighbour
        )
    }

    /// Nearest spot to `preferred` that a start may actually occupy, or nil if there is none close by.
    ///
    /// The tactical map lets the operator put the start anywhere he can click, including inside a
    /// building or under a road deck — the map is a flat plan and says nothing about what stands
    /// there. Rather than refuse the click, it is snapped to the closest legal spot.
    ///
    /// `allowElevated` decides what a tap on a building means. The automatic search must stay on the
    /// ground (a start parked 19 m up on a roof nobody chose is a defect, and the reason
    /// `isGroundLevel` exists), but an operator who taps a building is *asking* for its roof — and in
    /// a dense city that is the better answer: Lower Manhattan measured **zero** clear departure
    /// headings of 24 at street level, its streets being narrower than the aircraft's turn radius,
    /// while a rooftop starts above most of what blocks them. The roof still has to pass every other
    /// test — flat, open, with headroom — so a pitched roof, a parapet edge or a light well is
    /// rejected exactly as before and the search moves on to the next candidate.
    func nearestValidPoint(
        to preferred: SIMD2<Float>,
        clearanceRadius: Float = 3.0,
        searchRadius: Float = 160.0,
        ringStep: Float = 6.0,
        allowElevated: Bool = false
    ) -> SIMD3<Float>? {
        var best: (point: SIMD3<Float>, distance: Float)?
        var radius: Float = 0

        while radius <= searchRadius {
            // Once anything legal is found, only the rest of this ring can still be nearer.
            if let best, best.distance < radius - ringStep { return best.point }

            let samples = radius < 0.5 ? 1 : max(8, Int(radius / 6.0) * 8)
            for sample in 0..<samples {
                let angle = Float(sample) / Float(samples) * 2 * .pi
                let x = preferred.x + cos(angle) * radius
                let z = preferred.y + sin(angle) * radius
                guard let candidate = evaluate(x: x, z: z, clearanceRadius: clearanceRadius),
                      allowElevated || candidate.isGroundLevel else { continue }
                let distance = simd_distance(SIMD2<Float>(x, z), preferred)
                if best == nil || distance < best!.distance {
                    best = (candidate.point, distance)
                }
            }
            radius += ringStep
        }
        return best?.point
    }

    /// The roof of the building the operator tapped, or nil if he tapped no building — or if that
    /// roof cannot hold a start.
    ///
    /// Tried *before* the ordinary snap, because the ordinary snap answers a different question. Its
    /// lateral-clearance floor exists to reject a six-metre light well at street level, and applied
    /// to a roof it rejects any mid-rise standing among towers — which is most of a financial
    /// district. The result was the opposite of what the tap asked for: the operator picked a
    /// building and was set down on the street beside it. On a roof the clearance that matters is
    /// *overhead*, not lateral: the aircraft leaves above the parapet with nothing but sky in front.
    /// So openness drops to a figure that only rejects a narrow ledge, while flatness, headroom and
    /// footprint spread are enforced exactly as on the ground.
    ///
    /// Searched over a short radius rather than at the tap alone: a tap near a parapet fails the
    /// levelness test — its neighbours are the street far below — and the fix is to step inboard,
    /// not to give up. Candidates are held to the tapped roof's own height so the search cannot
    /// quietly deliver the pavement below.
    func rooftopStart(
        at preferred: SIMD2<Float>,
        clearanceRadius: Float = 3.0,
        searchRadius: Float = 45.0,
        ringStep: Float = 3.0
    ) -> SIMD3<Float>? {
        guard let roofLevel = collision.highestSurface(x: preferred.x, z: preferred.y) else {
            return nil
        }
        // Something that stands well above its own surroundings is a building; anything else is
        // ground, and ground is the ordinary snap's business.
        let survey = surroundings(x: preferred.x, z: preferred.y, surface: roofLevel)
        guard roofLevel - survey.lowestNeighbour > Self.groundLevelTolerance else { return nil }

        var radius: Float = 0
        while radius <= searchRadius {
            let samples = radius < 0.5 ? 1 : max(8, Int(radius / 3.0) * 8)
            for sample in 0..<samples {
                let angle = Float(sample) / Float(samples) * 2 * .pi
                let x = preferred.x + cos(angle) * radius
                let z = preferred.y + sin(angle) * radius
                guard let candidate = evaluate(
                    x: x,
                    z: z,
                    clearanceRadius: clearanceRadius,
                    minimumClearance: Self.rooftopLateralClearance
                ) else { continue }
                // Same roof, not the street below or a neighbour's parapet.
                guard abs(candidate.point.y - roofLevel) <= Self.rooftopHeightTolerance else { continue }
                return candidate.point
            }
            radius += ringStep
        }
        return nil
    }

    /// Lateral room a rooftop start needs. Far below the ground figure on purpose — see
    /// `rooftopStart` — and non-zero only so a narrow ledge or a lift overrun's shoulder is refused.
    static let rooftopLateralClearance: Float = 3.0

    /// How far a rooftop candidate may sit from the height of the roof that was tapped.
    static let rooftopHeightTolerance: Float = 2.0

    /// A start point must have room *around* it, not just above it.
    ///
    /// Level ground and clear sky are both true inside a six-metre light well between two blocks,
    /// which is where the search actually put the aircraft in central Helsinki: walls 6 m west, 6 m
    /// south and 10 m east of a rooftop 7.5 m up, reported to the pilot as a dark box with a patch
    /// of sky and a standing collision warning. Flatness was measured over a 3 m probe and the
    /// headroom ray went straight up, so neither test could see the walls.
    /// Least clear space around a start point.
    ///
    /// Set by two opposing measurements rather than by taste. Helsinki produced a **six-metre** light
    /// well between two blocks that passed every other test, so the floor has to sit above that.
    /// Lower Manhattan produced no ground at all with fourteen metres — its streets are simply
    /// narrower than that between facades — and the search fell back to rooftops. Eight metres
    /// rejects the light well and accepts a normal city street.
    static let minimumLateralClearance: Float = 8.0
    static let opennessProbeLimit: Float = 45.0

    /// What counts as being in the way.
    ///
    /// Set at 2.5 m this missed parked cars, and the search duly delivered the aircraft into a car
    /// park wedged between vehicles: 34 m of clearance by the old measure, 1 m by any measure that
    /// can see a van. A drone cares about anything it can strike, and 1.2 m catches cars, bollards
    /// and railings while still ignoring kerbs and low walls.
    static let obstructionHeight: Float = 1.2

    /// An apron is smooth; a car park, a rubble field and a tree line are not. Measured as the
    /// height spread across the immediate footprint, this rejects them all without needing to know
    /// what they are — and it is the test that would have caught the car park on its own.
    static let maximumFootprintSpread: Float = 1.0

    /// How far a surface may stand above its own surroundings and still count as ground.
    ///
    /// A roof is not distinguished by its absolute height — terrain varies and the vertical datum is
    /// arbitrary — but by standing above everything around it. One generous storey is the line: it
    /// keeps quaysides, which sit a couple of metres over the water they look onto, and rejects the
    /// rooftops that an openness-only test happily selects.
    static let groundLevelTolerance: Float = 5.0

    struct Candidate {
        let point: SIMD3<Float>
        let openness: Float
        let standsAbove: Float
        var isGroundLevel: Bool { standsAbove <= WorldSpawnFinder.groundLevelTolerance }
    }

    /// Height spread over the patch the aircraft actually stands on.
    /// Height spread over the patch the aircraft actually stands on.
    ///
    /// Samples the surface *at or just above the candidate's own level*, never the highest thing in
    /// the column. Using the highest made the test meaningless in a dense city: a perfectly flat
    /// street four metres from a tower has a sample that lands on the tower's roof, so the patch
    /// reports a spread of fifty metres and is thrown out as rough ground. Measured on Lower
    /// Manhattan that rejected **15,687 of 17,168** candidates and left the search nothing at ground
    /// level to choose from, so it started the aircraft on a roof.
    ///
    /// The car park this test was written for is still caught, by the openness probe rather than
    /// here: parked cars stand well above the 1.2 m obstruction height and that site measured one
    /// metre of clearance.
    func footprintSpread(x: Float, z: Float, surface: Float) -> Float {
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude
        for stepX in -3...3 {
            for stepZ in -3...3 {
                guard let height = collision.surfaceHeight(
                    x: x + Float(stepX) * 1.5,
                    z: z + Float(stepZ) * 1.5,
                    startingFrom: surface + 0.8
                ) else { continue }
                lowest = min(lowest, height)
                highest = max(highest, height)
            }
        }
        return highest > lowest ? highest - lowest : 0.0
    }

    /// Walks eight directions once, answering both questions the choice depends on: how far the
    /// clear space extends, and how far the surface drops away around it.
    /// Walks eight directions once, answering both questions the choice depends on: how far the
    /// clear space extends, and how far the surface drops away around it.
    ///
    /// The two answers stop at different places, and conflating them was a real defect. Openness has
    /// to stop at the first obstruction — that is what "clear space" means. Elevation must *not*,
    /// because a wide rooftop looks perfectly level for the whole probe: every sample sits on the
    /// same roof, nothing lower is ever seen, and the patch reports that it stands zero metres above
    /// its surroundings. Measured on Lower Manhattan that put the start on a roof 36 m up and called
    /// it ground. So the elevation probe keeps sampling to the full radius, past whatever it hits,
    /// and only then says how far the world falls away.
    func surroundings(
        x: Float,
        z: Float,
        surface: Float
    ) -> (openness: Float, lowestNeighbour: Float) {
        var worst = Self.opennessProbeLimit
        var lowest = surface

        for step in 0..<8 {
            let angle = Float(step) / 8 * 2 * .pi
            let dx = cos(angle), dz = sin(angle)
            var distance: Float = 2
            var obstructedAt: Float?

            while distance < Self.opennessProbeLimit {
                guard let height = collision.highestSurface(x: x + dx * distance, z: z + dz * distance)
                else { break }
                lowest = min(lowest, height)
                if obstructedAt == nil, height > surface + Self.obstructionHeight {
                    obstructedAt = distance
                }
                distance += 2
            }
            worst = min(worst, obstructedAt ?? distance)
        }
        return (worst, lowest)
    }

    /// The most open of the candidates found, and among equally open ones the lowest.
    ///
    /// Openness alone happily selects a large flat roof — it is level, it has sky above it and
    /// nothing taller nearby, which is precisely the definition being tested. But a roof nineteen
    /// metres up is a strange place to find a launch pad parked, and a quayside or a plaza reads as
    /// the apron it is meant to be. Since the openness probe saturates, ties are common and the
    /// elevation tie-break does the real work here.
    /// Lowest-standing candidate first, most open among equals.
    ///
    /// The priority order is the whole decision and it was originally the other way round: openness
    /// first, elevation only as a tie-break. That reliably picked a rooftop in a dense city, because
    /// a roof four metres up is open in every direction for 45 m while a street between buildings is
    /// open for perhaps fifteen. Measured on Lower Manhattan, it started the aircraft on a roof in a
    /// world whose ground is a flat plane — there was nothing wrong with the ground, it simply lost.
    ///
    /// Elevation above the surroundings is bucketed to a metre so that genuinely equivalent ground —
    /// a quayside and the road behind it — is still separated by openness rather than by centimetres
    /// of survey noise.
    func bestCandidate(_ candidates: [Candidate]) -> SIMD3<Float>? {
        candidates.min { left, right in
            let leftBucket = (left.standsAbove).rounded(.down)
            let rightBucket = (right.standsAbove).rounded(.down)
            if leftBucket != rightBucket { return leftBucket < rightBucket }
            return left.openness > right.openness
        }?.point
    }
}
