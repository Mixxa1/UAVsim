import Foundation

// How a gamepad's sticks and triggers reach the aircraft.
//
// The mapping used to be hard-coded and, by the standards of any RC transmitter, wrong: the left
// stick flew pitch and roll, the right stick's vertical axis did nothing at all, throttle lived on
// the triggers, and the UI cursor was wired to the same stick as the flight controls — so the
// pointer crept across the screen for as long as the operator was flying. Every one of those is a
// binding now, and the default is the layout most pilots already have in their hands.

// MARK: - Physical axes

/// An axis a controller can actually offer. `triggerPair` and `shoulderPair` fold two unidirectional
/// controls into one signed axis, which is how throttle used to work and still can.
enum ControllerAxisSource: String, Codable, CaseIterable, Identifiable {
    case none
    case leftStickX
    case leftStickY
    case rightStickX
    case rightStickY
    case leftTrigger
    case rightTrigger
    case triggerPair
    case shoulderPair
    case dpadX
    case dpadY

    var id: String { rawValue }
    var titleKey: String { "controller.axis.source.\(rawValue)" }

    /// Whether this source rests at zero and returns there. A stick does; a single trigger does
    /// too, but only from one side, which is why an absolute throttle wants a stick.
    var isBidirectional: Bool {
        switch self {
        case .leftTrigger, .rightTrigger, .none: return false
        default: return true
        }
    }

    var isStick: Bool {
        switch self {
        case .leftStickX, .leftStickY, .rightStickX, .rightStickY: return true
        default: return false
        }
    }
}

/// What an axis can drive. Deliberately includes the UI cursor: giving it a binding of its own is
/// what stops a flight stick from dragging the pointer around.
enum ControllerAxisFunction: String, Codable, CaseIterable, Identifiable {
    case throttle
    case yaw
    case pitch
    case roll
    case cameraPan
    case cameraTilt
    case cursorX
    case cursorY

    var id: String { rawValue }
    var titleKey: String { "controller.axis.function.\(rawValue)" }

    /// The four that fly the aircraft. Everything else is a convenience.
    static let flightAxes: [ControllerAxisFunction] = [.throttle, .yaw, .pitch, .roll]
}

// MARK: - One binding

struct ControllerAxisBinding: Codable, Equatable {
    var source: ControllerAxisSource
    /// Flips the axis. Needed because a gamepad's Y axes read positive-down and because half the
    /// world flies with reversed elevator.
    var isInverted: Bool
    /// Fraction of travel around centre that reads as zero. A worn stick that rests off-centre is
    /// the difference between an aircraft that holds attitude and one that slowly rolls away.
    ///
    /// The only shaping that belongs here. Expo and rates describe how the operator wants to fly,
    /// not what their hardware is, and live in `ControllerRateProfile` where a pilot expects to
    /// find them — two expo sliders in two places is how a control setup becomes unexplainable.
    var deadzone: Double

    init(
        source: ControllerAxisSource,
        isInverted: Bool = false,
        deadzone: Double = 0.06
    ) {
        self.source = source
        self.isInverted = isInverted
        self.deadzone = deadzone
    }

    static let unbound = ControllerAxisBinding(source: .none)

    /// Applies the dead zone and inversion to a raw −1…1 reading. The travel outside the dead
    /// zone is rescaled rather than truncated, so the stick still reaches its ends.
    func apply(to raw: Double) -> Double {
        guard source != .none else { return 0 }
        let clamped = min(1, max(-1, raw))
        let magnitude = abs(clamped)
        let zone = min(0.45, max(0, deadzone))
        guard magnitude > zone else { return 0 }
        let rescaled = (magnitude - zone) / (1 - zone)
        let signed = clamped < 0 ? -rescaled : rescaled
        return isInverted ? -signed : signed
    }
}

// MARK: - The whole map

/// Stick layouts named the way transmitters name them. They are starting points, not a straitjacket:
/// every axis stays individually rebindable afterwards.
enum ControllerStickMode: String, Codable, CaseIterable, Identifiable {
    case mode1
    case mode2
    case mode3
    case mode4
    /// Anything that is not one of the four any more.
    case custom

    var id: String { rawValue }
    var titleKey: String { "controller.stick_mode.\(rawValue)" }
    var summaryKey: String { "controller.stick_mode.\(rawValue).summary" }
}

/// How the throttle axis is read.
enum ControllerThrottleMode: String, Codable, CaseIterable, Identifiable {
    /// Stick position *is* the throttle: bottom is zero, top is full. What a transmitter does, and
    /// what the operator expects the moment throttle lives on a stick.
    case absolute
    /// The axis adds to and subtracts from the current setting, which is how the keyboard and the
    /// triggers have always worked and the only thing that makes sense for a self-centring control
    /// that is not a throttle stick.
    case rate

