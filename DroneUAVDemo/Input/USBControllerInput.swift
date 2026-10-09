import Foundation
import Combine
import IOKit.hid

struct USBChannel: Identifiable, Equatable {
    var id: String
    var name: String
    var minimum: Double
    var maximum: Double
    var isButton: Bool
}
struct USBDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var channels: [USBChannel]
}
struct USBAxisCalibration: Codable, Equatable {
    var minimum: Double
    var center: Double
    var maximum: Double
    func normalized(_ raw: Double, inverted: Bool = false, deadzone: Double = 0.04) -> Double {
        guard raw.isFinite, minimum.isFinite, center.isFinite, maximum.isFinite,
              minimum < center, center < maximum else { return 0 }
        let value = raw >= center ? (raw - center) / (maximum - center) : (raw - center) / (center - minimum)
        let clamped = min(1, max(-1, inverted ? -value : value))
        let zone = min(0.4, max(0, deadzone))
        guard abs(clamped) > zone else { return 0 }
        return (clamped < 0 ? -1 : 1) * (abs(clamped) - zone) / (1 - zone)
    }
}
struct USBAxisAssignment: Codable, Equatable {
    var channel: String
    var inverted = false
    var deadzone = 0.04
}
enum USBFlightButtonAction: String, Codable, CaseIterable, Identifiable {
    case arm, disarm, armSwitch, returnHome, manual, hover, fpv, camera, payload, rewind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .armSwitch: return "ARM / DISARM"; case .rewind: return "Перемотка"
        case .arm: return "ARM"; case .disarm: return "DISARM"; case .returnHome: return "Возврат домой"
        case .manual: return "Ручное управление"; case .hover: return "Зависание"; case .fpv: return "FPV"
        case .camera: return "Камера"; case .payload: return "Сброс нагрузки"
        }
    }
    var inputAction: InputAction {
        switch self {
        case .armSwitch: return .armAircraft; case .rewind: return .rewindFlight
        case .arm: return .armAircraft; case .disarm: return .disarmAircraft; case .returnHome: return .returnHome
        case .manual: return .takeManualControl; case .hover: return .requestHover; case .fpv: return .toggleFPV
        case .camera: return .cycleCameraMode; case .payload: return .dropPayload
        }
    }
}
struct USBDeviceConfiguration: Codable, Equatable {
    var deviceName: String
    var calibration: [String: USBAxisCalibration]
    /// Keys are ControllerAxisFunction.rawValue, values identify HID elements rather than their ordering.
    var axes: [String: USBAxisAssignment]
    var buttons: [String: USBFlightButtonAction] = [:]
    var throttleMode: ControllerThrottleMode = .absolute
    func validate() throws {
        var used = Set<String>()
        for function in ControllerAxisFunction.flightAxes {
            guard let assignment = axes[function.rawValue], used.insert(assignment.channel).inserted,
                  let c = calibration[assignment.channel], c.minimum.isFinite, c.center.isFinite, c.maximum.isFinite,
                  c.minimum < c.center, c.center < c.maximum, assignment.deadzone.isFinite,
                  (0...0.4).contains(assignment.deadzone) else {
                throw ControlProfileError.invalid("Назначьте четыре разные оси и завершите калибровку")
            }
        }
        guard axes.count <= 8, calibration.count <= 128, buttons.count <= 128 else { throw ControlProfileError.invalid("Слишком много каналов") }
        for (function, assignment) in axes {
            guard ControllerAxisFunction(rawValue: function) != nil, let c = calibration[assignment.channel],
                  c.minimum.isFinite, c.center.isFinite, c.maximum.isFinite, c.minimum < c.center, c.center < c.maximum,
                  assignment.deadzone.isFinite, (0...0.4).contains(assignment.deadzone) else { throw ControlProfileError.invalid("Некорректная USB-ось") }
        }
    }
}

