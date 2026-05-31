import Foundation

enum CADCutPreviewStatus: String, Equatable {
    case notReady
    case ready
    case invalid

    var displayNameKey: String {
        switch self {
        case .notReady: return "cad.cut_v1.preview.not_ready"
        case .ready:    return "cad.cut_v1.preview.ready"
        case .invalid:  return "cad.cut_v1.preview.invalid"
        }
    }
}

enum CADCutApplyStatus: String, Equatable {
    case supported
    case blocked
    case committed

    var displayNameKey: String {
        switch self {
        case .supported: return "cad.cut_v1.apply.supported"
        case .blocked:   return "cad.cut_v1.apply.blocked"
        case .committed: return "cad.cut_v1.apply.committed"
        }
    }
}

struct CADCutValidationReport: Equatable {
    var validation: CADFeatureValidation
    var previewStatus: CADCutPreviewStatus
    var applyStatus: CADCutApplyStatus

    static let notReady = CADCutValidationReport(
        validation: .noSelectedProfileArea,
        previewStatus: .notReady,
        applyStatus: .blocked
    )

    static func invalid(_ validation: CADFeatureValidation) -> CADCutValidationReport {
        CADCutValidationReport(
            validation: validation,
            previewStatus: .invalid,
            applyStatus: .blocked
        )
    }

    static func ready() -> CADCutValidationReport {
        CADCutValidationReport(
            validation: .valid,
            previewStatus: .ready,
            applyStatus: .supported
        )
    }
}
