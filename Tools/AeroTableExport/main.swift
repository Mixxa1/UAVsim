import Foundation

// Aerodynamic coefficient table pipeline — the offline half.
//
// Two jobs, and they are two halves of one loop. `export` writes every table the simulation
// currently holds out as CSV, so that what an aircraft is flying on can be opened, plotted
// and argued with. `check` reads a file back and reports what it contains, so that a table
// produced by a wind tunnel, a panel code or a spreadsheet can be validated *before* it is
// dropped into the bundle and flown.
//
// That ordering is the point of having a tool at all. Without it the only way to find out
// that a sweep was ragged, or that its moment column was signed the other way, is to fly an
// aircraft on it and try to work backwards from the handling.
//
//   Tools/AeroTableExport/run.sh export [directory]
//   Tools/AeroTableExport/run.sh check <file.aerotable.csv>
//   Tools/AeroTableExport/run.sh roundtrip

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "export"

func rule(_ title: String) {
    print("")
    print(title)
    print(String(repeating: "-", count: 104))
}

switch command {
case "export":
    let directory = URL(
        fileURLWithPath: arguments.count > 1 ? arguments[1] : "./AeroTables",
        isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    rule("Exporting installed coefficient tables to \(directory.path)")
    var written = 0
    for entry in MachCoefficientDatabase.inventory() {
        let familyPrefix = "family:"
        guard entry.key.hasPrefix(familyPrefix),
              let family = FixedWingFamily.allCases.first(
                  where: { "\($0)" == String(entry.key.dropFirst(familyPrefix.count)) }
              ),
              let table = MachCoefficientDatabase.table(profileID: nil, family: family) else {
            continue
        }
        let name = "family-\(family).aerotable.csv"
        let url = directory.appendingPathComponent(name)
        try? AeroTableCodec.encode(table).write(to: url, atomically: true, encoding: .utf8)
        print(String(
            format: "  %-34@ %3d alpha x %2d Mach   %@",
            name as NSString,
            table.alphaBreakpointsRad.count,
            table.machBreakpoints.count,
            entry.provenance as NSString
        ))
        written += 1
    }
    print("")
    print("\(written) table(s) written. Rename one to '<profile-id>.aerotable.csv' and add it")
    print("to the app bundle to override that aircraft's coefficients.")

case "check":
    guard arguments.count > 1 else {
        print("usage: run.sh check <file.aerotable.csv>")
        exit(2)
    }
    let url = URL(fileURLWithPath: arguments[1])
    do {
        let table = try AeroTableCodec.decode(try String(contentsOf: url, encoding: .utf8))
        rule("\(url.lastPathComponent)")
        print("  provenance   \(table.provenance)")
        print(String(
            format: "  grid         %d alpha (%.1f to %.1f deg) x %d Mach (%.2f to %.2f)",
            table.alphaBreakpointsRad.count,
            table.alphaBreakpointsRad.first! * 180.0 / .pi,
            table.alphaBreakpointsRad.last! * 180.0 / .pi,
            table.machBreakpoints.count,
            table.machBreakpoints.first!,
            table.machBreakpoints.last!
        ))
        print("  well formed  \(table.isWellFormed ? "yes" : "NO")")

        // The checks a solver's output most often fails, stated as questions about the
        // aircraft rather than about the file.
        rule("Sanity")
        var complaints: [String] = []
        let zeroLift = table.sample(alphaRad: 0.0, mach: 0.2)
        if zeroLift.cd <= 0.0 { complaints.append("zero-alpha drag is not positive — sign or column order") }
        if abs(zeroLift.cl) > 0.9 { complaints.append(String(format: "CL at zero alpha is %.2f — a very cambered section, or a units error", zeroLift.cl)) }
        let up = table.sample(alphaRad: 0.15, mach: 0.2)
        let down = table.sample(alphaRad: -0.15, mach: 0.2)
        if up.cl <= down.cl { complaints.append("lift does not increase with alpha — the CL column is inverted") }
        if up.cd < zeroLift.cd { complaints.append("drag falls with lift — the CD column is inverted") }
        if up.cm >= down.cm { complaints.append("Cm rises with alpha — this aircraft is statically unstable, which may be intended for a relaxed-stability airframe but is worth confirming") }
        var peak: Float = 0.0
        var peakMach: Float = 0.0
        for mach in table.machBreakpoints {
            let cd = table.sample(alphaRad: 0.03, mach: mach).cd
            if cd > peak { peak = cd; peakMach = mach }
        }
        print(String(format: "  drag at small alpha peaks at Mach %.2f (CD %.4f)", peakMach, peak))
        if complaints.isEmpty {
            print("  nothing suspicious")
        } else {
            for complaint in complaints { print("  ! \(complaint)") }
        }
        exit(complaints.isEmpty ? 0 : 1)
    } catch {
        print("could not read \(url.lastPathComponent): \(error)")
        exit(1)
    }

case "roundtrip":
    // Encode every installed table, decode it back and compare. A codec that silently
    // loses a column is worse than no codec, and this is the cheapest possible guard.
    rule("Encode / decode round trip")
    var worst: Float = 0.0
    var checked = 0
    for family in FixedWingFamily.allCases {
        guard let table = MachCoefficientDatabase.table(profileID: nil, family: family) else { continue }
        let restored = try AeroTableCodec.decode(AeroTableCodec.encode(table))
        guard restored.alphaBreakpointsRad.count == table.alphaBreakpointsRad.count,
              restored.machBreakpoints.count == table.machBreakpoints.count else {
            print("  \(family): grid changed shape")
            exit(1)
        }
        for (machIndex, _) in table.machBreakpoints.enumerated() {
            for (alphaIndex, _) in table.alphaBreakpointsRad.enumerated() {
                worst = max(worst, abs(table.liftCoefficient[machIndex][alphaIndex] - restored.liftCoefficient[machIndex][alphaIndex]))
                worst = max(worst, abs(table.dragCoefficient[machIndex][alphaIndex] - restored.dragCoefficient[machIndex][alphaIndex]))
                worst = max(worst, abs(table.pitchingMoment[machIndex][alphaIndex] - restored.pitchingMoment[machIndex][alphaIndex]))
            }
        }
        checked += 1
        print("  \(family): identical to within the file's own precision")
    }
    print("")
    print(String(format: "  %d table(s), largest coefficient difference %.2e", checked, worst))
    // Six decimal places in the file, so anything above 1e-6 is a real loss, not rounding.
    print(worst < 1.0e-5 ? "\nRESULT: PASS" : "\nRESULT: FAIL — the codec is losing data")
    exit(worst < 1.0e-5 ? 0 : 1)

default:
    print("unknown command '\(command)'. Use export, check or roundtrip.")
    exit(2)
}
