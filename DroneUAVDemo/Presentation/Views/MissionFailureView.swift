import SwiftUI

struct MissionFailureView: View {
    let detailKey: String
    let severity: MissionWarningSeverity

    init(detailKey: String, severity: MissionWarningSeverity) {
        self.detailKey = detailKey
        self.severity = severity
    }

    init(explanation: MissionStatusExplanation) {
        self.detailKey = explanation.detailKey
        self.severity = {
            switch explanation.severity {
            case .info:
                return .info
            case .warning:
                return .warning
            case .critical:
                return .critical
            }
        }()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(LocalizedStringKey(detailKey))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var indicatorColor: Color {
        switch severity {
        case .info:
            return GroundControlPalette.accent
        case .warning:
            return GroundControlPalette.warning
        case .critical:
            return GroundControlPalette.danger
        }
    }
}
