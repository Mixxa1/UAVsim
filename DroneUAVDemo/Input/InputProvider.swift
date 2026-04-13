import Foundation

protocol InputProvider: AnyObject {
    var sourceKind: InputSourceKind { get }
    var isEnabled: Bool { get set }

    func update(deltaTime: TimeInterval)
    func currentSnapshot() -> InputSnapshot
}
