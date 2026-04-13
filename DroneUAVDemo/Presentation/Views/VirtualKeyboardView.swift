import SwiftUI

struct VirtualKeyboardView: View {
    @ObservedObject var bridge: ControllerUIBridge

    var body: some View {
        if let session = bridge.textInputSession {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.96))

                    Text(session.text.isEmpty ? session.placeholder : session.text)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .foregroundStyle(session.text.isEmpty ? Color.white.opacity(0.46) : Color.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.28))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(ControllerKeyboardKey.defaultRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            ForEach(row) { key in
                                KeyboardKeyCell(
                                    key: key,
                                    isSelected: session.selectedKeyID == key.id
                                )
                            }
                        }
                    }
                }

                Text("A Select  •  B Cancel  •  Stick / D-Pad Move")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            .padding(18)
            .frame(maxWidth: 860)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.84))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.32), radius: 20, y: 10)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .zIndex(20)
            .allowsHitTesting(false)
        }
    }

}

private struct KeyboardKeyCell: View {
    let key: ControllerKeyboardKey
    let isSelected: Bool

    private var isWide: Bool {
        switch key.kind {
        case .character:
            return false
        case .space, .backspace, .confirm, .cancel:
            return true
        }
    }

    private var foregroundColor: Color {
        isSelected ? Color.black.opacity(0.92) : Color.white.opacity(0.88)
    }

    private var fillColor: Color {
        isSelected ? Color.cyan.opacity(0.95) : Color.white.opacity(0.08)
    }

    private var strokeColor: Color {
        isSelected ? Color.cyan.opacity(0.98) : Color.white.opacity(0.08)
    }

    var body: some View {
        Text(key.title)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, isWide ? 14 : 12)
            .frame(maxWidth: isWide ? .infinity : nil)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }
}
