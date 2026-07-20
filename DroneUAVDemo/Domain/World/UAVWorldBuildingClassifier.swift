import Foundation

/// Source-neutral description of one building as the importer understood it, before any
/// simulator-specific decisions are made.
///
/// Every field is optional except the footprint area, because the whole point of a
/// constructor-style importer is that data quality varies enormously by country: a Dutch or
/// NYC record may carry a surveyed height, a construction year and a use class, while the same
/// query in a sparsely-mapped region yields a bare outline. The classifier below degrades
/// through those tiers instead of demanding a fixed schema.
struct UAVWorldBuildingSourceRecord: Sendable {
    /// Normalised use class: `residential`, `commercial`, `office`, `retail`, `industrial`,
    /// `warehouse`, `church`, `school`, `hospital`, `civic`, `garage`, `hotel`… Adapters lower
    /// their source's vocabulary into these before calling.
    var useClass: String?
    /// Normalised cladding hint: `brick`, `glass`, `concrete`, `metal`, `stone`, `stucco`,
    /// `wood`. Only set when the source actually states it.
    var claddingMaterial: String?
    var levels: Int?
    var yearBuilt: Int?
    /// Height in metres when the source measured or stated one.
    var statedHeightMeters: Float?
    var footprintAreaSquareMeters: Float
    var name: String?
    /// Source's own roof-shape statement, normalised: `flat`, `gabled`, `hipped`, `pyramidal`,
    /// `dome`, `skillion`, `mansard`.
    var roofShape: String?

    init(
        useClass: String? = nil,
        claddingMaterial: String? = nil,
        levels: Int? = nil,
        yearBuilt: Int? = nil,
        statedHeightMeters: Float? = nil,
        footprintAreaSquareMeters: Float,
        name: String? = nil,
        roofShape: String? = nil
    ) {
        self.useClass = useClass
        self.claddingMaterial = claddingMaterial
        self.levels = levels
        self.yearBuilt = yearBuilt
        self.statedHeightMeters = statedHeightMeters
        self.footprintAreaSquareMeters = footprintAreaSquareMeters
        self.name = name
        self.roofShape = roofShape
    }
}

/// Turns whatever a source dataset happened to record into the height, roof and facade class
/// the simulator renders and collides against.
///
/// The facade rules are architectural heuristics, not arbitrary mappings — construction era and
/// use class really do predict cladding, and getting that correlation approximately right is
/// what makes a procedurally-clad city read as the *right* city. A block of prewar brick
/// walk-ups, postwar concrete slabs and modern glass towers is recognisably Lower Manhattan;
/// the same geometry in one uniform grey is not, even though the shapes are identical.
///
/// Every inference is reported with its accuracy tier, so nothing downstream mistakes a guess
/// for a survey.
enum UAVWorldBuildingClassifier {
    /// Typical floor-to-floor heights, in metres. Commercial floors are taller than residential
    /// ones, and industrial halls taller still; using one average for all three visibly
    /// mis-scales any skyline with a mixed use pattern.
    private enum StoreyHeight {
        static let residential: Float = 3.1
        static let commercial: Float = 3.9
        static let industrial: Float = 5.4
        static let civic: Float = 4.6
        static let `default`: Float = 3.3
    }

    /// Ground-floor storeys are usually taller than the ones above (retail, lobbies, loading).
    private static let groundFloorBonusMeters: Float = 1.2

    // MARK: - Height

    struct ResolvedHeight {
        let heightMeters: Float
        let accuracy: UAVWorldHeightAccuracy
        let levels: Int?
    }