    var id: String { rawValue }
    var titleKey: String { "controller.throttle_mode.\(rawValue)" }
}

struct ControllerAxisMap: Codable, Equatable {
    var bindings: [ControllerAxisFunction: ControllerAxisBinding]
    var throttleMode: ControllerThrottleMode

    init(
        bindings: [ControllerAxisFunction: ControllerAxisBinding],
        throttleMode: ControllerThrottleMode = .absolute
    ) {
        self.bindings = bindings
        self.throttleMode = throttleMode
    }

    func binding(for function: ControllerAxisFunction) -> ControllerAxisBinding {
        bindings[function] ?? .unbound
    }

    mutating func setBinding(_ binding: ControllerAxisBinding, for function: ControllerAxisFunction) {
        bindings[function] = binding
    }

    /// Functions sharing one physical axis. Not forbidden — pitch on the same axis as the cursor is
    /// harmless while the cursor is hidden — but the settings screen says so, because a genuine
    /// double-booking of two flight axes is unflyable and never intentional.
    var conflicts: [ControllerAxisSource: [ControllerAxisFunction]] {
        var byAxis: [ControllerAxisSource: [ControllerAxisFunction]] = [:]
        for function in ControllerAxisFunction.allCases {
            let source = binding(for: function).source
            guard source != .none else { continue }
            byAxis[source, default: []].append(function)
        }
        return byAxis.filter { $0.value.count > 1 }
    }

    var conflictingFlightAxes: Bool {
        conflicts.values.contains { functions in
            functions.filter(ControllerAxisFunction.flightAxes.contains).count > 1
        }
    }

    /// Which named layout this is, if any.
    var stickMode: ControllerStickMode {
        for mode in [ControllerStickMode.mode1, .mode2, .mode3, .mode4]
        where Self.preset(mode).flightBindingsMatch(self) {
            return mode
        }
        return .custom
    }

    private func flightBindingsMatch(_ other: ControllerAxisMap) -> Bool {
        ControllerAxisFunction.flightAxes.allSatisfy {
            binding(for: $0).source == other.binding(for: $0).source
                && binding(for: $0).isInverted == other.binding(for: $0).isInverted
        }
    }

    // MARK: Presets

    /// The four transmitter layouts. In all of them the vertical stick axes are inverted, because a
    /// gamepad reports "stick pushed forward" as negative and every one of these wants forward to
    /// mean more.
    static func preset(_ mode: ControllerStickMode) -> ControllerAxisMap {
        let throttleAxis: ControllerAxisSource
        let yawAxis: ControllerAxisSource
        let pitchAxis: ControllerAxisSource
        let rollAxis: ControllerAxisSource
        switch mode {
        case .mode1, .custom:
            throttleAxis = .rightStickY
            yawAxis = .leftStickX
            pitchAxis = .leftStickY
            rollAxis = .rightStickX
        case .mode2:
            throttleAxis = .leftStickY
            yawAxis = .leftStickX
            pitchAxis = .rightStickY
            rollAxis = .rightStickX
        case .mode3:
            throttleAxis = .rightStickY
            yawAxis = .rightStickX
            pitchAxis = .leftStickY
            rollAxis = .leftStickX
        case .mode4:
            throttleAxis = .leftStickY
            yawAxis = .rightStickX
            pitchAxis = .rightStickY
            rollAxis = .leftStickX
        }
        return ControllerAxisMap(
            bindings: [
                .throttle: ControllerAxisBinding(source: throttleAxis, deadzone: 0.05),
                .yaw: ControllerAxisBinding(source: yawAxis, deadzone: 0.08),
                .pitch: ControllerAxisBinding(source: pitchAxis, isInverted: true, deadzone: 0.06),
                .roll: ControllerAxisBinding(source: rollAxis, deadzone: 0.06),
                // The two sticks are spoken for. Camera and cursor are left for the operator to
                // place — on the triggers, the D-pad, or nowhere — rather than quietly stealing an
                // axis the aircraft needs.
                .cameraPan: .unbound,
                .cameraTilt: .unbound,
                .cursorX: ControllerAxisBinding(source: .dpadX, deadzone: 0.2),
                .cursorY: ControllerAxisBinding(source: .dpadY, isInverted: true, deadzone: 0.2)
            ],
            throttleMode: .absolute
        )
    }

    /// Mode 2: left stick is throttle and yaw, right stick is pitch and roll. The layout most
    /// pilots already fly, and the one this simulator now starts in.
    static let `default` = preset(.mode2)
}
