import Foundation

final class MissionPersistenceAdapter {
    private let maxPersistedEvents: Int
    private let maxPersistedKeyEvents: Int

    init(
        maxPersistedEvents: Int = 96,
        maxPersistedKeyEvents: Int = 12
    ) {
        self.maxPersistedEvents = max(12, maxPersistedEvents)
        self.maxPersistedKeyEvents = max(6, maxPersistedKeyEvents)
    }

    func timelineForPersistence(_ timeline: MissionTimeline?) -> MissionTimeline? {
        guard var timeline else {
            return nil
        }
        if timeline.events.count > maxPersistedEvents {
            timeline.events = Array(timeline.events.suffix(maxPersistedEvents))
        }
        return timeline
    }

    func debriefForPersistence(_ debrief: MissionDebrief?) -> MissionDebrief? {
        guard var debrief else {
            return nil
        }
        if debrief.keyEvents.count > maxPersistedKeyEvents {
            debrief.keyEvents = Array(debrief.keyEvents.suffix(maxPersistedKeyEvents))
        }
        return debrief
    }

    func restoreTimeline(_ timeline: MissionTimeline?) -> MissionTimeline? {
        timeline
    }

    func restoreDebrief(_ debrief: MissionDebrief?) -> MissionDebrief? {
        debrief
    }
}
