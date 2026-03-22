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
                    .font(.system(size: 13, weight: .semibold))

                VStack(alignment: .leading, spacing: 1) {
                    Text("payload.configure")
                        .font(.caption.weight(.semibold))
                    Text(payloadState.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Circle()
                    .fill(mountTint)
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPresented ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isPresented ? Color.accentColor.opacity(0.70) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(String(localized: isPresented ? "payload.toolbar.close" : "payload.toolbar.open"))
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
