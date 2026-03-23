import SwiftUI

enum GroundControlPalette {
    static let shell = Color(red: 0.08, green: 0.10, blue: 0.12)
    static let panel = Color(red: 0.11, green: 0.13, blue: 0.16)
    static let panelRaised = Color(red: 0.14, green: 0.17, blue: 0.20)
    static let inset = Color(red: 0.07, green: 0.09, blue: 0.11)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.18)
    static let accent = Color(red: 0.23, green: 0.59, blue: 0.94)
    static let success = Color(red: 0.29, green: 0.75, blue: 0.41)
    static let warning = Color(red: 0.93, green: 0.63, blue: 0.24)
    static let danger = Color(red: 0.86, green: 0.29, blue: 0.22)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.66)
}

struct SidebarModuleHostView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @Binding var appLanguage: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.activeControlModule != .diagnostics {
                SidebarOperationalHeaderView(viewModel: viewModel)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            activeModuleContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GroundControlPalette.shell)
    }

    @ViewBuilder
    private var activeModuleContent: some View {
        switch viewModel.activeControlModule {
        case .flightOps?:
            ScrollableModuleSectionView {
                FlightOpsModuleView(viewModel: viewModel)
            }
        case .uavCatalog?:
            ScrollableModuleSectionView {
                UAVCatalogModuleView(viewModel: viewModel)
            }
        case .camera?:
            ScrollableModuleSectionView {
                CameraModuleView(viewModel: viewModel)
            }
        case .scenario?:
            ScrollableModuleSectionView {
                ScenarioModuleView(viewModel: viewModel)
            }
        case .diagnostics?:
            DiagnosticsModuleView(viewModel: viewModel, appLanguage: $appLanguage)
        case nil:
            EmptyView()
        }
    }
}

private struct SidebarOperationalHeaderView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(viewModel.activeControlModule?.titleKey ?? "module.panel.idle"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text(LocalizedStringKey(viewModel.activeControlModule?.subtitleKey ?? "module.panel.idle.subtitle"))
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                StatusBadge(
                    titleKey: viewModel.telemetry.armStateKey,
                    tint: viewModel.isArmed ? GroundControlPalette.success : GroundControlPalette.warning
                )
            }

            moduleSummary

            if let warningKey = viewModel.warnings.first {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GroundControlPalette.warning)
                    Text(LocalizedStringKey(warningKey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(GroundControlPalette.warning.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(GroundControlPalette.warning.opacity(0.32), lineWidth: 1)
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(GroundControlPalette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var moduleSummary: some View {
        switch viewModel.activeControlModule {
        case .flightOps?:
            ModuleMetricGrid {
                ModuleMetricCell(
                    labelKey: "sidebar.metric.mode",
                    value: localized(viewModel.telemetry.modeKey)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.state",
                    value: localized(viewModel.telemetry.flightStateKey)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.throttle",
                    value: String(format: "%.0f %%", viewModel.controlValues.throttle * 100.0)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.battery",
                    value: String(format: "%.0f %%", viewModel.telemetry.batteryPercent)
                )
            }
        case .camera?:
            ModuleMetricGrid {
                ModuleMetricCell(
                    labelKey: "sidebar.metric.camera",
                    value: localized(viewModel.cameraConfiguration.mode.titleKey)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.preset",
                    value: localized(viewModel.selectedCameraPreset.titleKey)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.fov",
                    value: String(format: "%.0f°", Double(viewModel.cameraConfiguration.fov))
                )
                ModuleMetricCell(
                    labelKey: viewModel.supportsDistanceControl ? "sidebar.metric.distance" : "sidebar.metric.battery",
                    value: viewModel.supportsDistanceControl
                        ? String(format: "%.1f m", viewModel.activeCameraDistance)
                        : String(format: "%.0f %%", viewModel.telemetry.batteryPercent)
                )
            }
        case .scenario?:
            ModuleMetricGrid {
                ModuleMetricCell(
                    labelKey: "sidebar.metric.weather",
                    value: localized(viewModel.weather.preset.titleKey)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.terrain",
                    value: localized(viewModel.terrain.preset.titleKey)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.wind",
                    value: String(format: "%.1f m/s", viewModel.weather.windSpeedMps)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.boundary",
                    value: localized(viewModel.isBoundaryBarrierVisible ? "sidebar.value.on" : "sidebar.value.off")
                )
            }
        case .uavCatalog?:
            ModuleMetricGrid {
                ModuleMetricCell(
                    labelKey: "sidebar.metric.platform",
                    value: viewModel.selectedDroneProfile.uiDisplayName
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.manufacturer",
                    value: viewModel.selectedDroneProfile.manufacturer
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.battery",
                    value: String(format: "%.0f %%", viewModel.telemetry.batteryPercent)
                )
                ModuleMetricCell(
                    labelKey: "sidebar.metric.warnings",
                    value: String(viewModel.warnings.count)
                )
            }
        case .diagnostics?, nil:
            EmptyView()
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

struct ModuleSection<Content: View>: View {
    let titleKey: String
    var subtitleKey: String? = nil
    @ViewBuilder let content: Content

    init(
        titleKey: String,
        subtitleKey: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(titleKey))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let subtitleKey {
                    Text(LocalizedStringKey(subtitleKey))
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            content
        }
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GroundControlPalette.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }
}

struct ScrollableModuleSectionView<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ModuleMetricGrid<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            content
        }
    }
}

struct ModuleMetricCell: View {
    let labelKey: String
    let value: String
    var tint: Color = GroundControlPalette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(labelKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(GroundControlPalette.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }
}

struct StatusBadge: View {
    let titleKey: String
    let tint: Color

    var body: some View {
        Text(LocalizedStringKey(titleKey))
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
    }
}

struct ModuleSliderRow: View {
    let titleKey: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let formatter: NumberFormatter
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onCommit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(titleKey))
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                TextField("", value: value, formatter: formatter)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .onSubmit {
                        onCommit?()
                    }
            }

            Slider(value: value, in: range, step: step) { editing in
                onEditingChanged?(editing)
                if !editing {
                    onCommit?()
                }
            }
            .tint(GroundControlPalette.accent)
        }
    }
}

struct ModuleModeTile: View {
    let titleKey: String
    let subtitle: String?
    let iconSystemName: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: iconSystemName)
                    .font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(titleKey))
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? GroundControlPalette.accent.opacity(0.22) : GroundControlPalette.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? GroundControlPalette.accent.opacity(0.65) : GroundControlPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct OperationalActionButton: View {
    let titleKey: String
    let systemImage: String
    var tint: Color = GroundControlPalette.accent
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                Text(LocalizedStringKey(titleKey))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(prominent ? tint.opacity(0.22) : GroundControlPalette.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(prominent ? tint.opacity(0.58) : GroundControlPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? GroundControlPalette.textPrimary : tint)
    }
}
