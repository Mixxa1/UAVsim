import SwiftUI

struct SceneViewportView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            DroneSceneViewRepresentable(
                scene: viewModel.scene,
                pointOfView: viewModel.activeCameraNode,
                cameraMode: viewModel.cameraConfiguration.mode,
                cameraSensitivity: viewModel.cameraConfiguration.sensitivity,
                freeMoveSpeed: viewModel.cameraConfiguration.free.moveSpeed,
                onLookDelta: { dx, dy in
                    viewModel.handlePointerLook(deltaX: dx, deltaY: dy)
                }
            )
            .ignoresSafeArea()

            if !viewModel.isParametersPanelVisible || viewModel.isCompactTelemetryHUDEnabled {
                CompactTelemetryHUDView(
                    telemetry: viewModel.telemetry,
                    warningKeys: viewModel.warnings
                )
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("hud.title")
                        .font(.caption.weight(.semibold))
                    Text("\(localized("hud.camera")): \(localized(viewModel.cameraConfiguration.mode.titleKey)) | \(localized("hud.drone")): \(localized(viewModel.selectedDroneProfile.displayNameKey))")
                        .font(.caption2)
                    if let warningKey = viewModel.warnings.first {
                        Text(LocalizedStringKey(warningKey))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    }
                }
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
        }
        .background(Color.black)
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
