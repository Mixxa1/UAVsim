import Foundation

@MainActor
protocol OnlineTrialSnapshotTransport: AnyObject {
    func sendVehicleSnapshot(_ snapshot: OnlineVehicleStateSnapshot)
}

// P2P v1.2: authority owner submits shared events via this protocol.
// LANSessionViewModel conforms; host relays/orders/deduplicates.
@MainActor
protocol OnlineSharedEventTransport: AnyObject {
    func submitSharedEvent(_ event: OnlineSharedEvent)
}
