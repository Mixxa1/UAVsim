import Foundation

/// Reads and writes aerodynamic coefficient tables as text.
///
/// The point of a table is that it can come from somewhere other than this source file — a
/// wind tunnel run, a panel-method sweep, an OpenVSP or AVL batch, a solver someone else
/// owns. That only works if there is a format, and the format has to be the one those tools
/// naturally emit rather than one they have to be taught.
///
/// So: long-form CSV. One row per (alpha, Mach) point, with the coefficients alongside.
/// Every solver in the world can produce that with a nested loop and a `print`, no
/// pivoting and no fixed column count, and a human can open it in anything. The grid is
/// reconstructed on import.
///
/// ```
/// # uavsim-aero-table v1
/// # provenance: AVL sweep, NACA 65A004 section, 2026-08-30
/// alpha_deg,mach,cl,cd,cm
/// -12.0,0.00,-0.612,0.0402,0.0221
/// -10.0,0.00,-0.518,0.0331,0.0187
/// ...
/// ```
///
/// Rows may arrive in any order. What is *not* optional is that the points form a complete
/// rectangular grid: every alpha present at every Mach. A ragged sweep is rejected rather
/// than filled in, because guessing at a missing corner of someone else's data and then
/// flying an aircraft on the guess is exactly the failure this format exists to prevent.
enum AeroTableCodec {
    enum DecodeError: Error, CustomStringConvertible {
        case missingHeader
        case malformedRow(line: Int, text: String)
        case tooFewPoints
        case raggedGrid(expected: Int, found: Int)

        var description: String {
            switch self {
            case .missingHeader:
                return "no 'alpha_deg,mach,cl,cd,cm' header row"
            case let .malformedRow(line, text):
                return "line \(line) is not five numbers: \(text)"
            case .tooFewPoints:
                return "needs at least two angles of attack and two Mach numbers"
            case let .raggedGrid(expected, found):
                return "incomplete grid: expected \(expected) points, found \(found)"
            }
        }
    }

    static let headerRow = "alpha_deg,mach,cl,cd,cm"
    static let formatMarker = "# uavsim-aero-table v1"

