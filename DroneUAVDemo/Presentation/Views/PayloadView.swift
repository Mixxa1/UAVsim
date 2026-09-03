import SwiftUI

/// Shared by `PayloadView`, which became generic over its stations slot and so can no longer
/// hold a static stored property of its own.
private let payloadMassFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter
}()

struct PayloadView<StationsContent: View>: View {
    let configuration: PayloadConfiguration
    let payloadState: PayloadState
    let payloadMountState: PayloadMountState
    let capabilityCheck: PayloadCapabilityCheck
    let massModel: VehicleMassModel
    let statusMessageKey: String?
    let activeUAVProfile: UAVProfile?
    let mountedCADPayload: MountedCADPayload?

    let onTypeChange: (PayloadType) -> Void
    let onMassChange: (Double) -> Void
    let onHoseRiggingChange: (FireHoseDiameterClass, Double) -> Void
    let onCapsuleRiggingChange: (FireCapsuleSize, Int) -> Void
    let onCustomNameChange: (String) -> Void
    let onAttach: () -> Void
    let onRelease: () -> Void
    let onRemove: () -> Void
    let onClose: (() -> Void)?
    /// The station list, injected rather than built here: it needs the view model, and this panel
    /// deliberately takes plain values. Rendering it inside the same shell is what keeps it from
    /// reading as a separate, unrelated card floating under the payload window.
    @ViewBuilder var stationsContent: () -> StationsContent

    @FocusState private var isMassFieldFocused: Bool
    @FocusState private var isCustomNameFieldFocused: Bool

    private let tileColumns = Array(
        repeating: GridItem(.flexible(minimum: 124), spacing: 10),
        count: 4
    )

