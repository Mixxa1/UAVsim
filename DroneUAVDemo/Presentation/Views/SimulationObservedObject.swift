import Combine
import SwiftUI

/// One presentation clock shared by the simulation's panels. Physics and scene updates keep
/// their own cadence; a burst of changes only invalidates SwiftUI once per display interval.
@MainActor
final class SimulationUIUpdates: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscription: AnyCancellable?

    init<Source: ObservableObject>(source: Source, interval: TimeInterval = 1.0 / 20.0) {
        subscription = source.objectWillChange
            .throttle(for: .seconds(interval), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}

@MainActor
protocol SimulationPresentationSource: ObservableObject {
    var uiUpdates: SimulationUIUpdates { get }
}

/// Reads the live model and observes its shared presentation clock. Keeping the model itself as
/// the binding target means a slider or a controller command still changes flight state at once.
@propertyWrapper
@MainActor
struct SimulationObservedObject<Source: SimulationPresentationSource>: DynamicProperty {
    private let source: Source
    @ObservedObject private var updates: SimulationUIUpdates

    init(wrappedValue: Source) {
        source = wrappedValue
        _updates = ObservedObject(wrappedValue: wrappedValue.uiUpdates)
    }

    var wrappedValue: Source { source }
    var projectedValue: Projection { Projection(source: source) }

    @MainActor
    @dynamicMemberLookup
    struct Projection {
        let source: Source

        subscript<Value>(dynamicMember keyPath: ReferenceWritableKeyPath<Source, Value>) -> Binding<Value> {
            ObservedObject(wrappedValue: source).projectedValue[dynamicMember: keyPath]
        }
    }
}