    static func encode(_ table: AeroCoefficientTable) -> String {
        var lines: [String] = [formatMarker, "# provenance: \(table.provenance)", headerRow]
        for (machIndex, mach) in table.machBreakpoints.enumerated() {
            for (alphaIndex, alphaRad) in table.alphaBreakpointsRad.enumerated() {
                let alphaDeg = alphaRad * 180.0 / .pi
                lines.append(
                    String(
                        format: "%.4f,%.4f,%.6f,%.6f,%.6f",
                        alphaDeg,
                        mach,
                        table.liftCoefficient[machIndex][alphaIndex],
                        table.dragCoefficient[machIndex][alphaIndex],
                        table.pitchingMoment[machIndex][alphaIndex]
                    )
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func decode(_ text: String) throws -> AeroCoefficientTable {
        var provenance = "imported"
        var sawHeader = false
        var points: [(alpha: Float, mach: Float, cl: Float, cd: Float, cm: Float)] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let comment = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if comment.lowercased().hasPrefix("provenance:") {
                    provenance = comment.dropFirst("provenance:".count)
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if !sawHeader {
                // Tolerant of spacing and of extra trailing columns a spreadsheet might add.
                let normalised = line.replacingOccurrences(of: " ", with: "").lowercased()
                if normalised.hasPrefix(headerRow) {
                    sawHeader = true
                    continue
                }
                throw DecodeError.missingHeader
            }
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 5,
                  let alphaDeg = Float(fields[0]),
                  let mach = Float(fields[1]),
                  let cl = Float(fields[2]),
                  let cd = Float(fields[3]),
                  let cm = Float(fields[4]),
                  alphaDeg.isFinite, mach.isFinite, cl.isFinite, cd.isFinite, cm.isFinite else {
                throw DecodeError.malformedRow(line: index + 1, text: line)
            }
            points.append((alphaDeg * .pi / 180.0, mach, cl, cd, cm))
        }

        guard sawHeader else { throw DecodeError.missingHeader }

        // Rebuild the axes from whatever the file happened to contain. Rounded before being
        // made unique: a solver writing 0.30000001 and 0.29999998 on different rows means
        // one Mach number, and treating them as two would produce a grid nothing fills.
        func axis(_ values: [Float], quantum: Float) -> [Float] {
            var seen: Set<Int32> = []
            var result: [Float] = []
            for value in values {
                let key = Int32((value / quantum).rounded())
                if seen.insert(key).inserted {
                    result.append(Float(key) * quantum)
                }
            }
            return result.sorted()
        }
        let alphaQuantum: Float = 0.0001
        let machQuantum: Float = 0.0005
        let alphas = axis(points.map(\.alpha), quantum: alphaQuantum)
        let machs = axis(points.map(\.mach), quantum: machQuantum)
        guard alphas.count >= 2, machs.count >= 2 else { throw DecodeError.tooFewPoints }

        var alphaIndex: [Int32: Int] = [:]
        for (index, value) in alphas.enumerated() { alphaIndex[Int32((value / alphaQuantum).rounded())] = index }
        var machIndex: [Int32: Int] = [:]
        for (index, value) in machs.enumerated() { machIndex[Int32((value / machQuantum).rounded())] = index }

        let empty = [Float](repeating: .nan, count: alphas.count)
        var cl = [[Float]](repeating: empty, count: machs.count)
        var cd = cl
        var cm = cl
        var filled = 0
        for point in points {
            guard let row = machIndex[Int32((point.mach / machQuantum).rounded())],
                  let column = alphaIndex[Int32((point.alpha / alphaQuantum).rounded())] else { continue }
            if cl[row][column].isNaN { filled += 1 }
            cl[row][column] = point.cl
            cd[row][column] = point.cd
            cm[row][column] = point.cm
        }
        let expected = alphas.count * machs.count
        guard filled == expected else {
            throw DecodeError.raggedGrid(expected: expected, found: filled)
        }

        return AeroCoefficientTable(
            alphaBreakpointsRad: alphas,
            machBreakpoints: machs,
            liftCoefficient: cl,
            dragCoefficient: cd,
            pitchingMoment: cm,
            provenance: provenance
        )
    }
}

extension MachCoefficientDatabase {
    /// The filename an airframe's table is expected under.
    ///
    /// `<profile-id>.aerotable.csv` — the identifier is already the catalogue's own key, so
    /// dropping a file in with the right name is the whole of the installation step.
    static func tableFileName(profileID: String) -> String {
        "\(profileID).aerotable.csv"
    }

    /// Loads every `*.aerotable.csv` in a directory, replacing whatever was seeded.
    ///
    /// Called at launch against the app bundle, and usable against a working directory by a
    /// tool. Returns what happened rather than throwing: one bad file among twenty should
    /// not stop the other nineteen loading, and it certainly should not stop the simulation
    /// from starting — an aircraft whose table failed to load falls back to the closed-form
    /// model and flies, which is the behaviour it had before any of this existed.
    @discardableResult
    static func importTables(fromDirectory directory: URL) -> (loaded: [String], failed: [(String, String)]) {
        var loaded: [String] = []
        var failed: [(String, String)] = []
        let suffix = ".aerotable.csv"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return (loaded, failed)
        }
        for url in entries where url.lastPathComponent.hasSuffix(suffix) {
            let profileID = String(url.lastPathComponent.dropLast(suffix.count))
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let table = try AeroTableCodec.decode(text)
                if register(profileID: profileID, table: table) {
                    loaded.append(profileID)
                } else {
                    failed.append((profileID, "table failed its well-formedness check"))
                }
            } catch {
                failed.append((profileID, "\(error)"))
            }
        }
        return (loaded, failed)
    }

    /// Loads tables shipped inside the app bundle. Safe to call more than once.
    static func importBundledTables(bundle: Bundle = .main) {
        guard let resources = bundle.resourceURL else { return }
        let result = importTables(fromDirectory: resources)
        if !result.loaded.isEmpty {
            print("[Aero] loaded coefficient tables: \(result.loaded.joined(separator: ", "))")
        }
        for (profileID, reason) in result.failed {
            print("[Aero] \(profileID): \(reason)")
        }
    }
}