    static func resolveHeight(for record: UAVWorldBuildingSourceRecord) -> ResolvedHeight {
        // Tier 1 — the source states a height. Trust it, but reject absurdities: negative or
        // implausibly tall values are a well-known failure mode of crowd-sourced height tags
        // (unit confusion, typos, a "height" that is actually a floor count).
        if let stated = record.statedHeightMeters, stated.isFinite, stated > 1.0, stated < 900.0 {
            return ResolvedHeight(
                heightMeters: stated,
                accuracy: .measured,
                levels: record.levels
            )
        }

        // Tier 2 — a floor count, converted with a use-appropriate storey height.
        if let levels = record.levels, levels > 0, levels < 200 {
            let storey = storeyHeight(for: record.useClass)
            let height = Float(levels) * storey + groundFloorBonusMeters
            return ResolvedHeight(
                heightMeters: height,
                accuracy: .derivedFromLevels,
                levels: levels
            )
        }

        // Tier 3 — nothing but a footprint. Estimate from use class and size. This is openly a
        // guess; it exists so a sparsely-mapped region still yields a flyable, obstacle-bearing
        // world rather than a plain of zero-height slabs, and it is tagged `.estimated` so
        // clearance planning can refuse to rely on it.
        let estimated = estimateHeight(
            useClass: record.useClass,
            footprintAreaSquareMeters: record.footprintAreaSquareMeters
        )
        return ResolvedHeight(
            heightMeters: estimated,
            accuracy: .estimated,
            levels: nil
        )
    }

    private static func storeyHeight(for useClass: String?) -> Float {
        switch normalized(useClass) {
        case "commercial", "office", "retail", "hotel":
            return StoreyHeight.commercial
        case "industrial", "warehouse", "hangar":
            return StoreyHeight.industrial
        case "church", "cathedral", "civic", "school", "hospital", "museum":
            return StoreyHeight.civic
        case "residential", "apartments", "house", "detached", "terrace":
            return StoreyHeight.residential
        default:
            return StoreyHeight.default
        }
    }

    private static func estimateHeight(
        useClass: String?,
        footprintAreaSquareMeters area: Float
    ) -> Float {
        switch normalized(useClass) {
        case "industrial", "warehouse", "hangar":
            // Big sheds are wide and low; small ones are workshops.
            return area > 2_000 ? 11.0 : 7.5
        case "garage", "carport", "shed", "hut":
            return 3.2
        case "church", "cathedral":
            return 17.0
        case "office", "commercial", "retail", "hotel":
            // Larger commercial plates tend to belong to taller buildings.
            return area > 1_500 ? 24.0 : 12.0
        case "house", "detached", "bungalow":
            return 6.5
        case "apartments", "residential":
            return area > 800 ? 18.0 : 9.5
        default:
            // Deliberately modest: over-estimating unknown buildings litters a map with
            // phantom obstacles, which is worse for flight testing than under-estimating.
            return area > 1_200 ? 12.0 : 8.0
        }
    }

    // MARK: - Roof

    static func resolveRoofForm(for record: UAVWorldBuildingSourceRecord) -> UAVWorldRoofForm {
        // An explicit statement always wins.
        switch normalized(record.roofShape) {
        case "gabled", "gable":
            return .gabled
        case "hipped", "hip", "half-hipped":
            return .hipped
        case "pyramidal", "pyramid":
            return .pyramidal
        case "dome", "domed", "onion":
            return .domed
        case "skillion", "lean_to", "shed":
            return .skillion
        case "mansard":
            return .mansard
        case "flat":
            return .flat
        default:
            break
        }

        // Otherwise infer. Pitched roofs belong to small, low buildings; anything tall or with a
        // large plate is flat in practice, and guessing a pitch on a city block produces a
        // distinctly wrong, village-like skyline.
        let area = record.footprintAreaSquareMeters
        let levels = record.levels ?? 0
        switch normalized(record.useClass) {
        case "house", "detached", "bungalow", "terrace", "hut", "shed", "garage":
            return area < 400 ? .gabled : .flat
        case "church", "cathedral":
            return .gabled
        default:
            if levels > 0, levels <= 2, area < 300 {
                return .gabled
            }
            return .flat
        }
    }

    /// Rise from eaves to ridge. Proportional to the building's smaller plan dimension via its
    /// area, and capped so a large hall does not acquire a cathedral-scale roof.
    static func roofRiseMeters(
        form: UAVWorldRoofForm,
        footprintAreaSquareMeters area: Float
    ) -> Float {
        guard form.hasRaisedProfile else { return 0.0 }
        let approximateSpan = max(4.0, area.squareRoot())
        switch form {
        case .flat:
            return 0.0
        case .skillion:
            return min(2.5, approximateSpan * 0.12)
        case .mansard:
            return min(4.0, approximateSpan * 0.18)
        case .gabled, .hipped:
            return min(6.5, approximateSpan * 0.28)
        case .pyramidal:
            return min(8.0, approximateSpan * 0.35)
        case .domed:
            return min(12.0, approximateSpan * 0.42)
        }
    }

