import SwiftUI

struct PayloadView: View {
    let configuration: PayloadConfiguration
    let payloadState: PayloadState
    let payloadMountState: PayloadMountState
    let capabilityCheck: PayloadCapabilityCheck
    let massModel: VehicleMassModel
    let statusMessageKey: String?
    let activeUAVProfile: UAVProfile?

    let onTypeChange: (PayloadType) -> Void
    let onMassChange: (Double) -> Void
    let onCustomNameChange: (String) -> Void
    let onAttach: () -> Void
    let onRelease: () -> Void
    let onRemove: () -> Void
    let onClose: (() -> Void)?

    @FocusState private var isMassFieldFocused: Bool
    @FocusState private var isCustomNameFieldFocused: Bool

    private static let massFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private let tileColumns = [
        GridItem(.flexible(minimum: 112), spacing: 10),
        GridItem(.flexible(minimum: 112), spacing: 10),
        GridItem(.flexible(minimum: 112), spacing: 10),
        GridItem(.flexible(minimum: 112), spacing: 10)
    ]

    private var payloadDataResolution: PayloadDataResolution? {
        activeUAVProfile?.payloadDataResolution
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBlock

            HStack(alignment: .top, spacing: 16) {
                leftColumn
                    .frame(width: 288)

                rightColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(18)
        .background(shellBackground)
        .overlay(shellStroke)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.30), radius: 24, x: 0, y: 18)
    }

    private var headerBlock: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.cyan.opacity(0.92))
                    .frame(width: 3, height: 18)
                Rectangle()
                    .fill(Color.cyan.opacity(0.55))
                    .frame(width: 8, height: 2)
                Text("payload.section")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(Color(red: 0.74, green: 0.87, blue: 1.0))
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(activeUAVProfile?.localizedDisplayName ?? String(localized: "common.not_specified"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(2)
                Text("payload.console.subtitle")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(String(localized: "payload.toolbar.close"))
                .controllerButtonTarget(id: "payload.close", action: onClose)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(chromePanel(accent: Color.cyan.opacity(0.55)))
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusConsole
            selectionConsole
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            tilesConsole
            massConsole

            if configuration.payloadType == .custom {
                customNameConsole
            }

            limitsConsole
            actionConsole
        }
    }

    private var statusConsole: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("payload.status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                if let payloadDataResolution {
                    consoleBadge(title: payloadDataResolution.sourceQuality.title, tint: payloadDataTint(for: payloadDataResolution.sourceQuality))
                }
                consoleBadge(title: payloadMountState.title, tint: mountTint)
            }

            Text(payloadState.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(statusTint)

            VStack(alignment: .leading, spacing: 4) {
                Text(configuration.resolvedName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(activeUAVProfile.map { profile in
                    let country = profile.localizedCountryOfOrigin ?? String(localized: "common.not_specified")
                    return "\(profile.manufacturer) / \(country)"
                } ?? String(localized: "common.not_specified"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                compactMetric(
                    title: "payload.mass",
                    value: massText(configuration.payloadMass)
                )
                compactMetric(
                    title: "payload.mount.title",
                    value: payloadMountState.title
                )
            }

            if let messageKey = effectiveMessageKey {
                Text(LocalizedStringKey(messageKey))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(messageColor(for: messageKey))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(messageBackground(for: messageKey))
            }
        }
        .padding(14)
        .background(chromePanel(accent: statusTint.opacity(0.48)))
    }

    private var selectionConsole: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(titleKey: "payload.type")
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Array(PayloadType.allCases.enumerated()), id: \.element.id) { index, type in
                    Button {
                        onTypeChange(type)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbolName(for: type))
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 18)
                                .foregroundStyle(typeAccent(for: type))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.title)
                                    .font(.system(size: 15, weight: type == configuration.payloadType ? .semibold : .medium))
                                    .foregroundStyle(type == configuration.payloadType ? .white : Color.white.opacity(0.78))
                                    .lineLimit(1)
                                Text(massText(type.defaultMass))
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.44))
                            }

                            Spacer(minLength: 8)

                            if type == configuration.payloadType {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.cyan.opacity(0.9))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(selectionRowFill(isSelected: type == configuration.payloadType))
                    }
                    .buttonStyle(.plain)

                    if index < PayloadType.allCases.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(height: 1)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .background(chromePanel(accent: Color.cyan.opacity(0.36)))
    }

    private var tilesConsole: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(titleKey: "payload.type")
                Spacer()
                Text("\(String(localized: "payload.mass")): \(massText(configuration.payloadMass))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            LazyVGrid(columns: tileColumns, spacing: 10) {
                ForEach(PayloadType.allCases) { type in
                    Button {
                        onTypeChange(type)
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: symbolName(for: type))
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(typeAccent(for: type))
                                .frame(height: 34)

                            Text(type.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(type == configuration.payloadType ? .white : Color.white.opacity(0.78))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            Text(massText(type.defaultMass))
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.48))
                        }
                        .frame(maxWidth: .infinity, minHeight: 124)
                        .padding(.horizontal, 8)
                        .background(tileFill(for: type))
                    }
                    .buttonStyle(.plain)
                    .controllerButtonTarget(id: "payload.type.\(type.id)") {
                        onTypeChange(type)
                    }
                }
            }
        }
        .padding(14)
        .background(chromePanel(accent: Color.cyan.opacity(0.34)))
    }

    private var massConsole: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(titleKey: "payload.mass")

            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    TextField(
                        String(localized: "payload.mass"),
                        value: Binding(
                            get: { Double(configuration.payloadMass) },
                            set: onMassChange
                        ),
                        formatter: Self.massFormatter
                    )
                    .focused($isMassFieldFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .controllerTextInputTarget(
                        id: "payload.mass.input",
                        title: String(localized: "payload.mass"),
                        currentText: {
                            Self.massFormatter.string(from: NSNumber(value: configuration.payloadMass)) ?? ""
                        },
                        onCommit: { text in
                            guard let parsed = Self.massFormatter.controllerDouble(from: text) else {
                                return
                            }
                            onMassChange(parsed)
                        }
                    )

                    Text("kg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(valueFieldBackground(isFocused: isMassFieldFocused))

                HStack(spacing: 8) {
                    adjustMassButton(symbol: "minus") {
                        adjustMass(by: -0.25)
                    }
                    adjustMassButton(symbol: "plus") {
                        adjustMass(by: 0.25)
                    }
                }

                compactMetric(
                    title: "payload.total_mass",
                    value: projectedTotalMassText
                )
                .frame(width: 170)
            }
        }
        .padding(14)
        .background(chromePanel(accent: Color.orange.opacity(0.34)))
    }

    private var customNameConsole: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(titleKey: "payload.custom_name")

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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(valueFieldBackground(isFocused: isCustomNameFieldFocused))
            .controllerTextInputTarget(
                id: "payload.customName.input",
                title: String(localized: "payload.custom_name"),
                currentText: { configuration.customName },
                onCommit: onCustomNameChange
            )
        }
        .padding(14)
        .background(chromePanel(accent: Color.cyan.opacity(0.28)))
    }

    private var limitsConsole: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(titleKey: "payload.limits.title")

            if let payloadDataResolution {
                HStack(spacing: 8) {
                    Text("payload.data_source")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.48))
                    consoleBadge(title: payloadDataResolution.sourceQuality.title, tint: payloadDataTint(for: payloadDataResolution.sourceQuality))
                    if payloadDataResolution.usesEstimatedValues {
                        Text(LocalizedStringKey("payload.data.estimated_hint"))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }
            }

            HStack(spacing: 10) {
                limitMetric(title: "payload.base_mass", value: massText(payloadDataResolution?.baseMass))
                limitMetric(title: "payload.battery_mass", value: massText(payloadDataResolution?.batteryMass))
                limitMetric(title: "payload.max_payload", value: massText(payloadDataResolution?.maxPayloadMass))
                limitMetric(title: "payload.max_takeoff", value: massText(payloadDataResolution?.maxTakeoffMass))
            }
        }
        .padding(14)
        .background(chromePanel(accent: Color.cyan.opacity(0.28)))
    }

    private var actionConsole: some View {
        HStack(spacing: 12) {
            actionButton(
                title: "payload.attach",
                tint: Color(red: 0.42, green: 0.68, blue: 0.34),
                isDisabled: !capabilityCheck.isAllowed
            ) {
                onAttach()
            }

            actionButton(
                title: "payload.release",
                tint: Color(red: 0.25, green: 0.54, blue: 0.90),
                isDisabled: payloadState != .attached
            ) {
                onRelease()
            }

            VStack(alignment: .center, spacing: 5) {
                Text("payload.total_mass")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.52))
                Text(projectedTotalMassText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1.0)
                    )
            )

            actionButton(
                title: "payload.remove",
                tint: Color(red: 0.72, green: 0.27, blue: 0.23),
                isDisabled: payloadState != .attached
            ) {
                onRemove()
            }
        }
        .padding(14)
        .background(chromePanel(accent: Color.cyan.opacity(0.22)))
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

    private var effectiveMessageKey: String? {
        if let statusMessageKey {
            return statusMessageKey
        }
        return capabilityCheck.rejectReason?.messageKey
    }

    private var statusTint: Color {
        switch payloadState {
        case .noPayload:
            return Color(red: 0.95, green: 0.76, blue: 0.31)
        case .attached:
            return Color(red: 0.50, green: 0.84, blue: 0.40)
        case .removed:
            return Color(red: 0.95, green: 0.58, blue: 0.28)
        case .released:
            return Color(red: 0.30, green: 0.74, blue: 0.98)
        case .falling:
            return Color(red: 0.96, green: 0.66, blue: 0.22)
        case .landed:
            return Color(red: 0.54, green: 0.82, blue: 0.72)
        case .cleanedUp:
            return Color(red: 0.74, green: 0.80, blue: 0.86)
        }
    }

    private var mountTint: Color {
        switch payloadMountState {
        case .unavailable:
            return Color(red: 0.84, green: 0.34, blue: 0.30)
        case .ready:
            return Color(red: 0.30, green: 0.74, blue: 0.98)
        case .occupied:
            return Color(red: 0.96, green: 0.66, blue: 0.22)
        }
    }

    private func payloadDataTint(for quality: PayloadDataQualitySource) -> Color {
        switch quality {
        case .verified:
            return Color(red: 0.50, green: 0.84, blue: 0.40)
        case .estimated:
            return Color(red: 0.30, green: 0.74, blue: 0.98)
        case .custom:
            return Color(red: 0.96, green: 0.66, blue: 0.22)
        }
    }

    private var shellBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.13, blue: 0.16),
                        Color(red: 0.08, green: 0.09, blue: 0.11)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var shellStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.white.opacity(0.09), lineWidth: 1.0)
    }

    private func chromePanel(accent: Color) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.black.opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1.0)
            )
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent)
                    .frame(width: 36, height: 3)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.15))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.34), lineWidth: 1.0)
                    )
            )
    }

    private func compactMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1.0)
                )
        )
    }

    private func limitMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1.0)
                )
        )
    }

    private func selectionRowFill(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color.cyan.opacity(0.16) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.cyan.opacity(0.44) : Color.clear, lineWidth: 1.0)
            )
    }

    private func tileFill(for type: PayloadType) -> some View {
        let isSelected = type == configuration.payloadType

        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? typeAccent(for: type).opacity(0.18) : Color.black.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? typeAccent(for: type).opacity(0.66) : Color.white.opacity(0.06), lineWidth: 1.0)
            )
    }

    private func valueFieldBackground(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.black.opacity(0.20))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isFocused ? Color.cyan.opacity(0.82) : Color.white.opacity(0.08), lineWidth: 1.0)
            )
    }

    private func adjustMassButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1.0)
                        )
                )
        }
        .buttonStyle(.plain)
        .controllerButtonTarget(id: "payload.mass.\(symbol)", action: action)
    }

    private func actionButton(
        title: String,
        tint: Color,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(isDisabled ? Color.white.opacity(0.32) : Color.white.opacity(0.96))
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isDisabled ? Color.white.opacity(0.06) : tint.opacity(0.92))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isDisabled ? Color.white.opacity(0.04) : tint.opacity(0.96), lineWidth: 1.0)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .controllerButtonTarget(id: "payload.action.\(title)", action: action)
    }

    private func adjustMass(by delta: Double) {
        let updated = max(0.0, Double(configuration.payloadMass) + delta)
        onMassChange(updated)
    }

    private func symbolName(for type: PayloadType) -> String {
        switch type {
        case .cargoBox:
            return "shippingbox.fill"
        case .cameraGimbal:
            return "camera.viewfinder"
        case .thermalCamera:
            return "thermometer.medium"
        case .lidarModule:
            return "wave.3.right.circle.fill"
        case .rescuePack:
            return "cross.case.fill"
        case .sensorModule:
            return "sensor.fill"
        case .radioRelay:
            return "dot.radiowaves.left.and.right"
        case .custom:
            return "plus"
        }
    }

    private func typeAccent(for type: PayloadType) -> Color {
        switch type {
        case .cargoBox, .rescuePack, .sensorModule:
            return Color(red: 0.96, green: 0.80, blue: 0.28)
        case .cameraGimbal, .radioRelay:
            return Color(red: 0.28, green: 0.65, blue: 0.98)
        case .thermalCamera:
            return Color(red: 0.99, green: 0.58, blue: 0.28)
        case .lidarModule:
            return Color(red: 0.70, green: 0.78, blue: 0.92)
        case .custom:
            return Color(red: 0.30, green: 0.74, blue: 0.98)
        }
    }

    private func massText(_ value: Float?) -> String {
        guard let value else {
            return String(localized: "common.not_specified")
        }
        return String(format: NSLocalizedString("payload.mass_value", comment: ""), value)
    }

    private func messageColor(for key: String) -> Color {
        switch key {
        case "payload.message.attached":
            return Color(red: 0.52, green: 0.84, blue: 0.42)
        case "payload.message.released":
            return Color(red: 0.30, green: 0.74, blue: 0.98)
        case "payload.message.dropped_successfully":
            return Color(red: 0.54, green: 0.82, blue: 0.72)
        case "payload.message.removed",
             "payload.message.cleanup_completed":
            return Color(red: 0.96, green: 0.66, blue: 0.22)
        case "payload.message.payload_limit_exceeded",
             "payload.message.takeoff_limit_exceeded",
             "payload.message.data_unavailable",
             "payload.message.invalid_mass",
             "payload.message.no_payload_attached":
            return Color(red: 0.98, green: 0.52, blue: 0.42)
        default:
            return .white.opacity(0.70)
        }
    }

    private func messageBackground(for key: String) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(
                {
                    switch key {
                    case "payload.message.attached":
                        return Color.green.opacity(0.16)
                    case "payload.message.released":
                        return Color.blue.opacity(0.16)
                    case "payload.message.dropped_successfully":
                        return Color.teal.opacity(0.16)
                    case "payload.message.removed",
                         "payload.message.cleanup_completed":
                        return Color.orange.opacity(0.16)
                    case "payload.message.payload_limit_exceeded",
                         "payload.message.takeoff_limit_exceeded",
                         "payload.message.data_unavailable",
                         "payload.message.invalid_mass",
                         "payload.message.no_payload_attached":
                        return Color.red.opacity(0.16)
                    default:
                        return Color.white.opacity(0.06)
                    }
                }()
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1.0)
            )
    }
}
