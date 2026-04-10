import Foundation

final class MissionTimelineBuilder {
    func startTimeline(
        projectID: String,
        projectName: String,
        missionPlanID: UUID?
    ) -> MissionTimeline {
        let now = Date()
        return MissionTimeline(
            id: UUID(),
            projectID: projectID,
            projectName: projectName,
            missionPlanID: missionPlanID,
            startedAt: now,
            endedAt: nil,
            outcome: nil,
            events: [],
            lastUpdatedAt: now
        )
    }

    func appending(
        _ event: MissionEvent,
        to timeline: MissionTimeline
    ) -> MissionTimeline {
        var nextTimeline = timeline
        nextTimeline.events.append(event)
        if nextTimeline.events.count > 256 {
            nextTimeline.events.removeFirst(nextTimeline.events.count - 256)
        }
        nextTimeline.lastUpdatedAt = event.timestamp
        return nextTimeline
    }

    func finalize(
        timeline: MissionTimeline,
        outcome: MissionOutcome,
        endedAt: Date = Date()
    ) -> MissionTimeline {
        var nextTimeline = timeline
        nextTimeline.outcome = outcome
        nextTimeline.endedAt = endedAt
        nextTimeline.lastUpdatedAt = endedAt
        return nextTimeline
    }
}