/// Uses the non-exclusive IOHID manager. Device values are copied on the main run loop;
/// SwiftUI receives at most 30 updates/s, regardless of the radio's report rate.
final class USBControllerStore: ObservableObject {
    static let shared = USBControllerStore()
    @Published private(set) var devices: [USBDevice] = []
    @Published private(set) var values: [String: [String: Double]] = [:]
    @Published private(set) var configurations: [String: USBDeviceConfiguration]
    @Published var selectedDeviceID: String {
        didSet { defaults.set(selectedDeviceID, forKey: "input.usb.selected"); previousButtons.removeAll(); suppressButtonEdgesOnce = true }
    }
    @Published var isCalibrating = false { didSet { suppressButtonEdgesOnce = true } }
    @Published private(set) var status = ""
    private let defaults: UserDefaults
    private let manager: IOHIDManager
    private var deviceKeys: [ObjectIdentifier: String] = [:]
    private var rawValues: [String: [String: Double]] = [:]
    private var previousButtons = Set<String>()
    private var suppressButtonEdgesOnce = true
    private var pendingDisconnectDisarm = false
    private var timer: Timer?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedDeviceID = defaults.string(forKey: "input.usb.selected") ?? ""
        configurations = defaults.data(forKey: "input.usb.calibrations.v1").flatMap { try? JSONDecoder().decode([String: USBDeviceConfiguration].self, from: $0) } ?? [:]
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [4, 5, 8].map { [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<USBControllerStore>.fromOpaque(context).takeUnretainedValue().connected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<USBControllerStore>.fromOpaque(context).takeUnretainedValue().disconnected(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<USBControllerStore>.fromOpaque(context).takeUnretainedValue().received(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { status = "USB HID недоступен: \(result)" }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, self.values != self.rawValues else { return }
            self.values = self.rawValues
        }
    }
    deinit {
        timer?.invalidate()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    private func channelID(_ element: IOHIDElement) -> String {
        "\(IOHIDElementGetUsagePage(element))-\(IOHIDElementGetUsage(element))-\(IOHIDElementGetCookie(element))"
    }
    private func connected(_ device: IOHIDDevice) {
        func property(_ key: String) -> String { IOHIDDeviceGetProperty(device, key as CFString).map { String(describing: $0) } ?? "" }
        let serial = property(kIOHIDSerialNumberKey)
        let id = [property(kIOHIDVendorIDKey), property(kIOHIDProductIDKey), serial.isEmpty ? property(kIOHIDLocationIDKey) : serial].joined(separator: ":")
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        let channels = elements.compactMap { element -> USBChannel? in
            let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
            guard (page == 1 && (0x30...0x38).contains(usage)) || page == 9 else { return nil }
            let minimum = Double(IOHIDElementGetLogicalMin(element)), maximum = Double(IOHIDElementGetLogicalMax(element))
            guard maximum > minimum else { return nil }
            let id = channelID(element)
            let names: [UInt32: String] = [0x30:"X", 0x31:"Y", 0x32:"Z", 0x33:"Rx", 0x34:"Ry", 0x35:"Rz", 0x36:"Slider", 0x37:"Dial", 0x38:"Wheel"]
            return USBChannel(id: id, name: page == 9 ? "Кнопка \(usage)" : (names[usage] ?? "Ось \(usage)"), minimum: minimum, maximum: maximum, isButton: page == 9)
        }.sorted { $0.id < $1.id }
        deviceKeys[ObjectIdentifier(device)] = id
        // Seed every channel before the first input event, including untouched throttle and switches.
        for element in elements {
            let channel = channelID(element)
            guard channels.contains(where: { $0.id == channel }) else { continue }
            withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { buffer in
                if IOHIDDeviceGetValue(device, element, buffer.baseAddress!) == kIOReturnSuccess {
                    rawValues[id, default: [:]][channel] = Double(IOHIDValueGetIntegerValue(buffer[0].takeUnretainedValue()))
                }
            }
        }
        devices.removeAll { $0.id == id }
        if selectedDeviceID == id { suppressButtonEdgesOnce = true }
        devices.append(USBDevice(id: id, name: property(kIOHIDProductKey).isEmpty ? "USB Joystick" : property(kIOHIDProductKey), channels: channels))
        values = rawValues
    }
    private func disconnected(_ device: IOHIDDevice) {
        guard let id = deviceKeys.removeValue(forKey: ObjectIdentifier(device)) else { return }
        devices.removeAll { $0.id == id }; rawValues.removeValue(forKey: id); values = rawValues
        if selectedDeviceID == id { previousButtons.removeAll(); pendingDisconnectDisarm = true }
    }
    private func received(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let id = deviceKeys[ObjectIdentifier(device)] else { return }
        rawValues[id, default: [:]][channelID(element)] = Double(IOHIDValueGetIntegerValue(value))
    }
    func save(_ configuration: USBDeviceConfiguration, for id: String) throws {
        try configuration.validate(); configurations[id] = configuration; persist()
    }
    func replaceConfigurations(_ configurations: [String: USBDeviceConfiguration]) { self.configurations = configurations; previousButtons.removeAll(); persist() }
    func importConfigurations(_ configurations: [String: USBDeviceConfiguration], selectedID: String?) {
        var imported = configurations
        var selection = selectedID ?? ""
        // A transmitter without a serial number receives a different location ID in another USB port.
        if !selection.isEmpty, !devices.contains(where: { $0.id == selection }), let saved = configurations[selection] {
            let family = selection.split(separator: ":").prefix(2)
            let candidates = devices.filter {
                $0.id.split(separator: ":").prefix(2).elementsEqual(family) && $0.name == saved.deviceName
            }
            if candidates.count == 1 {
                selection = candidates[0].id
                imported[selection] = saved
            }
        }
        replaceConfigurations(imported)
        selectedDeviceID = selection
    }
    private func persist() { if let data = try? JSONEncoder().encode(configurations) { defaults.set(data, forKey: "input.usb.calibrations.v1") } }
    func normalizedAxes(deviceID: String? = nil, configuration: USBDeviceConfiguration? = nil) -> [ControllerAxisFunction: Double] {
        let id = deviceID ?? selectedDeviceID
        guard let configuration = configuration ?? configurations[id] else { return [:] }
        var output: [ControllerAxisFunction: Double] = [:]
        for function in ControllerAxisFunction.allCases {
            guard let assignment = configuration.axes[function.rawValue], let c = configuration.calibration[assignment.channel],
                  let raw = rawValues[id]?[assignment.channel] else { continue }
            output[function] = c.normalized(raw, inverted: assignment.inverted, deadzone: function == .throttle ? 0 : assignment.deadzone)
        }
        return output
    }
    #if DEBUG
    func injectReportsForTesting(device: USBDevice, values: [String: Double], disconnected: Bool = false) {
        if disconnected { devices = []; rawValues = [:]; self.values = [:]; pendingDisconnectDisarm = true; return }
        if devices.isEmpty { devices = [device]; suppressButtonEdgesOnce = true }
        rawValues[device.id] = values; self.values = rawValues
    }
    #endif

    /// A selected USB controller owns this source even while unplugged: no surprise fallback to another device.
    var isRewindHeld: Bool {
        guard !isCalibrating, let device = devices.first(where: { $0.id == selectedDeviceID }),
              let configuration = configurations[selectedDeviceID], (try? configuration.validate()) != nil else { return false }
        return device.channels.contains { channel in
            channel.isButton && configuration.buttons[channel.id] == .rewind
                && (rawValues[selectedDeviceID]?[channel.id] ?? channel.minimum) > (channel.minimum + channel.maximum) / 2
        }
    }
    func inputSnapshot(rates: ControllerRateProfile) -> InputSnapshot? {
        guard !selectedDeviceID.isEmpty else { return nil }
        guard !isCalibrating, let device = devices.first(where: { $0.id == selectedDeviceID }),
              let configuration = configurations[selectedDeviceID], (try? configuration.validate()) != nil else {
            var neutral = InputSnapshot.neutral(source: .gameController)
            if pendingDisconnectDisarm { neutral.actions = [.disarmAircraft]; pendingDisconnectDisarm = false }
            return neutral
        }
        let axes = normalizedAxes()
        guard ControllerAxisFunction.flightAxes.allSatisfy({ axes[$0] != nil }) else {
            return InputSnapshot.neutral(source: .gameController)
        }
        var result = InputSnapshot.neutral(source: .gameController, isConnected: true)
        result.yaw = rates.yaw.command(axes[.yaw] ?? 0); result.pitch = rates.pitch.command(axes[.pitch] ?? 0)
        result.roll = rates.roll.command(axes[.roll] ?? 0)
        result.throttle = axes[.throttle] ?? 0
        if configuration.throttleMode == .absolute { result.absoluteThrottle = rates.throttle.shaped((result.throttle + 1) / 2) }
        result.cameraPan = axes[.cameraPan] ?? 0; result.cameraTilt = axes[.cameraTilt] ?? 0
        var pressed = Set<String>()
        for channel in device.channels where channel.isButton {
            guard (rawValues[selectedDeviceID]?[channel.id] ?? channel.minimum) > (channel.minimum + channel.maximum) / 2 else { continue }
            pressed.insert(channel.id)
            if !previousButtons.contains(channel.id), let action = configuration.buttons[channel.id], action != .rewind { result.actions.append(action.inputAction) }
        }
        for channel in previousButtons.subtracting(pressed) where configuration.buttons[channel] == .armSwitch {
            result.actions.append(.disarmAircraft)
        }
        if suppressButtonEdgesOnce { result.actions.removeAll(); suppressButtonEdgesOnce = false }
        previousButtons = pressed
        // Absolute throttle sources stay dominant at idle and at centre, as the existing GC provider does.
        if pendingDisconnectDisarm { result.actions.append(.disarmAircraft); pendingDisconnectDisarm = false }
        result.activityScore = max(0.06, abs(result.yaw) + abs(result.pitch) + abs(result.roll) + abs(result.throttle))
        return result
    }
}
