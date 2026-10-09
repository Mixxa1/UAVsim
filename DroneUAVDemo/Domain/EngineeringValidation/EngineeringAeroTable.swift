import Foundation
import simd

/// Portable solver output. Forces use an orthonormal wind frame; moments use the simulator's
/// right-hand convention (roll about aft, pitch about right, yaw about up). No implicit CG.
struct EngineeringAeroTable: Codable, Hashable {
    /// Flow models the CFD adapter computes, as its --capabilities lists them. One list for the
    /// run settings and for the table a run returns: a model that can be launched must be readable.
    static let solverModels = ["euler", "laminar", "sst", "urans_sst"]

    struct Reference: Codable, Hashable {
        var areaM2: Double
        var spanM: Double
        var chordM: Double
        var momentCenterModelM: [Double]
    }
    struct Point: Codable, Hashable {
        var alphaDeg: Double
        var betaDeg: Double
        var cl: Double
        var cd: Double
        var cm: Double
        var cy: Double
        var cRoll: Double
        var cYaw: Double

        var coefficients: [Double] { [cl, cd, cm, cy, cRoll, cYaw] }
    }
    var schema: String
    var frame: String
    var reference: Reference
    var speedMps: Double
    var densityKgM3: Double
    var viscosityPaS: Double
    var model: String
    var alphaDeg: [Double]
    var betaDeg: [Double]
    /// alpha-major, beta-minor. The decoder verifies every coordinate, not just the count.
    var points: [Point]

    var problem: String? {
        guard schema == "uavsim-aerodynamics/1", frame == "flight-body-rhu" else { return "Несовместимая схема или система осей аэротаблицы." }
        guard Self.solverModels.contains(model) || model == "imported" else { return "Неизвестная модель течения." }
        guard [reference.areaM2, reference.spanM, reference.chordM, speedMps, densityKgM3, viscosityPaS].allSatisfy({ $0.isFinite && $0 > 0 && Float($0).isFinite }),
              speedMps <= 100, reference.momentCenterModelM.count == 3,
              reference.momentCenterModelM.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { return "Неверные опорные размеры, точка момента или условия." }
        for angles in [alphaDeg, betaDeg] {
            guard !angles.isEmpty, angles.count <= 181,
                  angles.allSatisfy({ $0.isFinite && abs($0) <= 75 }),
                  zip(angles, angles.dropFirst()).allSatisfy({ $0 < $1 }) else { return "Углы должны строго возрастать в диапазоне −75…75°." }
        }
        guard points.count <= 256, points.count == alphaDeg.count * betaDeg.count else { return "Аэротаблица не образует полную сетку α × β." }
        for (i, p) in points.enumerated() {
            guard p.alphaDeg == alphaDeg[i / betaDeg.count], p.betaDeg == betaDeg[i % betaDeg.count],
                  p.coefficients.allSatisfy({ $0.isFinite && abs($0) <= 1e6 }), p.cd >= 0 else { return "Неверный порядок, пропуск точки или нечисловые коэффициенты." }
        }
        return nil
    }

    var usableForFlight: Bool {
        problem == nil && model != "euler" && alphaDeg.count >= 2 && alphaDeg.first! <= 0 && alphaDeg.last! > 0
            && betaDeg.contains(0)
    }
    var hasBetaSweep: Bool { betaDeg.count > 1 }

    /// A measured positive-alpha peak followed by a ≥2% (or 0.001 absolute) loss
    /// of CL brackets possible stall. A monotone polar supplies no stall evidence.
    var possibleStallBracketDeg: ClosedRange<Double>? {
        guard model != "euler", problem == nil else { return nil }
        let neutral = points.filter { $0.betaDeg == 0 && $0.alphaDeg >= 0 }
        guard let peak = neutral.max(by: { $0.cl < $1.cl }), peak.cl > 0,
              let after = neutral.first(where: {
                  $0.alphaDeg > peak.alphaDeg && peak.cl - $0.cl >= max(0.001, 0.02 * abs(peak.cl))
              }) else { return nil }
        return peak.alphaDeg...after.alphaDeg
    }

    var fingerprint: String {
        // Only the physical data: iterations and artifact paths never change downstream results.
        let encoded = try? JSONEncoder().encode(self)
        return encoded.flatMap { try? JSONDecoder().decode(EngineeringCanonicalValue.self, from: $0) }?.fingerprint ?? "invalid-aero-table"
    }

