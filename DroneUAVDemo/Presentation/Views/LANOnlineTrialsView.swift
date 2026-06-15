import SwiftUI
import Foundation

struct LANOnlineTrialsView: View {
    @ObservedObject var viewModel: LANSessionViewModel
    @State private var didRequestRuntimeOpen = false

    let onClose: () -> Void
    let onLaunchTrial: ((LANTrialLaunchDescriptor, LANParticipant) -> Void)?

    // P2P v1.3: local IPv4 address for display to other participants.
    private var localIPAddress: String {
        let all = Host.current().addresses
        let ipv4 = all.first { $0.contains(".") && !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.") }
        return ipv4 ?? "неизвестно"
    }

    init(
        viewModel: LANSessionViewModel,
        onClose: @escaping () -> Void,
        onLaunchTrial: ((LANTrialLaunchDescriptor, LANParticipant) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
        self.onLaunchTrial = onLaunchTrial
    }

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

            // v1.5: left column (mode cards + setup form) and right column (session panel)
            // share the same HStack so their tops are flush.
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
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

                    lanSetupPanel
                }
                .frame(width: 390, alignment: .topLeading)

                if viewModel.state.connectionState != .idle {
                    sessionStatusPanel
                }
            }
        }
        .frame(maxWidth: 840, alignment: .leading)
        .onChange(of: viewModel.shouldOpenTrialRuntime) { _, shouldOpen in
            requestRuntimeOpenIfNeeded(shouldOpen: shouldOpen)
        }
        // P2P v1.3.1: backup in case .onChange misses an already-true value on appear.
        .onAppear {
            requestRuntimeOpenIfNeeded(shouldOpen: viewModel.shouldOpenTrialRuntime)
        }
    }

    private var lanSetupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("LAN")

            VStack(alignment: .leading, spacing: 7) {
                formLabel("Имя участника")
                TextField("Участник", text: $viewModel.displayName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isSessionActive)
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
            .disabled(viewModel.isSessionActive)
            .opacity(viewModel.isSessionActive ? 0.42 : 1.0)

            Divider()
                .overlay(Color.white.opacity(0.12))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    formLabel("IP / адрес")
                    TextField("127.0.0.1", text: $viewModel.joinAddress)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isSessionActive)
                }

                VStack(alignment: .leading, spacing: 7) {
                    formLabel("Порт")
                    TextField("7777", text: $viewModel.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                        .disabled(viewModel.isSessionActive)
                }
            }

            Button {
                viewModel.joinSession()
            } label: {
                actionLabel("Подключиться", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSessionActive)
            .opacity(viewModel.isSessionActive ? 0.42 : 1.0)

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
        VStack(spacing: 0) {
            // Pinned header — always visible.
            HStack {
                sectionTitle("Сессия")
                Spacer()
                statusBadge(viewModel.state.connectionState)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider().overlay(Color.white.opacity(0.12))

            // Scrollable content area.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // Passive architecture badge — not a user choice.
                    HStack(spacing: 5) {
                        Image(systemName: "circle.grid.3x3.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.46))
                        Text("LAN P2P · Distributed Authority")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.46))
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        formLabel("Соединение")
                        compactMetric("Адрес", connectionAddressText)
                        compactMetric("Порт", "\(viewModel.state.port)")
                        compactMetric("Режим", viewModel.state.mode?.rawValue.uppercased() ?? "-")
                        compactMetric("Фаза", viewModel.state.trialPhase.rawValue.uppercased())
                    }

                    if viewModel.state.mode == .host {
                        VStack(alignment: .leading, spacing: 7) {
                            formLabel("Сетевое подключение")
                            HStack(spacing: 6) {
                                Image(systemName: "network")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.52))
                                Text("Мой IP: ")
                                    .foregroundStyle(.white.opacity(0.52))
                                Text(localIPAddress)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .textSelection(.enabled)
                                Text(":\(viewModel.state.port)")
                                    .foregroundStyle(.white.opacity(0.52))
                            }
                            .font(.caption.monospacedDigit())
                            Text("Сообщи этот адрес другим участникам для подключения.")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.44))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // P2P v1.3: checklist
                    VStack(alignment: .leading, spacing: 4) {
                        formLabel("Статус")
                        checklistRow("Сессия активна", isOk: viewModel.isSessionActive)
                        checklistRow("Участников: \(viewModel.state.participants.count)", isOk: viewModel.state.participants.count > 0)
                        checklistRow("Фаза: \(viewModel.state.trialPhase.rawValue)", isOk: viewModel.state.trialPhase != .ended)
                        if viewModel.isSessionActive {
                            checklistRow("Транспорт: OK", isOk: true)
                            HStack(spacing: 10) {
                                Button {
                                    viewModel.sendTestPing()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                        Text("Тест пинг")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.state.mode == .host)

                                if let rtt = viewModel.onlineDiagnostics.lastPingRoundtripMs {
                                    Text(String(format: "%.0f ms", rtt))
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(rtt < 50 ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 0.95, green: 0.74, blue: 0.35))
                                }
                            }
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

                    if viewModel.state.localParticipant?.isHost == true,
                       viewModel.isSessionActive,
                       viewModel.state.trialPhase == .lobby {
                        launchControlPanel
                    }

                    // P2P v1.3.1: show client waiting state while host hasn't launched yet.
                    if viewModel.state.mode == .client,
                       viewModel.isSessionActive,
                       viewModel.state.trialPhase == .lobby {
                        clientWaitingPanel
                    }

                    // P2P v1.3.1: warn client if runtime handoff appears stuck.
                    if viewModel.state.mode == .client,
                       viewModel.state.trialPhase == .running,
                       !viewModel.shouldOpenTrialRuntime {
                        clientHandoffWarningPanel
                    }

                    if viewModel.state.trialPhase == .ended {
                        trialEndedPanel
                    }
                }
                .padding(16)
            }

            Divider().overlay(Color.white.opacity(0.12))

            // Pinned footer — always visible regardless of scroll position.
            Button {
                viewModel.leaveSession()
            } label: {
                actionLabel("Выйти из сессии", systemImage: "xmark.circle", isDestructive: true)
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .frame(width: 390)
        .frame(minHeight: 520, maxHeight: 640)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(panelStroke(cornerRadius: 12))
    }

    private var connectionAddressText: String {
        switch viewModel.state.mode {
        case .host:
            return "0.0.0.0"
        case .client:
            return viewModel.state.joinAddress
        case .none:
            return "-"
        }
    }

    private var launchControlPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Запуск")
            Text("Пилотам будут назначены аппараты. Наблюдатели войдут без БЛА.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            // P2P v1.3.1: must have ≥2 participants before launch is enabled.
            if viewModel.state.participants.count < 2 {
                HStack(spacing: 7) {
                    Image(systemName: "person.badge.clock")
                    Text("Ожидание подключения участников...")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.95, green: 0.74, blue: 0.35))
            }

            if !viewModel.hasPilotParticipants {
                HStack(spacing: 7) {
                    Image(systemName: "eye")
                    Text("Пилотов нет: испытание откроется в режиме наблюдения.")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.66, green: 0.82, blue: 1.0))
            }

            Button {
                viewModel.launchTrial()
            } label: {
                actionLabel("Запустить испытание", systemImage: "play.circle")
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canLaunchTrial)
            .opacity(viewModel.canLaunchTrial ? 1.0 : 0.42)
        }
        .padding(10)
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: – Client waiting panel

    private var clientWaitingPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.66, green: 0.82, blue: 1.0))
            Text("Ожидание запуска host...")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.66, green: 0.82, blue: 1.0))
        }
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.28), lineWidth: 1)
        )
    }

    private var clientHandoffWarningPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GroundControlPalette.warning)
            Text("Runtime handoff не завершён — перезапустите сессию.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.warning)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(GroundControlPalette.warning.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: – Ended state panel

    private var trialEndedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color(red: 0.35, green: 0.86, blue: 0.58))
                Text("Испытание завершено")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            Text("Нажмите «Выйти из сессии» чтобы вернуться в лобби для нового испытания.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color(red: 0.10, green: 0.16, blue: 0.12).opacity(0.70), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.35, green: 0.86, blue: 0.58).opacity(0.30), lineWidth: 1)
        )
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

                HStack(spacing: 8) {
                    Text(participant.role.displayName)
                    if let vehicleID = participant.assignedVehicleID {
                        Text(String(vehicleID.uuidString.prefix(8)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.56))
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
    }

    private func checklistRow(_ label: String, isOk: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: isOk ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOk ? Color(red: 0.35, green: 0.86, blue: 0.58) : Color(red: 1.0, green: 0.48, blue: 0.38))
            Text(label)
                .foregroundStyle(.white.opacity(0.78))
        }
        .font(.caption)
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

    private func requestRuntimeOpenIfNeeded(shouldOpen: Bool) {
        guard shouldOpen,
              !didRequestRuntimeOpen,
              let descriptor = viewModel.launchDescriptor,
              let participant = viewModel.state.localParticipant else {
            return
        }

        didRequestRuntimeOpen = true
        onLaunchTrial?(descriptor, participant)
    }
}