    // MARK: - Facade class

    static func resolveFacadeClass(
        for record: UAVWorldBuildingSourceRecord,
        resolvedHeightMeters: Float
    ) -> UAVWorldFacadeClass {
        // A stated cladding material is the strongest evidence available and overrides every
        // era heuristic below.
        switch normalized(record.claddingMaterial) {
        case "brick", "brick_block":
            return .brickPrewar
        case "glass", "glass_curtain_wall":
            return .glassCurtainWall
        case "concrete", "cement_block", "reinforced_concrete":
            return .concretePostwar
        case "metal", "metal_sheet", "steel", "aluminium":
            return .metalPanel
        case "stone", "sandstone", "limestone", "granite", "marble":
            return .stoneMasonry
        case "plaster", "stucco", "render":
            return .stucco
        default:
            break
        }

        let use = normalized(record.useClass)
        if ["industrial", "warehouse", "hangar", "factory"].contains(use) {
            return .industrial
        }

        let levels = record.levels ?? Int(resolvedHeightMeters / StoreyHeight.default)
        let isTall = resolvedHeightMeters >= 40.0 || levels >= 12
        let isLowRise = resolvedHeightMeters <= 12.0 || levels <= 3

        // Construction era, where known, is the best single predictor of cladding.
        if let year = record.yearBuilt, year > 1500, year <= 2100 {
            switch year {
            case ..<1940:
                // Prewar towers were masonry- and terracotta-clad over steel frames; prewar
                // low-rise is overwhelmingly brick.
                return isTall ? .stoneMasonry : .brickPrewar
            case 1940..<1980:
                // The postwar era splits sharply by height, and collapsing it into "concrete"
                // was visibly wrong when checked against real data: 28 Liberty (1961) and the
                // Marine Midland Building (1967) came out concrete, when both are International
                // Style curtain-wall towers. By the 1950s every tall building was clad in glass
                // and metal; poured concrete belongs to the low- and mid-rise stock of the same
                // decades.
                return isTall ? .glassCurtainWall : .concretePostwar
            default:
                return isTall ? .glassCurtainWall : .concretePostwar
            }
        }

        // No era information. Fall back on form and use, which still separates the three
        // silhouettes that matter most from the air.
        if isTall {
            return .glassCurtainWall
        }
        if isLowRise {
            if ["house", "detached", "bungalow", "terrace", "apartments", "residential"].contains(use) {
                return .residentialLowRise
            }
            return .brickPrewar
        }
        return .concretePostwar
    }

    // MARK: - Confidence

    /// Overall trust in the finished record. Starts from the height accuracy — the dominant
    /// term, since height is what flight safety depends on — and is adjusted by how much
    /// corroborating metadata the source supplied.
    static func resolveConfidence(
        heightAccuracy: UAVWorldHeightAccuracy,
        record: UAVWorldBuildingSourceRecord,
        footprintVertexCount: Int
    ) -> Float {
        var confidence = heightAccuracy.confidenceWeight

        if record.useClass != nil { confidence += 0.06 }
        if record.yearBuilt != nil { confidence += 0.06 }
        if record.claddingMaterial != nil { confidence += 0.05 }
        if record.roofShape != nil { confidence += 0.04 }

        // A footprint reduced to a bare quadrilateral is often a coarse approximation of a more
        // complex building; a richly-detailed ring usually came from a real survey.
        if footprintVertexCount <= 4 { confidence -= 0.05 }
        if footprintVertexCount >= 12 { confidence += 0.04 }

        // Slivers and specks are usually digitisation artefacts.
        if record.footprintAreaSquareMeters < 12.0 { confidence -= 0.15 }

        return min(1.0, max(0.0, confidence))
    }

    // MARK: - Helpers

    private static func normalized(_ value: String?) -> String {
        guard let value else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
