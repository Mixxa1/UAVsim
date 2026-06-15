import SwiftUI

struct LANOnlineTrialsView: View {
    @StateObject private var viewModel = LANSessionViewModel()

    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                        Text("Назад")
                    }
                    .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(panelFill, in: RoundedRectangle(cornerRadius: 8))

                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Мульти-испытания")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text("Локальная LAN-оболочка для P2P-сессий. Server будет добавлен позже.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.68))
            }

            HStack(spacing: 12) {
                entryModePanel(
                    title: "LAN",
                    subtitle: "Локальная сеть",
                    systemImage: "network",
                    isActive: true,
                    isDisabled: false
                )

                entryModePanel(
                    title: "Server",
                    subtitle: "позже",
                    systemImage: "server.rack",
                    isActive: false,
                    isDisabled: true
                )
            }

            HStack(alignment: .top, spacing: 14) {
                lanSetupPanel

                if viewModel.state.connectionState != .idle {
                    sessionStatusPanel
                }
            }
        }
        .frame(maxWidth: 840, alignment: .leading)
    }

    private var lanSetupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("LAN")

            VStack(alignment: .leading, spacing: 7) {
                formLabel("Имя участника")
                TextField("Участник", text: $viewModel.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 7) {
                formLabel("Роль")
                Picker("Роль", selection: $viewModel.selectedRole) {
                    ForEach(LANParticipantRole.allCases) { role in
                        Text(role.displayName).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.selectedRole) { _, role in
                    viewModel.selectRole(role)
                }
            }

            Button {
                viewModel.createHostSession()
            } label: {
                actionLabel("Создать LAN-сессию", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)

            Divider()
                .overlay(Color.white.opacity(0.12))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    formLabel("IP / адрес")
                    TextField("127.0.0.1", text: $viewModel.joinAddress)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 7) {
                    formLabel("Порт")
                    TextField("7777", text: $viewModel.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                }
            }

            Button {
                viewModel.joinSession()
            } label: {
                actionLabel("Подключиться", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.plain)

            if let error = viewModel.state.lastErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.63, blue: 0.36))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .frame(width: 390, alignment: .topLeading)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(panelStroke(cornerRadius: 12))
    }

    private var sessionStatusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Сессия")
                Spacer()
                statusBadge(viewModel.state.connectionState)
            }

            if let config = viewModel.state.config {
                VStack(alignment: .leading, spacing: 7) {
                    formLabel("Конфигурация")
                    compactMetric("Название", config.sessionName)
                    compactMetric("Карта", "\(config.mapID), масштаб \(config.mapScale)")
                    compactMetric("Погода", config.weatherPresetID)
                    compactMetric("Пилоты", "\(config.maxPilots)")
                }
            }

            if let local = viewModel.state.localParticipant {
                VStack(alignment: .leading, spacing: 7) {
                    formLabel("Локальный участник")
                    participantRow(local, isLocal: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                formLabel("Участники")
                if viewModel.state.participants.isEmpty {
                    Text("Список пуст")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.54))
                } else {
                    ForEach(viewModel.state.participants) { participant in
                        participantRow(
                            participant,
                            isLocal: participant.id == viewModel.state.localParticipant?.id
                        )
                    }
                }
            }

            Button {
                viewModel.leaveSession()
            } label: {
                actionLabel("Выйти", systemImage: "xmark.circle", isDestructive: true)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 390, alignment: .topLeading)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(panelStroke(cornerRadius: 12))
    }

    private func entryModePanel(
        title: String,
        subtitle: String,
        systemImage: String,
        isActive: Bool,
        isDisabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                if isDisabled {
                    Text("позже")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.44))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(isDisabled ? 0.42 : 0.66))
            }
        }
        .foregroundStyle(.white.opacity(isDisabled ? 0.42 : 0.92))
        .padding(14)
        .frame(width: 180, height: 112, alignment: .topLeading)
        .background(
            (isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.045)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isActive ? 0.34 : 0.14), lineWidth: 1)
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.92))
    }

    private func formLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.54))
    }

    private func actionLabel(
        _ title: String,
        systemImage: String,
        isDestructive: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(isDestructive ? Color(red: 1.0, green: 0.64, blue: 0.52) : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(isDestructive ? 0.055 : 0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(isDestructive ? 0.20 : 0.24), lineWidth: 1)
        )
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white.opacity(0.58))
            Spacer()
            Text(value)
                .foregroundStyle(.white.opacity(0.86))
        }
        .font(.caption.monospacedDigit())
    }

    private func participantRow(_ participant: LANParticipant, isLocal: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: participant.role == .pilot ? "airplane" : "eye")
                .frame(width: 18)
                .foregroundStyle(.white.opacity(0.82))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(participant.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    if participant.isHost {
                        Text("HOST")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.82))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.78), in: Capsule())
                    }
                    if isLocal {
                        Text("LOCAL")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }

                Text(participant.role.displayName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.56))
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusBadge(_ state: LANConnectionState) -> some View {
        Text(statusText(state))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(statusColor(state).opacity(0.64), lineWidth: 1))
    }

    private func statusText(_ state: LANConnectionState) -> String {
        switch state {
        case .idle:
            return "IDLE"
        case .hosting:
            return "HOSTING"
        case .joining:
            return "JOINING"
        case .connected:
            return "CONNECTED"
        case .disconnected:
            return "DISCONNECTED"
        case .failed:
            return "FAILED"
        }
    }

    private func statusColor(_ state: LANConnectionState) -> Color {
        switch state {
        case .idle:
            return .white
        case .hosting, .connected:
            return Color(red: 0.35, green: 0.86, blue: 0.58)
        case .joining:
            return Color(red: 0.95, green: 0.74, blue: 0.35)
        case .disconnected, .failed:
            return Color(red: 1.0, green: 0.48, blue: 0.38)
        }
    }

    private var panelFill: Color {
        Color(red: 0.08, green: 0.11, blue: 0.15).opacity(0.92)
    }

    private func panelStroke(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(Color.white.opacity(0.16), lineWidth: 1)
    }
}
