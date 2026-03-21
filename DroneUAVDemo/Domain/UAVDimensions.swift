import Foundation

struct UAVDimensions: Hashable {
    let foldedMillimeters: DroneDimensionsMM?
    let unfoldedMillimeters: DroneDimensionsMM?
    let diagonalWheelbaseMillimeters: Float?
    let wingspanMillimeters: Float?
    let fuselageLengthMillimeters: Float?
    let heightMillimeters: Float?

    init(
        foldedMillimeters: DroneDimensionsMM? = nil,
        unfoldedMillimeters: DroneDimensionsMM? = nil,
        diagonalWheelbaseMillimeters: Float? = nil,
        wingspanMillimeters: Float? = nil,
        fuselageLengthMillimeters: Float? = nil,
        heightMillimeters: Float? = nil
    ) {
        self.foldedMillimeters = foldedMillimeters
        self.unfoldedMillimeters = unfoldedMillimeters
        self.diagonalWheelbaseMillimeters = diagonalWheelbaseMillimeters
        self.wingspanMillimeters = wingspanMillimeters
        self.fuselageLengthMillimeters = fuselageLengthMillimeters
        self.heightMillimeters = heightMillimeters
    }

    func resolvedUnfoldedMillimeters(fallback: DroneDimensionsMM) -> DroneDimensionsMM {
        if let unfoldedMillimeters {
            return unfoldedMillimeters
        }

        return DroneDimensionsMM(
            x: wingspanMillimeters ?? fallback.x,
            y: fuselageLengthMillimeters ?? fallback.y,
            z: heightMillimeters ?? fallback.z
        )
    }

    func resolvedFoldedMillimeters(fallback: DroneDimensionsMM) -> DroneDimensionsMM {
        if let foldedMillimeters {
            return foldedMillimeters
        }

        let unfolded = resolvedUnfoldedMillimeters(fallback: fallback)
        return DroneDimensionsMM(
            x: max(fallback.x * 0.45, unfolded.x * 0.58),
            y: max(fallback.y * 0.40, unfolded.y * 0.46),
            z: max(fallback.z * 0.82, unfolded.z * 0.88)
        )
    }
}
