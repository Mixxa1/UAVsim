import Foundation

final class MissionEventRecorder {
    private let builder: MissionTimelineBuilder
    private(set) var currentTimeline: MissionTimeline?

    init(builder: MissionTimelineBuilder = MissionTimelineBuilder()) {
        self.builder = builder
    }

    func beginSession(
        projectID: String,
        projectName: String,
        missionPlanID: UUID?
    ) -> MissionTimeline {
        let timeline = builder.startTimeline(
            projectID: projectID,
            projectName: projectName,
            missionPlanID: missionPlanID
        )
        currentTimeline = timeline
        return timeline
    }

    @discardableResult
    func record(_ event: MissionEvent) -> MissionTimeline? {
        guard let currentTimeline else {
            return nil
        }
        let nextTimeline = builder.appending(event, to: currentTimeline)
        self.currentTimeline = nextTimeline
        return nextTimeline
    }

    @discardableResult
    func record(contentsOf events: [MissionEvent]) -> MissionTimeline? {
        guard !events.isEmpty else {
            return currentTimeline
        }

        var lastTimeline = currentTimeline
        for event in events {
            if let next = record(event) {
                lastTimeline = next
            }
        }
        return lastTimeline
    }

    @discardableResult
    func finishSession(
        outcome: MissionOutcome,
        endedAt: Date = Date()
    ) -> MissionTimeline? {
        guard let currentTimeline else {
            return nil
        }
        let nextTimeline = builder.finalize(
            timeline: currentTimeline,
            outcome: outcome,
            endedAt: endedAt
        )
        self.currentTimeline = nextTimeline
        return nextTimeline
    }

    func restore(timeline: MissionTimeline?) {
        currentTimeline = timeline
    }

    func reset() {
        currentTimeline = nil
    }
}
