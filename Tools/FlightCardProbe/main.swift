// Headless flight cards: every fixed wing in the catalogue flown for the figures its own entry
// declares, and the two set side by side.
//
// The measuring is done by `AirframeFlightCard` in the app's own sources — this file only asks for
// each card, prints it, and holds it against the baseline beside it. `--json <path>` writes the
// cards out; `--only <id>` flies one airframe.
//
// What fails the run is a figure that MOVED. `baseline.json` is every measured figure of every
// airframe as of the last time somebody looked at them and wrote them down; a change to the
// solver that shifts one of them by more than half a per cent is a change to how that aircraft
// flies, and the run says which. The lines outside their bands are printed on every run and do
// not fail it: there are about twenty, each a standing finding, and a probe that is always red
// cannot tell anybody that something new has broken. `--rebaseline` writes the file again —
// after reading what moved and deciding it should have.
import Foundation

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}
let only = value(after: "--only")
let jsonPath = value(after: "--json")
let rebaseline = arguments.contains("--rebaseline")
let baselinePath = value(after: "--baseline") ?? "Tools/FlightCardProbe/baseline.json"

struct BaselineEntry: Codable {
    let airframeID: String
    let displayName: String
    /// Measured figure by quantity; a line that was not measured is not here.
    let measured: [String: Float]
}

