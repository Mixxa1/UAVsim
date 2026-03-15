import SwiftUI

struct AbstractModelEditorView: View {
    let initial: AbstractDroneParameters
    let onSave: (AbstractDroneParameters) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var massKg: Double
    @State private var dimX: Double
    @State private var dimY: Double
    @State private var dimZ: Double
    @State private var batteryWh: Double
    @State private var maxSpeed: Double
    @State private var maxAscent: Double
    @State private var maxDescent: Double
    @State private var windResistance: Double
    @State private var responsiveness: Double
    @State private var collisionRadius: Double

    init(initial: AbstractDroneParameters, onSave: @escaping (AbstractDroneParameters) -> Void) {
        self.initial = initial
        self.onSave = onSave

        _massKg = State(initialValue: Double(initial.massKg))
        _dimX = State(initialValue: Double(initial.unfoldedMm.x))
        _dimY = State(initialValue: Double(initial.unfoldedMm.y))
        _dimZ = State(initialValue: Double(initial.unfoldedMm.z))
        _batteryWh = State(initialValue: Double(initial.batteryEnergyWh))
        _maxSpeed = State(initialValue: Double(initial.maxHorizontalSpeedMps))
        _maxAscent = State(initialValue: Double(initial.maxAscentSpeedMps))
        _maxDescent = State(initialValue: Double(initial.maxDescentSpeedMps))
        _windResistance = State(initialValue: Double(initial.maxWindResistanceMps))
        _responsiveness = State(initialValue: Double(initial.controlResponsiveness))
        _collisionRadius = State(initialValue: Double(initial.collisionRadiusMeters))
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("abstract.editor.title")
                .font(.title3.weight(.semibold))

            Form {
                Section("abstract.editor.mass") {
                    SliderWithValue(value: $massKg, range: 0.10...5.0, step: 0.01, suffix: "kg")
                }

                Section("abstract.editor.dimensions") {
                    SliderWithValue(value: $dimX, range: 120...900, step: 1, suffix: "mm", label: "X")
                    SliderWithValue(value: $dimY, range: 120...900, step: 1, suffix: "mm", label: "Y")
                    SliderWithValue(value: $dimZ, range: 40...400, step: 1, suffix: "mm", label: "Z")
                }

                Section("abstract.editor.energy") {
                    SliderWithValue(value: $batteryWh, range: 8...220, step: 0.5, suffix: "Wh")
                    SliderWithValue(value: $maxSpeed, range: 3...42, step: 0.1, suffix: "m/s", label: "Vh")
                    SliderWithValue(value: $maxAscent, range: 1...18, step: 0.1, suffix: "m/s", label: "Asc")
                    SliderWithValue(value: $maxDescent, range: 1...18, step: 0.1, suffix: "m/s", label: "Desc")
                    SliderWithValue(value: $windResistance, range: 2...22, step: 0.1, suffix: "m/s", label: "Wind")
                }

                Section("abstract.editor.control") {
                    SliderWithValue(value: $responsiveness, range: 0.2...1.0, step: 0.01, suffix: "", label: "Ctrl")
                    SliderWithValue(value: $collisionRadius, range: 0.12...1.20, step: 0.01, suffix: "m")
                }
            }

            if let error = validationError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("common.cancel") {
                    dismiss()
                }

                Spacer()

                Button("common.save") {
                    onSave(buildParameters())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(validationError != nil)
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 520)
    }

    private var validationError: String? {
        if maxAscent < 0.8 || maxDescent < 0.8 {
            return String(localized: "abstract.validation.vertical")
        }
        if maxSpeed < max(maxAscent, maxDescent) {
            return String(localized: "abstract.validation.speed")
        }
        if collisionRadius > (max(dimX, dimY) / 1000.0) {
            return String(localized: "abstract.validation.radius")
        }
        return nil
    }

    private func buildParameters() -> AbstractDroneParameters {
        AbstractDroneParameters(
            massKg: Float(massKg),
            unfoldedMm: DroneDimensionsMM(x: Float(dimX), y: Float(dimY), z: Float(dimZ)),
            batteryEnergyWh: Float(batteryWh),
            maxHorizontalSpeedMps: Float(maxSpeed),
            maxAscentSpeedMps: Float(maxAscent),
            maxDescentSpeedMps: Float(maxDescent),
            maxWindResistanceMps: Float(windResistance),
            controlResponsiveness: Float(responsiveness),
            collisionRadiusMeters: Float(collisionRadius)
        )
    }
}

private struct SliderWithValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    var label: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(valueString)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range, step: step)
        }
    }

    private var valueString: String {
        if suffix.isEmpty {
            return String(format: "%.2f", value)
        }
        return String(format: "%.2f %@", value, suffix)
    }
}