    private var payloadDataResolution: PayloadDataResolution? {
        activeUAVProfile?.payloadDataResolution
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBlock

            HStack(alignment: .top, spacing: 14) {
                selectedPayloadConsole
                    .frame(width: 300)

                catalogConsole
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            configurationConsole
            limitsConsole
            stationsContent()
            actionConsole
        }
        .padding(16)
        .background(shellBackground)
        .overlay(shellStroke)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.30), radius: 24, x: 0, y: 18)
    }

    private var headerBlock: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.cyan.opacity(0.92))
                        .frame(width: 3, height: 20)
                    Rectangle()
                        .fill(Color.cyan.opacity(0.55))
                        .frame(width: 8, height: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("payload.section")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(Color(red: 0.74, green: 0.87, blue: 1.0))
                            .lineLimit(1)
                            .minimumScaleFactor(0.84)
                        Text("payload.catalog.subtitle")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.44))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("payload.active_uav")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.38))
                    Text(activeUAVProfile?.localizedDisplayName ?? String(localized: "common.not_specified"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "payload.toolbar.close"))
                    .controllerButtonTarget(id: "payload.close", action: onClose)
                }
            }

            HStack(spacing: 7) {
                Text("payload.status")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.34))
                consoleBadge(title: payloadState.title, tint: statusTint)
                consoleBadge(title: payloadMountState.title, tint: mountTint)
                if let payloadDataResolution {
                    consoleBadge(
                        title: payloadDataResolution.sourceQuality.title,
                        tint: payloadDataTint(for: payloadDataResolution.sourceQuality)
                    )
                }

                Spacer(minLength: 12)

                Text("payload.console.subtitle")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(chromePanel(accent: Color.cyan.opacity(0.55)))
    }

    private var selectedPayloadConsole: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.105, green: 0.115, blue: 0.12),
                                Color(red: 0.065, green: 0.070, blue: 0.075)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                PayloadLivePreviewView(
                    configuration: configuration,
                    isSpinning: true,
                    allowsCameraControl: true
                )
                .frame(height: 226)

                HStack(spacing: 6) {
                    Image(systemName: "cube.transparent")
                    Text("payload.preview.live")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.black.opacity(0.34), in: Capsule(style: .continuous))
                .padding(10)

                Text("payload.preview.drag")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.28), in: Capsule(style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(10)
            }
            .frame(height: 226)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(configuration.resolvedName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white.opacity(0.96))
                            .lineLimit(2)
                        Text(LocalizedStringKey(payloadDescriptionKey(for: configuration.payloadType)))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 6)

                    compatibilityBadge(for: capabilityCheck, compact: true)
                }

                HStack(spacing: 8) {
                    compactMetric(title: "payload.mass", value: massText(configuration.payloadMass))
                    compactMetric(title: "payload.total_mass", value: projectedTotalMassText)
                }

                massBudgetSummary

                if let messageKey = effectiveMessageKey {
                    statusMessage(messageKey)
                }

                if let mountedCADPayload {
                    cadPayloadStatusBlock(mountedCADPayload)
                }
            }
            .padding(.top, 13)
        }
        .padding(12)
        .frame(minHeight: 522, alignment: .top)
        .background(chromePanel(accent: typeAccent(for: configuration.payloadType).opacity(0.62)))
    }

    private var catalogConsole: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    sectionHeader(titleKey: "payload.catalog.title")
                    Text(String(format: String(localized: "payload.catalog.count_format"), PayloadType.allCases.count))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                HStack(spacing: 12) {
                    catalogLegend(title: "payload.compatible", tint: compatibleTint)
                    catalogLegend(title: "payload.incompatible", tint: incompatibleTint)
                }
            }

            LazyVGrid(columns: tileColumns, spacing: 10) {
                ForEach(PayloadType.allCases) { type in
                    payloadCatalogCard(type)
                }
            }
        }
        .padding(12)
        .frame(minHeight: 522, alignment: .top)
        .background(chromePanel(accent: Color.cyan.opacity(0.34)))
    }

    private func payloadCatalogCard(_ type: PayloadType) -> some View {
        let isSelected = type == configuration.payloadType
        let cardConfiguration = catalogConfiguration(for: type)
        let check = catalogCapability(for: cardConfiguration)
        let tint = typeAccent(for: type)

        return Button {
            onTypeChange(type)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    PayloadLivePreviewView(configuration: cardConfiguration)
                        .frame(maxWidth: .infinity)
                        .frame(height: 84)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : compatibilitySymbol(for: check))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isSelected ? tint : compatibilityTint(for: check))
                        .padding(7)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )

                Text(type.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.80))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)

                HStack(spacing: 5) {
                    Text(massText(cardConfiguration.payloadMass))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white.opacity(0.52))
                    Spacer(minLength: 2)
                    Circle()
                        .fill(compatibilityTint(for: check))
                        .frame(width: 6, height: 6)
                    Text(check.isAllowed ? "payload.compatible" : "payload.incompatible")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(compatibilityTint(for: check).opacity(0.92))
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 152, alignment: .top)
            .background(catalogCardBackground(isSelected: isSelected, tint: tint))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(catalogHelpText(for: type, check: check))
        .controllerButtonTarget(id: "payload.type.\(type.id)") {
            onTypeChange(type)
        }
    }

    private var configurationConsole: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(titleKey: "payload.configuration.title")
                Spacer()
                Text(configuration.resolvedName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(typeAccent(for: configuration.payloadType).opacity(0.94))
            }

            HStack(alignment: .center, spacing: 14) {
                massEditor
                    .frame(width: 330)

                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 1, height: 74)

                selectedConfigurationEditor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(chromePanel(accent: typeAccent(for: configuration.payloadType).opacity(0.44)))
    }

    private var isMassEditable: Bool {
        configuration.payloadType != .fireHose && configuration.payloadType != .fireCapsuleLauncher
    }

    private var massEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("payload.mass")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.48))

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "payload.mass"),
                        value: Binding(
                            get: { Double(configuration.payloadMass) },
                            set: onMassChange
                        ),
                        formatter: payloadMassFormatter
                    )
                    .focused($isMassFieldFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .disabled(!isMassEditable)
                    .controllerTextInputTarget(
                        id: "payload.mass.input",
                        title: String(localized: "payload.mass"),
                        currentText: {
                            payloadMassFormatter.string(from: NSNumber(value: configuration.payloadMass)) ?? ""
                        },
                        onCommit: { text in
                            guard let parsed = payloadMassFormatter.controllerDouble(from: text) else { return }
                            onMassChange(parsed)
                        }
                    )

                    Text("kg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(valueFieldBackground(isFocused: isMassFieldFocused))

                if isMassEditable {
                    adjustMassButton(symbol: "minus") { adjustMass(by: -0.25) }
                    adjustMassButton(symbol: "plus") { adjustMass(by: 0.25) }
                }
            }

            if !isMassEditable {
                Text(configuration.payloadType == .fireHose ? "payload.hose.mass_follows_rig" : "payload.capsule.mass_follows_rig")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.44))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var selectedConfigurationEditor: some View {
        switch configuration.payloadType {
        case .fireHose:
            hoseRiggingEditor
        case .fireCapsuleLauncher:
            capsuleRiggingEditor
        case .custom:
            customNameEditor
        default:
            standardConfigurationSummary
        }
    }

    private var hoseRiggingEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("payload.hose.title")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer()
                Text(String(format: "%.0f m", configuration.fireHoseLengthMeters))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            Picker("", selection: Binding(
                get: { configuration.fireHoseDiameterClass },
                set: { onHoseRiggingChange($0, Double(configuration.fireHoseLengthMeters)) }
            )) {
                ForEach(FireHoseDiameterClass.allCases) { value in
                    Text(LocalizedStringKey(value.titleKey)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Slider(
                value: Binding(
                    get: { Double(configuration.fireHoseLengthMeters) },
                    set: { onHoseRiggingChange(configuration.fireHoseDiameterClass, $0) }
                ),
                in: Double(configuration.fireHoseDiameterClass.lengthRangeMeters.lowerBound)...Double(configuration.fireHoseDiameterClass.lengthRangeMeters.upperBound),
                step: Double(configuration.fireHoseDiameterClass.lengthStepMeters)
            )
        }
    }

    private var capsuleRiggingEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("payload.capsule.title")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer()
                Text(String(format: String(localized: "payload.capsule.count_format"), configuration.fireCapsuleCount))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            Picker("", selection: Binding(
                get: { configuration.fireCapsuleSize },
                set: { onCapsuleRiggingChange($0, configuration.fireCapsuleCount) }
            )) {
                ForEach(FireCapsuleSize.allCases) { value in
                    Text(LocalizedStringKey(value.titleKey)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Slider(
                value: Binding(
                    get: { Double(configuration.fireCapsuleCount) },
                    set: { onCapsuleRiggingChange(configuration.fireCapsuleSize, Int($0.rounded())) }
                ),
                in: Double(FireCapsuleTuning.countRange.lowerBound)...Double(FireCapsuleTuning.countRange.upperBound),
                step: 1
            )
        }
    }

    private var customNameEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("payload.custom_name")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.52))

            TextField(
                String(localized: "payload.custom_name"),
                text: Binding(
                    get: { configuration.customName },
                    set: onCustomNameChange
                )
            )
            .focused($isCustomNameFieldFocused)
            .textFieldStyle(.plain)
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(valueFieldBackground(isFocused: isCustomNameFieldFocused))
            .controllerTextInputTarget(
                id: "payload.customName.input",
                title: String(localized: "payload.custom_name"),
                currentText: { configuration.customName },
                onCommit: onCustomNameChange
            )
        }
    }

    private var standardConfigurationSummary: some View {
        HStack(spacing: 10) {
            compactMetric(
                title: "payload.max_payload",
                value: massText(payloadDataResolution?.maxPayloadMass)
            )
            compactMetric(
                title: "payload.remaining_capacity",
                value: massText(remainingPayloadCapacity)
            )
            compactMetric(
                title: "payload.total_mass",
                value: projectedTotalMassText
            )
        }
    }

    private var limitsConsole: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionHeader(titleKey: "payload.limits.title")
                Spacer()
                if let payloadDataResolution {
                    Text("payload.data_source")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.44))
                    consoleBadge(
                        title: payloadDataResolution.sourceQuality.title,
                        tint: payloadDataTint(for: payloadDataResolution.sourceQuality)
                    )
                }
            }

            HStack(spacing: 10) {
                limitMetric(title: "payload.base_mass", value: massText(payloadDataResolution?.baseMass))
                limitMetric(title: "payload.battery_mass", value: massText(payloadDataResolution?.batteryMass))
                limitMetric(title: "payload.max_payload", value: massText(payloadDataResolution?.maxPayloadMass))
                limitMetric(title: "payload.max_takeoff", value: massText(payloadDataResolution?.maxTakeoffMass))

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("payload.capacity_usage")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.48))
                        Spacer()
                        Text(capacityPercentageText)
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(capacityTint)
                    }
                    ProgressView(value: min(max(payloadCapacityRatio, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(capacityTint)
                    Text(capabilityCheck.isAllowed ? "payload.compatibility.ready_hint" : "payload.compatibility.over_limit_hint")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.44))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(metricBackground)
            }
        }
        .padding(14)
        .background(chromePanel(accent: capacityTint.opacity(0.52)))
    }

    private var actionConsole: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(configuration.resolvedName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(capabilityCheck.isAllowed ? compatibleTint : incompatibleTint)
                        .frame(width: 7, height: 7)
                    Text(capabilityCheck.isAllowed ? "payload.compatibility.ready_hint" : "payload.compatibility.over_limit_hint")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
            }
            .frame(width: 210, alignment: .leading)

            actionButton(
                title: "payload.attach",
                systemImage: "link.badge.plus",
                tint: compatibleTint,
                isDisabled: !capabilityCheck.isAllowed,
                action: onAttach
            )

            actionButton(
                title: "payload.release",
                systemImage: "arrow.down.to.line.compact",
                tint: Color(red: 0.25, green: 0.54, blue: 0.90),
                isDisabled: payloadState != .attached,
                action: onRelease
            )

            VStack(alignment: .center, spacing: 3) {
                Text("payload.total_mass")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.48))
                Text(projectedTotalMassText)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(width: 150)
            .frame(minHeight: 62)
            .background(metricBackground)

            actionButton(
                title: "payload.remove",
                systemImage: "xmark.circle",
                tint: Color(red: 0.72, green: 0.27, blue: 0.23),
                isDisabled: payloadState != .attached,
                action: onRemove
            )
        }
        .padding(12)
        .background(chromePanel(accent: Color.cyan.opacity(0.24)))
    }

    private var massBudgetSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("payload.capacity_usage")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.46))
                Spacer()
                Text(capacityPercentageText)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(capacityTint)
            }
            ProgressView(value: min(max(payloadCapacityRatio, 0), 1))
                .progressViewStyle(.linear)
                .tint(capacityTint)
            HStack {
                Text("payload.remaining_capacity")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                Text(massText(remainingPayloadCapacity))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private func cadPayloadStatusBlock(_ payload: MountedCADPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("cad.payload.runtime.name")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.cyan.opacity(0.90))
            Text(payload.partName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            Text("\(String(localized: "cad.payload.runtime.mass")): \(massText(Float(payload.massKg)))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.56))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var projectedTotalMassText: String {
        let value: Float?
        switch payloadState {
        case .noPayload:
            value = capabilityCheck.resultingTotalMass ?? massModel.currentTotalMass
        case .attached, .removed, .released, .falling, .landed, .cleanedUp:
            value = massModel.currentTotalMass ?? capabilityCheck.resultingTotalMass
        }
        return massText(value)
    }

    private var remainingPayloadCapacity: Float? {
        guard let maxPayload = payloadDataResolution?.maxPayloadMass else { return nil }
        return maxPayload - configuration.payloadMass
    }

    private var payloadCapacityRatio: Double {
        guard let maxPayload = payloadDataResolution?.maxPayloadMass, maxPayload > 0 else { return 0 }
        return Double(configuration.payloadMass / maxPayload)
    }

    private var capacityPercentageText: String {
        guard payloadDataResolution?.maxPayloadMass != nil else {
            return String(localized: "common.not_specified")
        }
        return String(format: "%.0f%%", payloadCapacityRatio * 100)
    }

    private var capacityTint: Color {
        if payloadCapacityRatio > 1 || !capabilityCheck.isAllowed { return incompatibleTint }
        if payloadCapacityRatio > 0.8 { return Color(red: 0.96, green: 0.66, blue: 0.22) }
        return compatibleTint
    }

    private var compatibleTint: Color {
        Color(red: 0.36, green: 0.78, blue: 0.45)
    }

    private var incompatibleTint: Color {
        Color(red: 0.94, green: 0.34, blue: 0.27)
    }

    private var effectiveMessageKey: String? {
        statusMessageKey ?? capabilityCheck.rejectReason?.messageKey
    }

    private func catalogConfiguration(for type: PayloadType) -> PayloadConfiguration {
        type == configuration.payloadType ? configuration : PayloadConfiguration(payloadType: type)
    }

    private func catalogCapability(for cardConfiguration: PayloadConfiguration) -> PayloadCapabilityCheck {
        PayloadController.capabilityCheck(for: cardConfiguration, profile: activeUAVProfile)
    }

    private func compatibilityTint(for check: PayloadCapabilityCheck) -> Color {
        check.isAllowed ? compatibleTint : incompatibleTint
    }

    private func compatibilitySymbol(for check: PayloadCapabilityCheck) -> String {
        check.isAllowed ? "checkmark.circle" : "exclamationmark.triangle.fill"
    }

    private func compatibilityBadge(for check: PayloadCapabilityCheck, compact: Bool) -> some View {
        let tint = compatibilityTint(for: check)
        return HStack(spacing: 5) {
            Image(systemName: compatibilitySymbol(for: check))
            if !compact {
                Text(check.isAllowed ? "payload.compatible" : "payload.incompatible")
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(tint.opacity(0.30), lineWidth: 1))
    }

    private func catalogLegend(title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    private func catalogHelpText(for type: PayloadType, check: PayloadCapabilityCheck) -> String {
        let status = String(localized: check.isAllowed ? "payload.compatible" : "payload.incompatible")
        return "\(type.title) · \(massText(type.defaultMass)) · \(status)"
    }

    private func catalogCardBackground(isSelected: Bool, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.065) : Color.black.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.46) : Color.white.opacity(0.065), lineWidth: isSelected ? 1.4 : 1)
            )
    }

    private func statusMessage(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.caption.weight(.medium))
            .foregroundStyle(messageColor(for: key))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(messageBackground(for: key))
    }

    private var shellBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.115, green: 0.125, blue: 0.15),
                        Color(red: 0.065, green: 0.075, blue: 0.095)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var shellStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.white.opacity(0.09), lineWidth: 1)
    }

    private func chromePanel(accent: Color) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.045), Color.black.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.065), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent)
                    .frame(width: 38, height: 3)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
    }

    private func sectionHeader(titleKey: String) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.caption.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(0.68))
    }

    private func consoleBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(tint.opacity(0.30), lineWidth: 1))
    }

    private func compactMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.46))
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.90))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(metricBackground)
    }

    private func limitMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.46))
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(.white.opacity(0.90))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(metricBackground)
    }

    private var metricBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.black.opacity(0.20))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.065), lineWidth: 1)
            )
    }

    private func valueFieldBackground(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.black.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isFocused ? Color.cyan.opacity(0.82) : Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func adjustMassButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 42, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.065))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .controllerButtonTarget(id: "payload.mass.\(symbol)", action: action)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(LocalizedStringKey(title))
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(isDisabled ? Color.white.opacity(0.28) : Color.white.opacity(0.96))
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isDisabled ? Color.white.opacity(0.05) : tint.opacity(0.90))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(isDisabled ? Color.white.opacity(0.04) : tint, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .controllerButtonTarget(id: "payload.action.\(title)", action: action)
    }

    private func adjustMass(by delta: Double) {
        onMassChange(max(0, Double(configuration.payloadMass) + delta))
    }

    private var statusTint: Color {
        switch payloadState {
        case .noPayload: return Color(red: 0.95, green: 0.76, blue: 0.31)
        case .attached: return compatibleTint
        case .removed: return Color(red: 0.95, green: 0.58, blue: 0.28)
        case .released: return Color(red: 0.30, green: 0.74, blue: 0.98)
        case .falling: return Color(red: 0.96, green: 0.66, blue: 0.22)
        case .landed: return Color(red: 0.54, green: 0.82, blue: 0.72)
        case .cleanedUp: return Color(red: 0.74, green: 0.80, blue: 0.86)
        }
    }

    private var mountTint: Color {
        switch payloadMountState {
        case .unavailable: return incompatibleTint
        case .ready: return Color(red: 0.30, green: 0.74, blue: 0.98)
        case .occupied: return Color(red: 0.96, green: 0.66, blue: 0.22)
        }
    }

    private func payloadDataTint(for quality: PayloadDataQualitySource) -> Color {
        switch quality {
        case .verified: return compatibleTint
        case .estimated: return Color(red: 0.30, green: 0.74, blue: 0.98)
        case .custom: return Color(red: 0.96, green: 0.66, blue: 0.22)
        }
    }

    private func typeAccent(for type: PayloadType) -> Color {
        switch type {
        case .cargoBox, .rescuePack: return Color(red: 0.68, green: 0.51, blue: 0.27)
        case .cameraGimbal, .lidarModule, .sensorModule, .radioRelay, .custom:
            return Color(red: 0.36, green: 0.53, blue: 0.63)
        case .thermalCamera: return Color(red: 0.70, green: 0.39, blue: 0.22)
        case .laserRangefinder: return Color(red: 0.67, green: 0.29, blue: 0.25)
        case .fireHose: return Color(red: 0.66, green: 0.30, blue: 0.21)
        case .fireCapsuleLauncher: return Color(red: 0.70, green: 0.39, blue: 0.22)
        case .agriculturalSprayer: return Color(red: 0.36, green: 0.56, blue: 0.37)
        }
    }

    private func payloadDescriptionKey(for type: PayloadType) -> String {
        "payload.type.\(type.rawValue).description"
    }

    private func massText(_ value: Float?) -> String {
        guard let value else { return String(localized: "common.not_specified") }
        return String(format: NSLocalizedString("payload.mass_value", comment: ""), value)
    }

    private func messageColor(for key: String) -> Color {
        switch key {
        case "payload.message.attached": return compatibleTint
        case "payload.message.released": return Color(red: 0.30, green: 0.74, blue: 0.98)
        case "payload.message.dropped_successfully", "payload.message.impact_within_target":
            return Color(red: 0.48, green: 0.82, blue: 0.56)
        case "payload.message.impact_near_target": return Color(red: 0.98, green: 0.74, blue: 0.30)
        case "payload.message.removed", "payload.message.cleanup_completed":
            return Color(red: 0.96, green: 0.66, blue: 0.22)
        default: return incompatibleTint
        }
    }

    private func messageBackground(for key: String) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(messageColor(for: key).opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(messageColor(for: key).opacity(0.24), lineWidth: 1)
            )
    }
}
