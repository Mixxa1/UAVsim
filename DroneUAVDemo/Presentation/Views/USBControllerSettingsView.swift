import SwiftUI
import AppKit
import SceneKit

struct USBControllerSettingsView: View {
    @ObservedObject private var store = USBControllerStore.shared
    var profile: DroneModelProfile? = nil
    @State private var calibrating = false
    private var selected: USBDevice? { store.devices.first { $0.id == store.selectedDeviceID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Радиоаппаратура и USB-джойстики").font(.headline)
            Text("Подключите пульт кабелем передачи данных и выберите USB Joystick в EdgeTX / OpenTX.").font(.caption).foregroundStyle(.secondary)
            Picker("Источник", selection: $store.selectedDeviceID) {
                Text("Геймпады · автоматический выбор").tag("")
                ForEach(store.devices) { device in Text(device.name).tag(device.id) }
                if !store.selectedDeviceID.isEmpty, selected == nil { Text("Выбранный пульт отключён").tag(store.selectedDeviceID) }
            }
            if let selected {
                HStack {
                    Label(store.configurations[selected.id] == nil ? "Нужна калибровка" : "Калибровка сохранена", systemImage: "slider.horizontal.3")
                    Spacer()
                    Button("Мастер калибровки") { calibrating = true }.buttonStyle(.borderedProminent)
                }
                TransmitterResponsePreview(axes: store.normalizedAxes(), pressed: pressedButtons(selected), profile: profile).frame(height: 240)
            } else if store.devices.isEmpty {
                Text("USB HID устройств пока нет. После подключения пульт появится здесь автоматически.").font(.callout).foregroundStyle(.secondary)
            }
            if !store.status.isEmpty { Text(store.status).foregroundStyle(.orange) }
        }
        .sheet(isPresented: $calibrating) {
            if let selected {
                ScaledSettingsPanel(minimumSize: CGSize(width: 700, height: 660)) { USBCalibrationWizard(device: selected, profile: profile) }
                    .frame(width: min(820, (NSScreen.main?.visibleFrame.width ?? 1100) - 80), height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
            }
        }
    }
    private func pressedButtons(_ device: USBDevice) -> Set<Int> {
        Set(device.channels.filter(\.isButton).enumerated().compactMap { index, channel in
            (store.values[device.id]?[channel.id] ?? channel.minimum) > (channel.minimum + channel.maximum) / 2 ? index : nil
        })
    }
}

struct USBCalibrationWizard: View {
    let device: USBDevice
    var profile: DroneModelProfile?
    @ObservedObject private var store = USBControllerStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var centers: [String: Double] = [:]
    @State private var minimums: [String: Double] = [:]
    @State private var maximums: [String: Double] = [:]
    @State private var draft = USBDeviceConfiguration(deviceName: "", calibration: [:], axes: [:])
    @State private var error: String?
    private var pressedButtons: Set<Int> {
        Set(device.channels.filter(\.isButton).enumerated().compactMap { index, channel in
            (store.values[device.id]?[channel.id] ?? channel.minimum) > (channel.minimum + channel.maximum) / 2 ? index : nil
        })
    }
    private var connected: Bool { store.devices.contains { $0.id == device.id } }
    private var analog: [USBChannel] { device.channels.filter { !$0.isButton } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Калибровка · \(device.name)").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            ProgressView(value: Double(step), total: 3)
            if !connected { Label("Пульт отключён. Подключите его для продолжения.", systemImage: "cable.connector.slash").foregroundStyle(.orange) }
            Text(instruction).font(.headline)
            if step < 2 {
                ForEach(analog) { channel in
                    HStack {
                        Text(channel.name).frame(width: 60, alignment: .leading)
                        ProgressView(value: fraction(channel)).frame(maxWidth: .infinity)
                        Text("\(Int(store.values[device.id]?[channel.id] ?? channel.minimum))").monospacedDigit().frame(width: 65)
                    }
                }
                Text(step == 0 ? "Все стики в центре, газ на половине хода. Не трогайте оси, затем зафиксируйте центр." : "Несколько раз проведите каждый стик по полному ходу, включая углы, ручки и ползунки.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ControllerAxisFunction.flightAxes) { function in
                            HStack {
                                Text(LocalizedStringKey(function.titleKey)).frame(width: 100, alignment: .leading)
                                Picker("Канал", selection: axisBinding(function)) {
                                    Text("Выберите ось").tag("")
                                    ForEach(analog) { Text($0.name).tag($0.id) }
                                }.labelsHidden()
                                Toggle("Инверсия", isOn: invertedBinding(function))
                            }
                        }
                        Picker("Газ", selection: $draft.throttleMode) {
                            Text("Положение стика (пульт)").tag(ControllerThrottleMode.absolute)
                            Text("Изменение газа (джойстик)").tag(ControllerThrottleMode.rate)
                        }
                        ForEach(device.channels.filter(\.isButton)) { channel in
                            Picker(channel.name, selection: buttonBinding(channel)) {
                                Text("Не назначена").tag("")
                                ForEach(USBFlightButtonAction.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                        }
                        TransmitterResponsePreview(axes: store.normalizedAxes(deviceID: device.id, configuration: draft), pressed: pressedButtons, profile: profile).frame(height: 220)
                        Text("Проверьте направления: газ вверх увеличивается, крен вправо положительный, тангаж вперёд положительный.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                if step > 0 { Button("Заново") { step = 0; centers = [:]; minimums = [:]; maximums = [:] } }
                Spacer()
                Button(step == 0 ? "Зафиксировать центр →" : step == 1 ? "Назначить каналы →" : "Сохранить калибровку") { advance() }
                    .buttonStyle(.borderedProminent).disabled(!connected || analog.count < 4)
            }
        }
        .padding(24).frame(width: 700, height: 660)
        .onAppear { store.isCalibrating = true; draft.deviceName = device.name }
        .onDisappear { store.isCalibrating = false }
        .onReceive(store.$values) { values in
            guard step == 1 else { return }
            for channel in analog {
                guard let raw = values[device.id]?[channel.id] else { continue }
                minimums[channel.id] = min(minimums[channel.id] ?? raw, raw)
                maximums[channel.id] = max(maximums[channel.id] ?? raw, raw)
            }
        }
    }
    private var instruction: String { step == 0 ? "Центр стиков" : step == 1 ? "Полный диапазон хода" : "Назначение и проверка отклика" }
    private func fraction(_ channel: USBChannel) -> Double { min(1, max(0, ((store.values[device.id]?[channel.id] ?? channel.minimum) - channel.minimum) / (channel.maximum - channel.minimum))) }
    private func axisBinding(_ function: ControllerAxisFunction) -> Binding<String> {
        Binding(get: { draft.axes[function.rawValue]?.channel ?? "" }, set: { draft.axes[function.rawValue] = USBAxisAssignment(channel: $0) })
    }
    private func invertedBinding(_ function: ControllerAxisFunction) -> Binding<Bool> {
        Binding(get: { draft.axes[function.rawValue]?.inverted ?? false }, set: { value in
            guard var assignment = draft.axes[function.rawValue] else { return }; assignment.inverted = value; draft.axes[function.rawValue] = assignment
        })
    }
    private func buttonBinding(_ channel: USBChannel) -> Binding<String> {
        Binding(get: { draft.buttons[channel.id]?.rawValue ?? "" }, set: { draft.buttons[channel.id] = USBFlightButtonAction(rawValue: $0) })
    }
    private func advance() {
        error = nil
        if step == 0 {
            centers = store.values[device.id] ?? [:]; minimums = centers; maximums = centers; step = 1
        } else if step == 1 {
            draft.calibration = [:]
            for channel in analog {
                guard let low = minimums[channel.id], let high = maximums[channel.id], let center = centers[channel.id],
                      high - low >= (channel.maximum - channel.minimum) * 0.25, low < center, center < high else { continue }
                draft.calibration[channel.id] = USBAxisCalibration(minimum: low, center: center, maximum: high)
            }
            guard draft.calibration.count >= 4 else { error = "У четырёх осей должен быть полный ход в обе стороны от центра"; return }
            if let previous = store.configurations[device.id] { draft.axes = previous.axes; draft.buttons = previous.buttons; draft.throttleMode = previous.throttleMode }
            step = 2
        } else {
            do { try store.save(draft, for: device.id); store.selectedDeviceID = device.id; dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Articulated transmitter and the actual catalogue airframe share the same live axis values.
struct TransmitterResponsePreview: NSViewRepresentable {
    let axes: [ControllerAxisFunction: Double]
    let pressed: Set<Int>
    var profile: DroneModelProfile?
    final class Coordinator {
        var left = SCNNode(), right = SCNNode()
        let aircraft = SCNNode()
        var switches: [SCNNode] = [], buttons: [SCNNode] = []
        var propellers: [SCNNode] = []
        var lastThrottle: Float = -2
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(); let scene = SCNScene(); view.scene = scene
        view.backgroundColor = .clear; view.preferredFramesPerSecond = 30; view.isPlaying = true
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 150
        scene.rootNode.addChildNode(ambient)
        let keyLight = SCNNode(); keyLight.light = SCNLight(); keyLight.light?.type = .omni; keyLight.light?.intensity = 900
        keyLight.position = SCNVector3(0, 4, 6); scene.rootNode.addChildNode(keyLight)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(0, 0.8, 9); camera.look(at: SCNVector3(0, 0.4, 0)); scene.rootNode.addChildNode(camera); view.pointOfView = camera
        camera.camera?.wantsHDR = true; camera.camera?.wantsExposureAdaptation = false; camera.camera?.exposureOffset = -0.25
        view.allowsCameraControl = true
        let transmitter = Self.makeTransmitterNode()
        transmitter.simdScale = SIMD3(repeating: 16)
        transmitter.position = SCNVector3(-2.2, -0.25, 0)
        transmitter.eulerAngles = SCNVector3(-0.12, -0.40, 0.02)
        scene.rootNode.addChildNode(transmitter)
        context.coordinator.left = transmitter.childNode(withName: "GimbalLeft", recursively: true) ?? SCNNode()
        context.coordinator.right = transmitter.childNode(withName: "GimbalRight", recursively: true) ?? SCNNode()
        context.coordinator.switches = (0..<8).compactMap { transmitter.childNode(withName: "Switch\($0)", recursively: true) }
        context.coordinator.buttons = (0..<6).compactMap { transmitter.childNode(withName: "Button\($0)", recursively: true) }
        let floor = SCNNode(geometry: SCNFloor()); floor.position.y = -1.9
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.12, alpha: 1)
        (floor.geometry as? SCNFloor)?.reflectivity = 0.04; scene.rootNode.addChildNode(floor)
        let selected: DroneModelProfile
        if let profile, profile.visualClass != .abstract || profile.workbenchBuild != nil {
            selected = profile
        } else {
            selected = LIPODroneModelRepository().defaultProfile
        }
        let model = DroneModelBuilder.build(profile: selected)
        let size = model.visualBoundsSize
        let scale: Float = 2.5 / max(0.01, max(size.x, max(size.y, size.z)))
        model.rootNode.simdScale = SIMD3(repeating: scale)
        model.rootNode.simdPosition = -model.visualBoundsCenter * scale
        context.coordinator.propellers = model.propellerNodes
        context.coordinator.left.name = "transmitter.left-gimbal"; context.coordinator.right.name = "transmitter.right-gimbal"
        context.coordinator.aircraft.addChildNode(model.rootNode); context.coordinator.aircraft.position.x = 2.5; context.coordinator.aircraft.eulerAngles.x = 0.4
        scene.rootNode.addChildNode(context.coordinator.aircraft)
        return view
    }
    private static var transmitterTemplate: SCNNode?
    static func makeTransmitterNode() -> SCNNode {
        if let transmitterTemplate { return transmitterTemplate.clone() }
        guard let url = Bundle.main.url(forResource: "RadioMasterTX16S", withExtension: "usdz", subdirectory: "Controllers")
                ?? Bundle.main.url(forResource: "RadioMasterTX16S", withExtension: "usdz"),
              let asset = try? SCNScene(url: url, options: [.checkConsistency: false, .preserveOriginalTopology: false]) else {
            return SCNNode()
        }
        let root = SCNNode()
        for child in asset.rootNode.childNodes { root.addChildNode(child.clone()) }
        root.name = "transmitter.radiomaster.tx16s"
        transmitterTemplate = root
        return root.clone()
    }
    func updateNSView(_ view: SCNView, context: Context) {
        let yaw = Float(axes[.yaw] ?? 0), throttle = Float(axes[.throttle] ?? -1), pitch = Float(axes[.pitch] ?? 0), roll = Float(axes[.roll] ?? 0)
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.06
        context.coordinator.left.eulerAngles = SCNVector3(-throttle * 0.45, yaw * 0.45, 0)
        context.coordinator.right.eulerAngles = SCNVector3(-pitch * 0.45, roll * 0.45, 0)
        context.coordinator.aircraft.eulerAngles = SCNVector3(0.4 + pitch * 0.4, yaw * 0.65, -roll * 0.4)
        context.coordinator.aircraft.position.y = CGFloat((throttle + 1) * 0.25)
        for (index, toggle) in context.coordinator.switches.enumerated() {
            toggle.eulerAngles.x = pressed.contains(index) ? -0.40 : 0.28
        }
        for (index, button) in context.coordinator.buttons.enumerated() {
            button.position.z = CGFloat(pressed.contains(index + 8) ? 0.0385 : 0.040)
        }
        SCNTransaction.commit()
        if abs(context.coordinator.lastThrottle - throttle) > 0.05 {
            context.coordinator.lastThrottle = throttle
            for propeller in context.coordinator.propellers {
                propeller.removeAction(forKey: "preview.spin")
                if throttle > -0.95 {
                    let duration = Double(0.18 - (throttle + 1) * 0.07)
                    propeller.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: duration)), forKey: "preview.spin")
                }
            }
        }
    }
}
