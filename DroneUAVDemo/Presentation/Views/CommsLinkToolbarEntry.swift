import SwiftUI

/// Sibling toolbar entry to `PayloadToolbarEntry` — the fiber-optic control link is a separate
/// equipment slot from mission payload (see `UAVControlLinkType`), so it gets its own toolbar
/// button and overlay rather than living inside the payload editor.
struct CommsLinkToolbarEntry: View {
    let isPresented: Bool
    let isAttached: Bool
    let linkStatus: FiberLinkStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 16)

                Text("module.comms_link.toolbar_title")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Spacer(minLength: 4)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(statusTint)
                    .frame(width: 10, height: 10)
            }
            .padding(.horizontal, 10)
            .foregroundStyle(GroundControlPalette.textPrimary)
            .frame(width: 142, height: 46, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isPresented ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isPresented ? GroundControlPalette.accent.opacity(0.62) : GroundControlPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(String(localized: isPresented ? "comms_link.toolbar.close" : "comms_link.toolbar.open"))
        .controllerButtonTarget(id: "toolbar.comms_link", action: action)
    }

    private var statusTint: Color {
        guard isAttached else {
            return .gray
        }
        switch linkStatus {
        case .connected:
            return .blue
        case .degraded:
            return .orange
        case .broken:
            return .red
        }
    }
}
