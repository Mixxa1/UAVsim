import Combine
import SwiftUI

@MainActor
private final class ProbeSource: SimulationPresentationSource {
    @Published var value = 0
    lazy var uiUpdates = SimulationUIUpdates(source: self)
}

@MainActor
private final class WeakSource {
    weak var value: ProbeSource?
    init(_ source: ProbeSource) { value = source }
}

@main
struct UIPresentationProbe {
    @MainActor static func main() async {
        checkBatteryRecovery()
        checkRadioLocalization()
        let source = ProbeSource()
        let observer = SimulationObservedObject(wrappedValue: source)
        let projection: SimulationObservedObject<ProbeSource>.Projection = observer.projectedValue
        precondition(source.uiUpdates === source.uiUpdates, "Panels must share one presentation clock")
        var notifications = 0
        var latestValue = 0
        let subscription = source.uiUpdates.objectWillChange.sink {
            notifications += 1
            latestValue = source.value
        }

        projection.value.wrappedValue = 42
        precondition(source.value == 42, "Control bindings must write immediately")
        // Several state publications in each physics tick must not cause as many UI updates.
        for tick in 1...60 {
            source.value = tick
            source.value = tick + 1_000
            source.value = tick + 2_000
            try? await Task.sleep(nanoseconds: 6_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(notifications >= 2 && notifications < 60, "State bursts must be coalesced")
        precondition(latestValue == 2_060, "The final update must arrive after the burst")
        precondition(projection.value.wrappedValue == 2_060, "Bindings must read live state")
        subscription.cancel()
        print("PASS: 181 state changes → \(notifications) UI notifications; final state delivered; bindings immediate")

        var transient: ProbeSource? = ProbeSource()
        let weakSource = WeakSource(transient!)
        let clock = transient!.uiUpdates
        transient = nil
        precondition(weakSource.value == nil, "The clock must not retain its source")
        withExtendedLifetime(clock) {}
        print("PASS: shared presentation clock does not retain its source")
    }

    static func checkBatteryRecovery() {
        var battery = BatteryState.full
        precondition(!battery.shouldOfferRecharge, "A charged battery needs no recovery dialog")
        battery.chargePercent = 0
        precondition(battery.shouldOfferRecharge, "Normal depletion must still offer charging")
        battery.hasFireDamage = true
        precondition(battery.isDepleted && !battery.shouldOfferRecharge,
                     "A burnt battery must keep power off without offering charging")
        // Presentation lifetime is independent of the pack state: fading out flames/smoke
        // must not turn an unrecoverable failure back into ordinary depletion.
        let afterFire = battery
        precondition(!afterFire.shouldOfferRecharge, "Fire damage must survive subsequent state copies")
        battery = .full
        battery.chargePercent = 0
        precondition(battery.shouldOfferRecharge, "A replacement pack must allow normal recovery again")
        print("PASS: ordinary depletion offers recharge; burnt pack does not; replacement restores recovery")
    }

    static func checkRadioLocalization() {
        let resourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        for language in ["ru", "en"] {
            let bundle = Bundle(url: resourceURL.appendingPathComponent("\(language).lproj"))!
            for intent in ELRSControlIntent.allCases {
                for key in [intent.titleKey, intent.hintKey] {
                    // Catch SwiftUI treating a dynamically interpolated literal as a format
                    // key ("control_link.intent.%@") instead of the actual catalog key.
                    let swiftUIKey = LocalizedStringKey(key)
                    let resolvedKey = Mirror(reflecting: swiftUIKey).children
                        .first(where: { $0.label == "key" })?.value as? String
                    precondition(resolvedKey == key, "The UI must look up the complete intent key")
                    let translation = bundle.localizedString(forKey: resolvedKey!, value: nil, table: nil)
                    precondition(!translation.isEmpty && translation != key,
                                 "Every intent title and hint must resolve in \(language)")
                }
            }
        }
        print("PASS: all ELRS intent titles/hints resolve through SwiftUI keys in Russian and English")
    }
}
