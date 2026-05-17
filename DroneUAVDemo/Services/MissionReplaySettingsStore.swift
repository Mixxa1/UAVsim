import Foundation

final class MissionReplaySettingsStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let key = "MissionReplayRetentionPolicy"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPolicy() -> MissionReplayRetentionPolicy {
        guard let data = defaults.data(forKey: key),
              let policy = try? decoder.decode(MissionReplayRetentionPolicy.self, from: data) else {
            return .defaultPolicy
        }
        return policy.clamped
    }

    func savePolicy(_ policy: MissionReplayRetentionPolicy) {
        guard let data = try? encoder.encode(policy.clamped) else { return }
        defaults.set(data, forKey: key)
    }
}
