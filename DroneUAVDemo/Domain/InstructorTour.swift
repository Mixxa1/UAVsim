import Foundation

enum InstructorTourStep: String, CaseIterable {
    case welcome, projects, create, missions, workbench, replay, online, settings, ready

    var titleKey: String { "instructor.tour.\(rawValue).title" }
    var detailKey: String { "instructor.tour.\(rawValue).detail" }
    var target: String? {
        switch self {
        case .welcome, .ready: return nil
        default: return "app.\(rawValue)"
        }
    }
}
