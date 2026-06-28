import AppKit
import SwiftUI

/// Native AppKit slider — deliberately not SwiftUI's `Slider`. Gimbal aiming needs direct,
/// continuous drag-to-exact-angle control; an `NSSlider` dispatches its action straight to the
/// target without going through a SwiftUI view-diff every tick, and reads as the same kind of
/// physical control a real ground-station gimbal joystick/slider would be.
struct NativeAxisSlider: NSViewRepresentable {
    let minValue: Double
    let maxValue: Double
    @Binding var value: Double
    var isVertical: Bool = false

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isVertical = isVertical
        slider.controlSize = .small
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.value = $value
        nsView.minValue = minValue
        nsView.maxValue = maxValue
        nsView.isVertical = isVertical
        if abs(nsView.doubleValue - value) > 0.05 {
            nsView.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

/// Payload-camera gimbal aiming controls, overlaid on the viewport while the payload optics
/// camera is active. Each slider reports its *delta* from the last value through
/// `adjustPayloadGimbal`, mirroring how the existing rangefinder gimbal sliders in
/// `CameraModuleView` drive `adjustRangefinderGimbal` — but placed directly over the live feed so
/// aiming doesn't require leaving the viewport to open the Camera module.
struct PayloadGimbalSliderControls: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    private var isEnabled: Bool { viewModel.payloadCameraOpticsState.isAvailable }

    private var yawBinding: Binding<Double> {
        Binding(
            get: { viewModel.payloadCameraOpticsState.gimbalYawDegrees },
            set: { newValue in
                let current = viewModel.payloadCameraOpticsState.gimbalYawDegrees
                viewModel.adjustPayloadGimbal(yawDeltaDegrees: newValue - current, pitchDeltaDegrees: 0.0)
            }
        )
    }

    private var pitchBinding: Binding<Double> {
        Binding(
            get: { viewModel.payloadCameraOpticsState.gimbalPitchDegrees },
            set: { newValue in
                let current = viewModel.payloadCameraOpticsState.gimbalPitchDegrees
                viewModel.adjustPayloadGimbal(yawDeltaDegrees: 0.0, pitchDeltaDegrees: newValue - current)
            }
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(spacing: 6) {
                Text("payload.gimbal.pitch_short")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                NativeAxisSlider(minValue: -90, maxValue: 35, value: pitchBinding, isVertical: true)
                    .frame(width: 22, height: 120)
                Text(String(format: "%.0f°", viewModel.payloadCameraOpticsState.gimbalPitchDegrees))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(GroundControlPalette.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("payload.gimbal.yaw_short")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                NativeAxisSlider(minValue: -180, maxValue: 180, value: yawBinding)
                    .frame(width: 170, height: 22)
                Text(String(format: "%.0f°", viewModel.payloadCameraOpticsState.gimbalYawDegrees))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(GroundControlPalette.textPrimary)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .opacity(isEnabled ? 1.0 : 0.4)
        .allowsHitTesting(isEnabled)
    }
}