    /// Bilinear interpolation, with no extrapolation past measured alpha/beta. An alpha-only
    /// table carries no lateral model; the consumer keeps its existing lateral derivatives.
    func sample(alphaRad: Double, betaRad: Double) -> Point? {
        guard alphaRad.isFinite, betaRad.isFinite, !alphaDeg.isEmpty, !betaDeg.isEmpty,
              points.count == alphaDeg.count * betaDeg.count else { return nil }
        let a = alphaRad * 180 / .pi, b = hasBetaSweep ? betaRad * 180 / .pi : betaDeg[0]
        guard a >= alphaDeg[0], a <= alphaDeg.last!, b >= betaDeg[0], b <= betaDeg.last! else { return nil }
        func bracket(_ values: [Double], _ value: Double) -> (Int, Int, Double) {
            if values.count == 1 { return (0, 0, 0) }
            let high = min(values.count - 1, max(1, values.firstIndex { $0 >= value } ?? values.count - 1))
            let low = high - 1
            return (low, high, (value - values[low]) / (values[high] - values[low]))
        }
        let (a0, a1, ta) = bracket(alphaDeg, a), (b0, b1, tb) = bracket(betaDeg, b)
        let p00 = points[a0 * betaDeg.count + b0], p01 = points[a0 * betaDeg.count + b1]
        let p10 = points[a1 * betaDeg.count + b0], p11 = points[a1 * betaDeg.count + b1]
        func blend(_ key: KeyPath<Point, Double>) -> Double {
            let low = p00[keyPath: key] * (1 - tb) + p01[keyPath: key] * tb
            let high = p10[keyPath: key] * (1 - tb) + p11[keyPath: key] * tb
            return low * (1 - ta) + high * ta
        }
        return Point(alphaDeg: a, betaDeg: b, cl: blend(\.cl), cd: blend(\.cd), cm: blend(\.cm),
                     cy: blend(\.cy), cRoll: blend(\.cRoll), cYaw: blend(\.cYaw))
    }
}

struct EngineeringAeroRuntime: Hashable {
    var table: EngineeringAeroTable
    var centerOfMassModelM: SIMD3<Double>
    var source: EngineeringResultSource
    var solverVersion: String

    func sample(alphaRad: Float, betaRad: Float = 0, mach: Float = 0) -> EngineeringAeroTable.Point? {
        guard mach.isFinite, mach >= 0, mach <= 0.3,
              var point = table.sample(alphaRad: Double(alphaRad), betaRad: Double(betaRad)) else { return nil }
        // M_CG = M_ref + (ref - CG) × F, in physical flight XYZ (+right,+up,+aft).
        let a = Double(alphaRad), b = table.hasBetaSweep ? Double(betaRad) : 0
        let drag = SIMD3(-sin(b), sin(a) * cos(b), cos(a) * cos(b))
        let lift = SIMD3(0.0, cos(a), -sin(a))
        let side = SIMD3(cos(b), sin(a) * sin(b), cos(a) * sin(b))
        let f = point.cd * drag + point.cl * lift + point.cy * side
        let ref = table.reference.momentCenterModelM
        let modelOffset = SIMD3(ref[0], ref[1], ref[2]) - centerOfMassModelM
        let flightOffset = SIMD3(-modelOffset.x, modelOffset.y, -modelOffset.z)
        let moment = simd_cross(flightOffset, f)
        point.cm += moment.x / table.reference.chordM
        point.cRoll += moment.z / table.reference.spanM
        point.cYaw += moment.y / table.reference.spanM
        return point
    }

    /// Resolved once when a blueprint becomes a runtime profile, not in every physics substep.
    static func resolve(build: WorkbenchBuild) -> EngineeringAeroRuntime? {
        let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: build.aerodynamicRuns.map(\.record))
        guard let evaluation = state.evaluation(.aerodynamics), evaluation.status.isCurrent,
              let record = evaluation.record, record.outcome == .pass || record.outcome == .warning,
              let table = record.aerodynamicTable, table.usableForFlight else { return nil }
        return EngineeringAeroRuntime(table: table, centerOfMassModelM: WorkbenchBuildAnalyzer.analyze(build).centerOfMass,
                                      source: record.source, solverVersion: record.solverVersion)
    }
}
