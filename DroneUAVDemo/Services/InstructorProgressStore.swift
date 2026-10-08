import Foundation

enum InstructorProgressStore {
    static let appTourSeenKey = "instructor.appTourSeen.v1"
    static let flightCourseCompletedKey = "instructor.flightCourseCompleted.v1"

    static func markFlightCourseCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: flightCourseCompletedKey)
    }
}
