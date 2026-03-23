import Foundation

enum ControlModule: String, CaseIterable, Identifiable {
    case flightOps
    case uavCatalog
    case camera
    case scenario
    case diagnostics

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .flightOps:
            return "module.flight_ops.title"
        case .uavCatalog:
            return "module.uav_catalog.title"
        case .camera:
            return "module.camera.title"
        case .scenario:
            return "module.scenario.title"
        case .diagnostics:
            return "module.diagnostics.title"
        }
    }

    var toolbarTitleKey: String {
        switch self {
        case .flightOps:
            return "module.flight_ops.toolbar_title"
        case .uavCatalog:
            return "module.uav_catalog.toolbar_title"
        case .camera:
            return "module.camera.toolbar_title"
        case .scenario:
            return "module.scenario.toolbar_title"
        case .diagnostics:
            return "module.diagnostics.toolbar_title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .flightOps:
            return "module.flight_ops.subtitle"
        case .uavCatalog:
            return "module.uav_catalog.subtitle"
        case .camera:
            return "module.camera.subtitle"
        case .scenario:
            return "module.scenario.subtitle"
        case .diagnostics:
            return "module.diagnostics.subtitle"
        }
    }

    var iconSystemName: String {
        switch self {
        case .flightOps:
            return "dot.scope"
        case .uavCatalog:
            return "airplane"
        case .camera:
            return "video"
        case .scenario:
            return "wind"
        case .diagnostics:
            return "waveform.path.ecg.rectangle"
        }
    }
}
