import SwiftUI

struct ControllerCursorOverlay: View {
    let state: ControllerCursorState
    let activeTargetFrame: CGRect?

    var body: some View {
        GeometryReader { _ in
            if state.isVisible {
                ZStack(alignment: .topLeading) {
                    if let activeTargetFrame {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.cyan.opacity(0.92), lineWidth: 2)
                            .frame(
                                width: activeTargetFrame.width + 8,
                                height: activeTargetFrame.height + 8
                            )
                            .position(x: activeTargetFrame.midX, y: activeTargetFrame.midY)
                            .shadow(color: Color.cyan.opacity(0.18), radius: 10)
                    }

                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: 14, height: 14)
                            .shadow(color: Color.black.opacity(0.28), radius: 6, y: 2)

                        Circle()
                            .stroke(Color.black.opacity(0.88), lineWidth: 1.5)
                            .frame(width: 14, height: 14)

                        Circle()
                            .fill(Color.black.opacity(0.86))
                            .frame(width: 4, height: 4)
                    }
                    .position(x: state.position.x, y: state.position.y)
                }
                .allowsHitTesting(false)
            }
        }
    }
}
