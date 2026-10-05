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
}
