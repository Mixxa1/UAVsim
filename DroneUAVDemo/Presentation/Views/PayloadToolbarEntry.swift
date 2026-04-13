import SwiftUI

struct PayloadToolbarEntry: View {
    let isPresented: Bool
    let payloadState: PayloadState
    let payloadMountState: PayloadMountState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 16)

                Text("module.payload.toolbar_title")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Spacer(minLength: 4)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(mountTint)
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
        .help(String(localized: isPresented ? "payload.toolbar.close" : "payload.toolbar.open"))
        .controllerButtonTarget(id: "toolbar.payload", action: action)
    }

    private var mountTint: Color {
        switch payloadMountState {
        case .unavailable:
            return .red
        case .ready:
            return .blue
        case .occupied:
            return .orange
        }
    }
}