func column(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
func figure(_ value: Float?, _ format: String = "%.1f") -> String { value.map { String(format: format, $0) } ?? "—" }

let repository = LIPODroneModelRepository()
var cards: [AirframeFlightCard] = []
let started = Date()

func pair(_ card: AirframeFlightCard, _ quantity: FlightCardLine.Quantity, _ format: String = "%.1f") -> String {
    guard let line = card.line(quantity) else { return "—" }
    let mark = line.verdict == .outside ? "!" : ""
    return "\(figure(line.declared, format)) / \(figure(line.measured, format))\(mark)"
}
func wanted(_ profile: DroneModelProfile) -> Bool { only == nil || profile.id == only }

print("Fixed wings — declared / measured, at maximum takeoff weight; stall and climb at 300 m, the rest at the airframe's own cruise height")
print(String(repeating: "-", count: 150))
print(column("airframe", 28) + column("MTOW kg", 9) + column("at m", 7) + column("stall m/s", 15) + column("cruise m/s", 15)
      + column("max m/s", 16) + column("climb m/s", 15) + column("endurance h", 15) + column("L/D idle", 10)
      + column("cruise lever", 14) + "outside")
for profile in repository.allProfiles where profile.airframeClass == .fixedWing && wanted(profile) {
    guard let card = AirframeFlightCard.measure(profile: profile) else { continue }
    cards.append(card)
    let lever: String = {
        guard let asked = card.cruiseLeverAsked, let held = card.cruiseLeverHeld else { return "—" }
        return abs(asked - held) > 0.05 ? String(format: "%.2f→%.2f", asked, held) : String(format: "%.2f", held)
    }()
    print(column(card.displayName, 28) + column(figure(card.flownMassKg, "%.0f"), 9) + column(figure(card.workingAltitudeM, "%.0f"), 7)
          + column(pair(card, .stallSpeed), 15) + column(pair(card, .cruiseSpeed), 15) + column(pair(card, .maximumSpeed), 16)
          + column(pair(card, .climbRate), 15) + column(pair(card, .endurance), 15)
          + column(figure(card.line(.glideRatio)?.measured), 10) + column(lever, 14)
          + card.outside.map(\.quantity.rawValue).joined(separator: ", "))
}

print("")
print("Hybrid VTOL, on the wing — declared / measured, at maximum takeoff weight")
print(String(repeating: "-", count: 150))
print(column("airframe", 28) + column("MTOW kg", 9) + column("at m", 7) + column("stall m/s", 15) + column("cruise m/s", 15)
      + column("max m/s", 16) + column("climb m/s", 15) + column("endurance h", 15) + column("L/D idle", 10)
      + column("cruise lever", 14) + "outside")
for profile in repository.allProfiles where profile.airframeClass == .hybridVTOL && wanted(profile) {
    guard let card = AirframeFlightCard.measure(profile: profile) else { continue }
    cards.append(card)
    let lever: String = {
        guard let asked = card.cruiseLeverAsked, let held = card.cruiseLeverHeld else { return "—" }
        return abs(asked - held) > 0.05 ? String(format: "%.2f→%.2f", asked, held) : String(format: "%.2f", held)
    }()
    print(column(card.displayName, 28) + column(figure(card.flownMassKg, "%.0f"), 9) + column(figure(card.workingAltitudeM, "%.0f"), 7)
          + column(pair(card, .stallSpeed), 15) + column(pair(card, .cruiseSpeed), 15) + column(pair(card, .maximumSpeed), 16)
          + column(pair(card, .climbRate), 15) + column(pair(card, .endurance), 15)
          + column(figure(card.line(.glideRatio)?.measured), 10) + column(lever, 14)
          + card.outside.map(\.quantity.rawValue).joined(separator: ", "))
}

print("")
print("Multirotors — declared / measured, at their own takeoff weight, 300 m")
print(String(repeating: "-", count: 118))
print(column("airframe", 30) + column("kg", 8) + column("hover lever", 15) + column("climb m/s", 15)
      + column("max m/s", 16) + column("endurance h", 16) + "outside")
for profile in repository.allProfiles where profile.airframeClass == .multirotor && wanted(profile) {
    guard let card = AirframeFlightCard.measure(profile: profile) else { continue }
    cards.append(card)
    print(column(card.displayName, 30) + column(figure(card.flownMassKg, "%.2f"), 8)
          + column(pair(card, .hoverLever, "%.2f"), 15) + column(pair(card, .climbRate), 15)
          + column(pair(card, .maximumSpeed), 16) + column(pair(card, .endurance, "%.2f"), 16)
          + card.outside.map(\.quantity.rawValue).joined(separator: ", "))
}

print("")
print(String(format: "%d cards in %.1f s", cards.count, Date().timeIntervalSince(started)))
for quantity in FlightCardLine.Quantity.allCases {
    let lines = cards.compactMap { $0.line(quantity) }
    let judged = lines.filter { $0.verdict == .within || $0.verdict == .outside }
    guard !judged.isEmpty else { continue }
    let outside = judged.filter { $0.verdict == .outside }.count
    print(column("  \(quantity.rawValue)", 18) + "\(judged.count - outside) of \(judged.count) inside the band"
          + (lines.count > judged.count ? ", \(lines.count - judged.count) not measured" : ""))
}

if let jsonPath {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(cards).write(to: URL(fileURLWithPath: jsonPath))
    print("written to \(jsonPath)")
}

let failing = cards.filter { !$0.outside.isEmpty }
print("")
for card in failing {
    let lines = card.outside.map { line in
        String(format: "%@ %@ against a declared %@ (%.0f %%)", line.quantity.rawValue, figure(line.measured, "%.2f"),
               figure(line.declared, "%.2f"), (line.ratio ?? 0) * 100)
    }
    print("OUTSIDE: \(card.displayName): " + lines.joined(separator: "; "))
}

let flown = cards.map { card in
    BaselineEntry(airframeID: card.airframeID, displayName: card.displayName,
                  measured: Dictionary(uniqueKeysWithValues: card.lines.compactMap { line in
                      line.measured.map { (line.quantity.rawValue, $0) }
                  }))
}.sorted { $0.airframeID < $1.airframeID }
let baselineURL = URL(fileURLWithPath: baselinePath)

if rebaseline {
    guard only == nil else {
        print("RESULT: FAIL - a baseline is the whole catalogue; --rebaseline does not go with --only")
        exit(1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(flown).write(to: baselineURL)
    print("RESULT: PASS - baseline written for \(flown.count) airframes to \(baselinePath); \(failing.count) carry a line outside its band")
    exit(0)
}

guard let stored = try? JSONDecoder().decode([BaselineEntry].self, from: Data(contentsOf: baselineURL)) else {
    print("RESULT: FAIL - no baseline at \(baselinePath); write one with --rebaseline")
    exit(1)
}

/// Half a per cent, or the last digit the tables print: a lever is read to a hundredth.
func hasMoved(_ quantity: String, from old: Float, to new: Float) -> Bool {
    let floor: Float = quantity == FlightCardLine.Quantity.hoverLever.rawValue ? 0.005 : 0.03
    return abs(new - old) > max(0.005 * abs(old), floor)
}
var moved: [String] = []
let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.airframeID, $0) })
for entry in flown {
    guard let before = storedByID[entry.airframeID] else {
        moved.append("\(entry.displayName): not in the baseline")
        continue
    }
    for quantity in Set(entry.measured.keys).union(before.measured.keys).sorted() {
        switch (before.measured[quantity], entry.measured[quantity]) {
        case let (old?, new?) where hasMoved(quantity, from: old, to: new):
            moved.append(String(format: "%@: %@ %.3f → %.3f (%+.1f %%)", entry.displayName, quantity, old, new, (new / old - 1) * 100))
        case (_?, nil):
            moved.append("\(entry.displayName): \(quantity) was measured and no longer is")
        case (nil, _?):
            moved.append("\(entry.displayName): \(quantity) is measured now and was not")
        default:
            break
        }
    }
}
if only == nil {
    let flownIDs = Set(flown.map(\.airframeID))
    for entry in stored where !flownIDs.contains(entry.airframeID) {
        moved.append("\(entry.displayName): in the baseline and not flown")
    }
}

if moved.isEmpty {
    print("RESULT: PASS - nothing has moved against the baseline; \(failing.count) of \(cards.count) airframes carry a line outside its band")
} else {
    for line in moved { print("MOVED: \(line)") }
    print("RESULT: FAIL - \(moved.count) figures have moved against the baseline")
    exit(1)
}
