import Foundation
import SwiftUI

enum ControlProfileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct KeyboardProfileEntry: Codable {
    var command: String
    var keyCode: UInt16
    var keyLabel: String
    var requiresShift: Bool
}

struct ControlProfile: Codable, Identifiable {
    var version = 1
    var id = UUID()
    var name: String
    var keyboard: [KeyboardProfileEntry]
    var controller: PersistedControllerSettings
    var usb: [String: USBDeviceConfiguration]
    var usbDeviceID: String? = nil

    func validate() throws {
        guard version == 1 else { throw ControlProfileError.invalid("Неподдерживаемая версия раскладки") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              keyboard.count == KeyboardCommand.allCases.count else {
            throw ControlProfileError.invalid("Неполная раскладка клавиатуры")
        }
        var commands = Set<String>(), chords = Set<String>()
        for entry in keyboard {
            guard KeyboardCommand(rawValue: entry.command) != nil, commands.insert(entry.command).inserted,
                  entry.keyCode <= 127 || entry.keyCode == .max else { throw ControlProfileError.invalid("Некорректная клавиша") }
            if entry.keyCode != .max {
                guard ![30, 33, 34, 40].contains(entry.keyCode) else { throw ControlProfileError.invalid("Клавиша зарезервирована интерфейсом") }
                guard chords.insert("\(entry.keyCode):\(entry.requiresShift)").inserted else {
                    throw ControlProfileError.invalid("Несколько команд назначены на одну клавишу")
                }
            }
        }
        try ControllerSettingsStore.validateConfiguration(controller)
        guard usb.count <= 64 else { throw ControlProfileError.invalid("Слишком много USB-профилей") }
        for configuration in usb.values { try configuration.validate() }
    }
}

struct ControlProfilesView: View {
    @ObservedObject var bindings: BindingsViewModel
    @State private var name = "Моя раскладка"
    @State private var saved: [ControlProfile] = []
    @State private var message: String?
    private static let key = "input.controlProfiles.v1"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сохранённые раскладки").font(.headline)
            Text("Клавиатура, оси, кривые, кнопки и калибровка USB сохраняются вместе.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Название", text: $name)
                Button("Сохранить") { perform {
                    let profile = makeProfile(); try profile.validate()
                    saved.removeAll { $0.name == profile.name }; saved.append(profile); persist()
                }}
                Button("Импорт JSON") { perform {
                    guard let data = try SettingsFileIO.read() else { return }
                    let profile = try JSONDecoder().decode(ControlProfile.self, from: data)
                    try profile.validate(); apply(profile)
                    saved.removeAll { $0.id == profile.id }; saved.append(profile); persist()
                    message = "Раскладка «\(profile.name)» импортирована"
                }}
                Button("Экспорт") { perform {
                    let profile = makeProfile(); try profile.validate()
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try SettingsFileIO.export(encoder.encode(profile), name: "UAVsim-controls.json")
                }}
            }
            ForEach(saved) { profile in
                HStack {
                    Text(profile.name); Spacer()
                    Button("Применить") { perform { try profile.validate(); apply(profile); message = "Раскладка применена" }}
                    Button(role: .destructive) { saved.removeAll { $0.id == profile.id }; persist() } label: { Image(systemName: "trash") }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { saved = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([ControlProfile].self, from: $0) } ?? [] }
    }
    private func makeProfile() -> ControlProfile {
        ControlProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), keyboard: bindings.exportKeyboard(),
                       controller: ControllerSettingsStore.shared.exportConfiguration(), usb: USBControllerStore.shared.configurations, usbDeviceID: USBControllerStore.shared.selectedDeviceID)
    }
    private func apply(_ profile: ControlProfile) {
        // Entire file was validated before any preferences are changed.
        bindings.importKeyboard(profile.keyboard)
        ControllerSettingsStore.shared.applyConfiguration(profile.controller)
        USBControllerStore.shared.importConfigurations(profile.usb, selectedID: profile.usbDeviceID)
    }
    private func persist() { if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) } }
    private func perform(_ block: () throws -> Void) { do { try block() } catch { message = error.localizedDescription } }
}
