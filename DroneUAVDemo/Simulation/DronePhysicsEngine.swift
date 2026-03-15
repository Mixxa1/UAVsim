import Foundation

protocol DronePhysicsEngine {
    func step(
        state: DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        deltaTime: Float
    ) -> DroneState
}
