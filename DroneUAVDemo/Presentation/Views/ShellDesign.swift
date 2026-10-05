import SwiftUI

struct ShellSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(GroundControlPalette.textPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShellEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(GroundControlPalette.accent)
                .frame(width: 66, height: 66)
                .background(GroundControlPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct ShellStepButton: View {
    let number: Int
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(isSelected ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : GroundControlPalette.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if isSelected {
                    GroundControlPalette.accent.opacity(0.85).frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
