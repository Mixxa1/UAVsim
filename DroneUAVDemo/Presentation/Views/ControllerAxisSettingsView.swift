import SwiftUI

/// Where the operator decides what the gamepad does.
///
/// Laid out the way a flight controller's configurator lays it out — one card per idea, rates
/// beside the curve they draw — because that is the shape the people flying this already have in
/// their heads. Backed only by `ControllerSettingsStore`, so it works from the settings screen
/// where no simulation exists.
struct ControllerAxisSettingsView: View {
    @ObservedObject var store: ControllerSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            layoutCard
            ratesCard
            throttleCard
            axesCard
        }
    }

    // MARK: - Layout

    private var layoutCard: some View {
        card(title: "controls.section.layout") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach([ControllerStickMode.mode1, .mode2, .mode3, .mode4]) { mode in
                        stickModeButton(mode)
                    }
                }
                Text(stickModeSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.axisMap.conflictingFlightAxes {
                    Label("controls.conflict", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var stickModeSummary: String {
        switch store.axisMap.stickMode {
        case .mode1: return NSLocalizedString("controls.mode1.summary", comment: "")
        case .mode2: return NSLocalizedString("controls.mode2.summary", comment: "")
        case .mode3: return NSLocalizedString("controls.mode3.summary", comment: "")
        case .mode4: return NSLocalizedString("controls.mode4.summary", comment: "")
        case .custom: return NSLocalizedString("controls.mode.custom.summary", comment: "")
        }
    }

    private func stickModeButton(_ mode: ControllerStickMode) -> some View {
        let isActive = store.axisMap.stickMode == mode
        return Button {
            store.applyStickMode(mode)
        } label: {
            Text(mode.rawValue.replacingOccurrences(of: "mode", with: "Mode "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .white : .white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? GroundControlPalette.accent.opacity(0.35) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isActive ? GroundControlPalette.accent : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rates

    /// One row per rotational axis, with the three curves drawn together on the right. Seeing roll,
    /// pitch and yaw on the same plot is the point: what matters is how they differ.
    private var ratesCard: some View {
        card(title: "controls.section.rates", trailing: {
            HStack(spacing: 6) {
                presetButton("controls.rates.calm") { store.applyRateProfile(.calm) }
                presetButton("controls.rates.standard") { store.applyRateProfile(.default) }
                presetButton("controls.rates.sharp") { store.applyRateProfile(.sharp) }
            }
        }) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    rateHeaderRow
                    rateRow(.roll, titleKey: "controls.axis.roll", tint: GroundControlPalette.danger)
                    rateRow(.pitch, titleKey: "controls.axis.pitch", tint: GroundControlPalette.success)
                    rateRow(.yaw, titleKey: "controls.axis.yaw", tint: GroundControlPalette.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    RateCurvePlot(curves: [
                        (store.rateProfile.roll, GroundControlPalette.danger),
                        (store.rateProfile.pitch, GroundControlPalette.success),
                        (store.rateProfile.yaw, GroundControlPalette.accent)
                    ])
                    .frame(width: 190, height: 130)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    Text("controls.rates.plot_caption")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 190)
                }
            }

            Text("controls.rates.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rateHeaderRow: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 62, alignment: .leading)
            columnTitle("controls.rates.sensitivity")
            columnTitle("controls.rates.super")
            columnTitle("controls.rates.expo")
            Text("controls.rates.half_stick")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
    }

    private func columnTitle(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rateRow(_ function: ControllerAxisFunction, titleKey: String, tint: Color) -> some View {
        let rates = store.rateProfile.rates(for: function) ?? ControllerAxisRates()
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 8, height: 8)
                Text(LocalizedStringKey(titleKey))
                    .font(.caption.weight(.medium))
            }
            .frame(width: 62, alignment: .leading)

            rateField(rates.sensitivity, range: 0.1...1) { value in
                var updated = rates
                updated.sensitivity = value
                store.setRates(updated, for: function)
            }
            rateField(rates.superRate, range: 0...1) { value in
                var updated = rates
                updated.superRate = value
                store.setRates(updated, for: function)
            }
            rateField(rates.expo, range: 0...1) { value in
                var updated = rates
                updated.expo = value
                store.setRates(updated, for: function)
            }

            // What the curve is actually doing, in the one place a pilot would look for it.
            Text(String(format: "%.0f%%", rates.halfStickShare * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 74, alignment: .trailing)
        }
    }

    private func rateField(
        _ value: Double,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.2f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            Slider(value: Binding(get: { value }, set: onChange), in: range)
        }
        .frame(maxWidth: .infinity)
    }

    private func presetButton(_ titleKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Throttle

    private var throttleCard: some View {
        let curve = store.rateProfile.throttle
        return card(title: "controls.section.throttle") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: Binding(
                        get: { store.axisMap.throttleMode },
                        set: { store.setThrottleMode($0) }
                    )) {
                        Text("controls.throttle.absolute").tag(ControllerThrottleMode.absolute)
                        Text("controls.throttle.rate").tag(ControllerThrottleMode.rate)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    labelledSlider("controls.throttle.mid", value: curve.mid, range: 0.1...0.9) { value in
                        var updated = curve
                        updated.mid = value
                        store.setThrottleCurve(updated)
                    }
                    labelledSlider("controls.throttle.expo", value: curve.expo, range: 0...1) { value in
                        var updated = curve
                        updated.expo = value
                        store.setThrottleCurve(updated)
                    }
                    labelledSlider("controls.throttle.idle", value: curve.idle, range: 0...0.2) { value in
                        var updated = curve
                        updated.idle = value
                        store.setThrottleCurve(updated)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ThrottleCurvePlot(curve: curve)
                    .frame(width: 190, height: 130)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("controls.throttle.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labelledSlider(
        _ titleKey: String,
        value: Double,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
            Text(String(format: "%.2f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: - Axes

    private var axesCard: some View {
        card(title: "controls.section.axes", trailing: {
            Button("controls.reset") { store.resetAxisMap() }
                .buttonStyle(.link)
                .font(.caption)
        }) {
            ForEach(ControllerAxisFunction.allCases) { function in
                axisRow(function)
            }
        }
    }

    /// One function: where it comes from, which way round it goes, and how much slop its stick has.
    private func axisRow(_ function: ControllerAxisFunction) -> some View {
        let binding = store.axisMap.binding(for: function)
        return HStack(spacing: 8) {
            Text(LocalizedStringKey(axisFunctionTitleKey(function)))
                .font(.caption.weight(.medium))
                .frame(width: 122, alignment: .leading)

            Picker("", selection: Binding(
                get: { binding.source },
                set: { source in
                    var updated = binding
                    updated.source = source
                    store.setAxisBinding(updated, for: function)
                }
            )) {
                ForEach(ControllerAxisSource.allCases) { source in
                    Text(LocalizedStringKey(axisSourceTitleKey(source))).tag(source)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 172)

            Toggle("controls.axis.invert", isOn: Binding(
                get: { binding.isInverted },
                set: { value in
                    var updated = binding
                    updated.isInverted = value
                    store.setAxisBinding(updated, for: function)
                }
            ))
            .font(.caption2)
            .toggleStyle(.checkbox)
            .disabled(binding.source == .none)

            if binding.source != .none {
                HStack(spacing: 6) {
                    Text("controls.axis.deadzone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { binding.deadzone },
                            set: { value in
                                var updated = binding
                                updated.deadzone = value
                                store.setAxisBinding(updated, for: function)
                            }
                        ),
                        in: 0...0.4
                    )
                    .frame(width: 84)
                    Text(String(format: "%.2f", binding.deadzone))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Chrome

    private func card<Content: View, Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                trailing()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func axisFunctionTitleKey(_ function: ControllerAxisFunction) -> String {
        "controls.function.\(function.rawValue)"
    }

    private func axisSourceTitleKey(_ source: ControllerAxisSource) -> String {
        "controls.source.\(source.rawValue)"
    }
}

// MARK: - Plots

/// Stick position against commanded rate, for all three axes at once.
private struct RateCurvePlot: View {
    let curves: [(rates: ControllerAxisRates, tint: Color)]

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: midY))
            axes.addLine(to: CGPoint(x: size.width, y: midY))
            axes.move(to: CGPoint(x: size.width / 2, y: 0))
            axes.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(axes, with: .color(.white.opacity(0.18)), lineWidth: 1)

            for curve in curves {
                var path = Path()
                for step in 0...80 {
                    let input = Double(step) / 40 - 1
                    let output = curve.rates.command(input)
                    let point = CGPoint(
                        x: size.width * (input + 1) / 2,
                        y: midY - midY * output
                    )
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(curve.tint), lineWidth: 1.6)
            }
        }
    }
}

/// Stick position against commanded throttle. Unlike the rate axes it has no centre, so the plot
/// runs bottom-left to top-right and the idle floor is visible as a lifted start.
private struct ThrottleCurvePlot: View {
    let curve: ControllerThrottleCurve

    var body: some View {
        Canvas { context, size in
            var frame = Path()
            frame.move(to: CGPoint(x: 0, y: size.height))
            frame.addLine(to: CGPoint(x: size.width, y: size.height))
            frame.move(to: CGPoint(x: 0, y: 0))
            frame.addLine(to: CGPoint(x: 0, y: size.height))
            context.stroke(frame, with: .color(.white.opacity(0.18)), lineWidth: 1)

            var path = Path()
            for step in 0...80 {
                let input = Double(step) / 80
                let point = CGPoint(
                    x: size.width * input,
                    y: size.height * (1 - curve.shaped(input))
                )
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(GroundControlPalette.accent), lineWidth: 1.6)
        }
    }
}
