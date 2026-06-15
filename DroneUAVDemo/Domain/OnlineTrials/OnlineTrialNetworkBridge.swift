import Foundation

@MainActor
protocol OnlineTrialSnapshotTransport: AnyObject {
    func sendVehicleSnapshot(_ snapshot: OnlineVehicleStateSnapshot)
}
