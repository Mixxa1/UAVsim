import SwiftUI

/// Preflight setup for a flight mission: pick a scenario, edit its parameters, choose the UAV
/// and payload, then start. Builds a `MissionScenarioConfiguration` handed to the simulation.
struct MissionSetupView: View {
    let availableProfiles: [DroneModelProfile]
    let onCancel: () -> Void
    let onStart: (MissionScenarioConfiguration) -> Void

    @State private var kind: MissionScenarioKind = .searchAndRescue
    @State private var difficulty: MissionDifficulty = .medium
    @State private var terrain: TerrainPreset = .forest
    @State private var terrainDensity: MissionTerrainDensity = .dense
    @State private var weather: WeatherPreset = .normal
    @State private var weatherIntensity: Double = 0.3
    @State private var timeOfDay: TimeOfDay = .day
    @State private var timeLimitMinutes: Int = MissionDifficulty.medium.defaultTimeLimitMinutes
    @State private var selectedProfileID: String = ""
    @State private var payload: PayloadType = .thermalCamera
    @State private var hoseDiameterClass: FireHoseDiameterClass = .standard
    @State private var hoseLengthMeters: Double = 30.0
    @State private var capsuleSize: FireCapsuleSize = .medium
    @State private var capsuleCount: Int = 2
    @State private var raceMode: RaceMode = .timed
    @State private var raceLaps: Int = 3
    @State private var raceTrackSource: RaceTrackSource = .generated
    @State private var raceLibrary: [RaceTrackStore.Summary] = []
    @State private var selectedRaceTrackID: UUID?
    @State private var interception = InterceptMissionConfiguration()
    @State private var aircraftPickerSlot: AircraftSlot?

    /// One of the three aircraft an interception run puts in the air.
    enum AircraftSlot: String, Identifiable {
        case player
        case target
        case observer

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .player: return "mission.setup.uav"
            case .target: return "intercept.target.profile"
            case .observer: return "intercept.observer.profile"
            }
        }
    }

    /// One height for every scenario chip, so the grid reads as a row of buttons rather than a
    /// set of differently-sized boxes.
    private static let scenarioChipHeight: CGFloat = 46

    /// Where the track for a racing mission comes from.
    private enum RaceTrackSource: String, CaseIterable, Identifiable {
        /// Laid out from the mission seed, sized by difficulty.
        case generated
        /// One the pilot built and saved earlier.
        case library
        /// Nothing at all: fly into an empty world and build the track there.
        case empty

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .generated: return "race.setup.source.generated"
            case .library: return "race.setup.source.library"
            case .empty: return "race.setup.source.empty"
            }
        }
    }

    /// UAV profiles that can actually carry `payload`'s mass (and stay within max takeoff mass) —
    /// without this, picking a heavy payload (e.g. the fire hose) against the default/first
    /// profile could silently fail to attach, leaving the operator stuck looking at a fallback
    /// camera with no visible cause. For the fire hose, the *rigged* mass (length × diameter
    /// class) is what matters, not the flat default — so the picker narrows live as the operator
    /// drags the length slider.
    private var compatibleProfiles: [DroneModelProfile] {
        // Racing mounts nothing, so no aircraft is excluded for being unable to carry it — the
        // pilot may fly a whoop, a Matrice or their own Workbench build through the gates.
        guard kind.requiresPayload else { return availableProfiles }
        var configuration = PayloadConfiguration(payloadType: payload)
        if payload == .fireHose {
            configuration.payloadMass = hoseDiameterClass.massForLength(Float(hoseLengthMeters))
        } else if payload == .fireCapsuleLauncher {
            configuration.payloadMass = FireCapsuleTuning.totalMass(size: capsuleSize, count: capsuleCount)
        }
        return availableProfiles.filter { canCarry(payloadConfiguration: configuration, profile: $0) }
    }

    private func canCarry(payloadConfiguration: PayloadConfiguration, profile: DroneModelProfile) -> Bool {
        guard let uav = profile.resolvedUAVProfile else { return true }
        return PayloadController.capabilityCheck(for: payloadConfiguration, profile: uav).isAllowed
    }

    private func canCarrySelectedPayload(_ profile: DroneModelProfile) -> Bool {
        guard kind.requiresPayload else { return true }
        return canCarry(payloadConfiguration: currentPayloadConfiguration, profile: profile)
    }

    private var currentPayloadConfiguration: PayloadConfiguration {
        var configuration = PayloadConfiguration(payloadType: payload)
        if payload == .fireHose {
            configuration.payloadMass = hoseDiameterClass.massForLength(Float(hoseLengthMeters))
        } else if payload == .fireCapsuleLauncher {
            configuration.payloadMass = FireCapsuleTuning.totalMass(size: capsuleSize, count: capsuleCount)
        }
        return configuration
    }

    /// Everything the operator could fly, with the aircraft that can carry the chosen payload
    /// first and the rest still listed underneath.
    ///
    /// A Workbench build is a real aircraft with real numbers, so a light one genuinely fails the
    /// payload check — but silently deleting it from the picker is how "I cannot find the drone I
    /// built" happens. The card says why instead, and the choice stays the operator's.
    private var playerPickerProfiles: [DroneModelProfile] {
        let compatible = Set(compatibleProfiles.map(\.id))
        return availableProfiles.sorted { lhs, rhs in
            let lhsOK = compatible.contains(lhs.id)
            let rhsOK = compatible.contains(rhs.id)
            return lhsOK == rhsOK ? lhs.uiDisplayName < rhs.uiDisplayName : lhsOK
        }
    }

    private var resolvedProfile: DroneModelProfile? {
        compatibleProfiles.first { $0.id == selectedProfileID } ?? compatibleProfiles.first
    }

    /// Resolves a live-preview-ready `UAVProfile` for a card, including the one entry
    /// (`DroneModelProfile.abstractProfile`) whose `resolvedUAVProfile` is nil because it never sets
    /// `uavProfileID` — falls back to `UAVReferenceCatalog.abstractProfile(from:)`, a different
    /// function that does build a real (if generic) `UAVProfile`, so that card still rotates a
    /// placeholder airframe instead of showing a blank preview.
    private func previewProfile(for profile: DroneModelProfile) -> UAVProfile? {
        profile.resolvedUAVProfile
            ?? (profile.isAbstract ? UAVReferenceCatalog.abstractProfile(from: .default) : nil)
    }

    private func profileBadgeText(for profile: DroneModelProfile) -> String {
        if profile.isAbstract {
            return NSLocalizedString("uav.badge.custom", comment: "")
        }
        return (profile.resolvedUAVProfile?.specConfidence ?? .partial).catalogTitle.uppercased()
    }

    private func profileBadgeTint(for profile: DroneModelProfile) -> Color {
        if profile.isAbstract {
            return .orange
        }
        switch profile.resolvedUAVProfile?.specConfidence ?? .partial {
        case .verified:
            return .green
        case .partial:
            return .yellow
        case .custom:
            return .orange
        }
    }

    private var compatiblePayloads: [PayloadType] {
        kind.compatiblePayloads
    }

    private var payloadHintKey: String {
        switch kind {
        case .attachedPayloadIntercept:
            return "intercept.payload.hint"
        case .searchAndRescue:
            return "mission.setup.payload.hint"
        case .fireResponse:
            return "mission.setup.payload.hint.fire_response"
        case .agriculturalSpraying:
            return "mission.setup.payload.hint.agricultural_spraying"
        case .droneRacing:
            return "mission.setup.payload.hint.drone_racing"
        }
    }

    /// Time budget for the selected scenario at the selected difficulty. Agricultural spraying is
    /// paced by water logistics — several tank loads plus the trips back to the canisters — so it
    /// gets its own, much longer default than the search/fire scenarios.
    private func defaultTimeLimit(for kind: MissionScenarioKind, difficulty: MissionDifficulty) -> Int {
        kind == .agriculturalSpraying
            ? difficulty.agriDefaultTimeLimitMinutes
            : difficulty.defaultTimeLimitMinutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scenarioSection
                    platformSection
                }
                .padding(20)
            }

            footer
        }
        .frame(maxWidth: 720, maxHeight: 720)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .sheet(item: $aircraftPickerSlot) { slot in
            aircraftPickerSheet(slot)
        }
        .onAppear {
            if selectedProfileID.isEmpty {
                selectedProfileID = availableProfiles.first?.id ?? ""
            }
            if !compatiblePayloads.contains(payload) {
                payload = compatiblePayloads.first ?? .thermalCamera
            }
            if !compatibleProfiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = compatibleProfiles.first?.id ?? ""
            }
            applyInterceptDifficulty(difficulty)
            resolveInterceptProfiles()
        }
        .onChange(of: kind) { _, newValue in
            if !compatiblePayloads.contains(payload) {
                payload = compatiblePayloads.first ?? .thermalCamera
            }
            // `.dense` (the default above) is tuned for SAR — a genuinely hard-to-search forest is
            // the point there (see ScenePopulationService/generateForest's own reasoning). Fire
            // Response doesn't share that justification: its fire zone already gets its own
            // dedicated, guaranteed tree population from spawnFireResponseScenario, so the ambient
            // forest across the rest of the map is purely decorative here — maxing it out too adds
            // real rendering/shadow cost (confirmed via a user's Debug log: `.dense` alone produced
            // ~917 ambient trees map-wide) without a corresponding gameplay benefit. Default to
            // `.medium` when switching into this scenario kind instead.
            if newValue == .fireResponse {
                terrainDensity = .medium
            }
            // A crop field is open ground by definition: the ambient forest is scenery on the
            // horizon here, and trees standing *in* the field would be both wrong to look at and
            // a genuine hazard on the 2-5 m passes this mission is flown at.
            if newValue == .agriculturalSpraying {
                terrain = .field
                terrainDensity = .sparse
            }
            // A race course needs clear air between the gates: the ambient forest is scenery on
            // the horizon here, not something to thread a quad through at 30 m/s.
            if newValue == .droneRacing {
                terrain = .field
                terrainDensity = .sparse
                raceLibrary = RaceTrackStore.list()
                if selectedRaceTrackID == nil {
                    selectedRaceTrackID = raceLibrary.first?.id
                }
            }
            // An interception is flown in open air between three aircraft: the ambient forest is
            // horizon scenery, and a dense one only puts obstacles between the observer and the
            // thing it is supposed to be watching.
            if newValue == .attachedPayloadIntercept {
                terrainDensity = .sparse
                resolveInterceptProfiles()
            }
            timeLimitMinutes = defaultTimeLimit(for: newValue, difficulty: difficulty)
        }
        .onChange(of: payload) { _, _ in
            if !compatibleProfiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = compatibleProfiles.first?.id ?? ""
            }
        }
        .onChange(of: hoseDiameterClass) { _, newValue in
            hoseLengthMeters = Double(Float(hoseLengthMeters).clamped(to: newValue.lengthRangeMeters))
            if !compatibleProfiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = compatibleProfiles.first?.id ?? ""
            }
        }
        .onChange(of: hoseLengthMeters) { _, _ in
            if !compatibleProfiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = compatibleProfiles.first?.id ?? ""
            }
        }
        .onChange(of: capsuleSize) { _, _ in
            if !compatibleProfiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = compatibleProfiles.first?.id ?? ""
            }
        }
        .onChange(of: capsuleCount) { _, _ in
            if !compatibleProfiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = compatibleProfiles.first?.id ?? ""
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("mission.setup.title")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("mission.setup.subtitle")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white.opacity(0.04))
    }

    /// Scenario picker + description, with that scenario's parameters opening directly below it in
    /// the same card — picking a mission and immediately seeing (and tuning) its own parameters
    /// reads more practical than a disconnected "Parameters" card further down the screen.
    private var scenarioSection: some View {
        sectionCard(titleKey: "mission.setup.section.scenario") {
            VStack(alignment: .leading, spacing: 14) {
                scenarioChooser

                HStack(spacing: 12) {
                    Image(systemName: kind.iconSystemName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(kind.titleKey))
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(LocalizedStringKey(kind.subtitleKey))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                }

                Divider().overlay(Color.white.opacity(0.12))

                Text("mission.setup.section.parameters")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))

                parametersFields
            }
            .animation(.easeInOut(duration: 0.2), value: kind)
        }
    }

    /// A wrapping grid of chips rather than a segmented control. A segmented control divides the
    /// available width equally and refuses to go below its content's intrinsic width, so a
    /// scenario with a long name pushed the whole card wider than the dialog and everything
    /// inside it sat visibly off-centre. Chips wrap onto a second row instead.
    private var scenarioChooser: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168, maximum: 300), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(MissionScenarioKind.allCases) { value in
                Button {
                    kind = value
                } label: {
                    scenarioChip(value)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func scenarioChip(_ value: MissionScenarioKind) -> some View {
        let isSelected = value == kind
        return HStack(spacing: 8) {
            Image(systemName: value.iconSystemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? GroundControlPalette.accent : .white.opacity(0.7))
                .frame(width: 16)
            // Every chip is the same box. A name long enough to wrap shrinks inside it instead of
            // making its whole row taller than the others, which is what left the grid looking
            // like a set of mismatched buttons.
            Text(LocalizedStringKey(value.titleKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Self.scenarioChipHeight, maxHeight: Self.scenarioChipHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? GroundControlPalette.accent.opacity(0.28) : Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? GroundControlPalette.accent : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var parametersFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledRow("mission.setup.difficulty") {
                Picker("", selection: $difficulty) {
                    ForEach(MissionDifficulty.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: difficulty) { _, newValue in
                    timeLimitMinutes = defaultTimeLimit(for: kind, difficulty: newValue)
                    applyInterceptDifficulty(newValue)
                }
            }

            if kind == .agriculturalSpraying {
                agriBriefingRow
            }

            if kind == .droneRacing {
                raceFields
            }

            if kind == .attachedPayloadIntercept {
                interceptFields
            }

            labeledRow("mission.setup.time_of_day") {
                Picker("", selection: $timeOfDay) {
                    ForEach(TimeOfDay.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeledRow("mission.setup.terrain") {
                Picker("", selection: $terrain) {
                    ForEach(TerrainPreset.available(for: resolvedProfile?.airframeClass ?? .multirotor)) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.white)
            }

            labeledRow("mission.setup.terrain_density") {
                Picker("", selection: $terrainDensity) {
                    ForEach(MissionTerrainDensity.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeledRow("mission.setup.weather") {
                Picker("", selection: $weather) {
                    ForEach(WeatherPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("mission.setup.weather_intensity")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.0f%%", weatherIntensity * 100))
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
                Slider(value: $weatherIntensity, in: 0...1, step: 0.01)
            }

            Stepper(value: $timeLimitMinutes, in: 3...30) {
                HStack {
                    Text("mission.setup.time_limit")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: NSLocalizedString("mission.setup.time_limit.value", comment: ""), timeLimitMinutes))
                        .font(.caption.monospacedDigit()).foregroundStyle(.white)
                }
            }
        }
    }

    /// What the chosen difficulty actually costs in water, spelled out before launch: the field's
    /// size, the water it needs at the reference dose, and how many tank loads that is. The
    /// mission's real difficulty knob is the number of trips back to the canisters, and it would
    /// otherwise be invisible until the operator is already airborne with an empty tank.
    private var agriBriefingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(GroundControlPalette.accent)
                Text(String(
                    format: NSLocalizedString("mission.setup.agri.briefing", comment: ""),
                    // The field is square, so its side goes in twice. Passing it once left the
                    // format reading the *next* argument as the second dimension and shifting
                    // everything after it — which is how a 2.56 ha field announced itself as
                    // "160×3 m — 140.80 ha … −318565456 full tanks".
                    difficulty.agriFieldSideMeters,
                    difficulty.agriFieldSideMeters,
                    difficulty.agriFieldAreaHectares,
                    difficulty.agriRequiredLiters,
                    difficulty.agriTankLoads
                ))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(String(
                format: NSLocalizedString("mission.setup.agri.window", comment: ""),
                AgriSprayTuning.idealAltitudeRange.lowerBound,
                AgriSprayTuning.idealAltitudeRange.upperBound,
                AgriSprayTuning.idealMaxGroundSpeed,
                AgriSprayTuning.successCoverageFraction * 100.0
            ))
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Attached payload interception

    /// Aircraft the mission may fly as the target: a multirotor that manoeuvres against the
    /// interceptor, or an aeroplane transiting the area at altitude. Never a tethered one — a
    /// fibre spool has nothing to pay out to on an aircraft nobody is flying.
    private var interceptTargetProfiles: [DroneModelProfile] {
        availableProfiles
            .filter { ($0.airframeClass == .multirotor || $0.airframeClass == .fixedWing) && $0.defaultVideoMode != .fiber }
            .sorted {
                $0.airframeClass == $1.airframeClass
                    ? $0.displayName < $1.displayName
                    : $0.airframeClass == .multirotor
            }
    }

    /// The observer holds a station and watches. Only a rotorcraft can do that, so an aeroplane is
    /// not offered here even though it is a legitimate target.
    private var interceptObserverProfiles: [DroneModelProfile] {
        availableProfiles
            .filter { $0.airframeClass == .multirotor && $0.defaultVideoMode != .fiber }
            .sorted { $0.displayName < $1.displayName }
    }

    /// The three aircraft this mission puts in the air, side by side: the one the operator flies,
    /// the one being intercepted, and the one watching. They belong together — the whole run is
    /// the relationship between them — and each opens its own picker rather than unrolling another
    /// scrolling grid into the middle of the form.
    private var aircraftSlotRow: some View {
        HStack(alignment: .top, spacing: 10) {
            aircraftSlot(.player, titleKey: "mission.setup.uav")
            aircraftSlot(.target, titleKey: "intercept.target.profile")
            aircraftSlot(.observer, titleKey: "intercept.observer.profile")
        }
    }

    private func aircraftSlot(_ slot: AircraftSlot, titleKey: String) -> some View {
        let profile = profiles(for: slot).first { $0.id == selection(for: slot) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption).foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Button {
                aircraftPickerSlot = slot
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    UAVLivePreviewView(
                        profile: profile.flatMap(previewProfile(for:)),
                        runtimeProfile: profile
                    )
                    .frame(height: 84)
                    .background(GroundControlPalette.shell, in: RoundedRectangle(cornerRadius: 8))

                    Text(profile?.uiDisplayName ?? "—")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("mission.setup.aircraft.change")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.accent)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(GroundControlPalette.accent)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The picker itself, in a sheet. One grid, once, instead of three of them stacked inside a
    /// form the operator has to scroll past to reach the start button.
    private func aircraftPickerSheet(_ slot: AircraftSlot) -> some View {
        let list = profiles(for: slot)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizedStringKey(slot.titleKey))
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button("mission.setup.aircraft.done") { aircraftPickerSlot = nil }
                    .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 10)], spacing: 10) {
                    ForEach(list) { profile in
                        Button {
                            select(profile.id, for: slot)
                            aircraftPickerSlot = nil
                        } label: {
                            UAVSelectionCardView(
                                name: profile.uiDisplayName,
                                manufacturer: profile.manufacturer,
                                previewProfile: previewProfile(for: profile),
                                runtimePreviewProfile: profile,
                                massKg: profile.takeoffMassKg,
                                speedMps: profile.resolvedUAVProfile?.nominalCruiseSpeedMps ?? profile.maxHorizontalSpeedMps,
                                flightTimeSec: profile.resolvedUAVProfile?.nominalFlightTimeSec,
                                rangeMeters: profile.resolvedUAVProfile?.nominalMaxRangeM,
                                badgeText: profileBadgeText(for: profile),
                                badgeTint: profileBadgeTint(for: profile),
                                isSelected: profile.id == selection(for: slot)
                            ) {
                                if slot == .player, !canCarrySelectedPayload(profile) {
                                    Text("mission.setup.uav.payload_too_heavy")
                                        .font(.caption2)
                                        .foregroundStyle(GroundControlPalette.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
            }
        }
        .padding(18)
        .frame(width: 720, height: 560)
        .background(GroundControlPalette.shell)
    }

    private func profiles(for slot: AircraftSlot) -> [DroneModelProfile] {
        switch slot {
        case .player: return playerPickerProfiles
        case .target: return interceptTargetProfiles
        case .observer: return interceptObserverProfiles
        }
    }

    private func selection(for slot: AircraftSlot) -> String {
        switch slot {
        case .player: return selectedProfileID
        case .target: return interception.targetProfileID
        case .observer: return interception.observerProfileID
        }
    }

    private func select(_ id: String, for slot: AircraftSlot) {
        switch slot {
        case .player: selectedProfileID = id
        case .target: interception.targetProfileID = id
        case .observer: interception.observerProfileID = id
        }
    }

    private var interceptFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            interceptBriefingRow

            aircraftSlotRow

            if isFixedWingTargetSelected {
                Text("intercept.setup.fixed_wing.hint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            labeledRow("intercept.target.behavior") {
                Picker("", selection: $interception.targetBehavior) {
                    ForEach(InterceptTargetBehavior.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.white)
            }

            labeledRow("intercept.effect.profile") {
                Picker("", selection: $interception.payloadProfile) {
                    ForEach(AttachedPayloadProfile.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeledRow("intercept.confirmation") {
                Picker("", selection: $interception.confirmationPolicy) {
                    ForEach(InterceptConfirmationPolicy.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text(LocalizedStringKey(interception.confirmationPolicy.hintKey))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Toggle("intercept.target.payload", isOn: $interception.targetCarriesPayload)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            if interception.targetCarriesPayload {
                Toggle("intercept.target.inert", isOn: $interception.targetPayloadInert)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                Text("intercept.target.inert.hint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("intercept.setup.hide_ranges", isOn: $interception.hidesRangeReadouts)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Text("intercept.setup.hide_ranges.hint")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the chosen difficulty actually changes, spelled out before launch. The mission has no
    /// visible sector or gate to look at, so without this the difficulty knob would be invisible
    /// until the operator is already airborne wondering why the target keeps slipping away.
    private var interceptBriefingRow: some View {
        let settings = InterceptMissionConfiguration.make(difficulty: difficulty)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .foregroundStyle(GroundControlPalette.accent)
                Text(String(
                    format: NSLocalizedString("intercept.setup.briefing", comment: ""),
                    Double(settings.areaRadius),
                    Double(settings.acquisitionRange)
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(LocalizedStringKey(
                settings.maximumAttempts > 0
                    ? "intercept.setup.attempts_limited"
                    : "intercept.setup.attempts_unlimited"
            ))
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Difficulty owns the geometry and the approach budget; it never overrides the operator's
    /// choice of target behaviour, module effect or confirmation policy.
    private func applyInterceptDifficulty(_ difficulty: MissionDifficulty) {
        let defaults = InterceptMissionConfiguration.make(difficulty: difficulty)
        interception.areaRadius = defaults.areaRadius
        interception.acquisitionRange = defaults.acquisitionRange
        interception.attemptRange = defaults.attemptRange
        interception.targetAgility = defaults.targetAgility
        interception.maximumAttempts = defaults.maximumAttempts
    }

    private var isFixedWingTargetSelected: Bool {
        interceptTargetProfiles.first { $0.id == interception.targetProfileID }?.airframeClass == .fixedWing
    }

    /// The two aircraft have to name something that exists. An empty or stale ID would leave the
    /// list with nothing highlighted and the mission falling back to a generic airframe.
    private func resolveInterceptProfiles() {
        if !interceptTargetProfiles.contains(where: { $0.id == interception.targetProfileID }) {
            interception.targetProfileID = interceptTargetProfiles.first?.id ?? ""
        }
        if !interceptObserverProfiles.contains(where: { $0.id == interception.observerProfileID }) {
            interception.observerProfileID = interceptObserverProfiles.first?.id ?? ""
        }
    }

    // MARK: Drone racing

    /// Racing setup: how the run is scored, how many laps, and where the track comes from.
    @ViewBuilder
    private var raceFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledRow("race.setup.mode") {
                Picker("", selection: $raceMode) {
                    ForEach(RaceMode.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text(LocalizedStringKey(raceMode.subtitleKey))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if raceMode == .timed {
                Stepper(value: $raceLaps, in: 1...10) {
                    HStack {
                        Text("race.setup.laps")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("\(raceLaps)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    }
                }
            }

            labeledRow("race.setup.source") {
                Picker("", selection: $raceTrackSource) {
                    ForEach(RaceTrackSource.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch raceTrackSource {
            case .generated:
                Text("race.setup.source.generated.hint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            case .empty:
                Text("race.setup.source.empty.hint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            case .library:
                if raceLibrary.isEmpty {
                    Text("race.setup.source.library.empty")
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(raceLibrary) { summary in
                            Button {
                                selectedRaceTrackID = summary.id
                            } label: {
                                raceLibraryRow(summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func raceLibraryRow(_ summary: RaceTrackStore.Summary) -> some View {
        let isSelected = summary.id == selectedRaceTrackID
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? GroundControlPalette.accent : .white.opacity(0.4))
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(String(
                    format: NSLocalizedString("race.setup.library.detail", comment: ""),
                    summary.gateCount,
                    summary.lapLengthMeters,
                    summary.laps
                ))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            if let best = summary.bestLapSeconds {
                Text(String(format: "%.2f s", best))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(GroundControlPalette.success)
            }
        }
        .padding(8)
        .background(
            Color.white.opacity(isSelected ? 0.10 : 0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var platformSection: some View {
        sectionCard(titleKey: "mission.setup.section.platform") {
            VStack(alignment: .leading, spacing: 14) {
                // The interception setup already shows this aircraft beside the target and the
                // observer, where the choice actually belongs. Repeating the whole grid here would
                // be a second, disagreeing place to pick the same thing.
                if kind != .attachedPayloadIntercept {
                    labeledRow("mission.setup.uav") {
                    if compatibleProfiles.isEmpty {
                        Text("mission.setup.uav.none_compatible")
                            .font(.caption2)
                            .foregroundStyle(GroundControlPalette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
                            ForEach(compatibleProfiles) { profile in
                                Button {
                                    selectedProfileID = profile.id
                                } label: {
                                    UAVSelectionCardView(
                                        name: profile.uiDisplayName,
                                        manufacturer: profile.manufacturer,
                                        previewProfile: previewProfile(for: profile),
                                        runtimePreviewProfile: profile,
                                        massKg: profile.takeoffMassKg,
                                        speedMps: profile.resolvedUAVProfile?.nominalCruiseSpeedMps ?? profile.maxHorizontalSpeedMps,
                                        flightTimeSec: profile.resolvedUAVProfile?.nominalFlightTimeSec ?? profile.maxFlightTimeMin * 60.0,
                                        rangeMeters: profile.resolvedUAVProfile?.nominalMaxRangeM,
                                        badgeText: profileBadgeText(for: profile),
                                        badgeTint: profileBadgeTint(for: profile),
                                        isSelected: profile.id == selectedProfileID
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    }
                }

                if kind.requiresPayload {
                    labeledRow("mission.setup.payload") {
                        Picker("", selection: $payload) {
                            ForEach(compatiblePayloads) { type in
                                Text(LocalizedStringKey(payloadTitleKey(type))).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(.white)
                    }
                }

                Text(LocalizedStringKey(payloadHintKey))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                if payload == .fireHose {
                    hoseRiggingFields
                }
                if payload == .fireCapsuleLauncher {
                    capsuleRiggingFields
                }
            }
        }
    }

    @ViewBuilder
    private var hoseRiggingFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledRow("payload.hose.diameter_class") {
                Picker("", selection: $hoseDiameterClass) {
                    ForEach(FireHoseDiameterClass.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("payload.hose.length")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.0f m", hoseLengthMeters))
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
                Slider(
                    value: $hoseLengthMeters,
                    in: Double(hoseDiameterClass.lengthRangeMeters.lowerBound)...Double(hoseDiameterClass.lengthRangeMeters.upperBound),
                    step: Double(hoseDiameterClass.lengthStepMeters)
                )
                Text(String(format: NSLocalizedString("payload.hose.rig_mass", comment: ""), hoseDiameterClass.massForLength(Float(hoseLengthMeters))))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var capsuleRiggingFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledRow("payload.capsule.size_class") {
                Picker("", selection: $capsuleSize) {
                    ForEach(FireCapsuleSize.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("payload.capsule.count")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("\(capsuleCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
                Slider(
                    value: Binding(
                        get: { Double(capsuleCount) },
                        set: { capsuleCount = Int($0.rounded()) }
                    ),
                    in: Double(FireCapsuleTuning.countRange.lowerBound)...Double(FireCapsuleTuning.countRange.upperBound),
                    step: 1
                )
                Text(String(format: NSLocalizedString("payload.capsule.rig_mass", comment: ""), FireCapsuleTuning.totalMass(size: capsuleSize, count: capsuleCount)))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Text("common.cancel")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: start) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("mission.setup.start")
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .background(GroundControlPalette.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(resolvedProfile == nil)
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
    }

    // MARK: Helpers

    private func start() {
        guard let profile = resolvedProfile else { return }
        let parameters = MissionScenarioParameters(
            kind: kind,
            terrain: terrain,
            terrainDensity: terrainDensity,
            difficulty: difficulty,
            weather: weather,
            weatherIntensity: Float(weatherIntensity),
            timeOfDay: timeOfDay,
            timeLimitMinutes: timeLimitMinutes
        )
        let config = MissionScenarioConfiguration(
            parameters: parameters,
            selectedUAVProfileID: profile.id,
            payloadType: payload,
            fireHoseDiameterClass: hoseDiameterClass,
            fireHoseLengthMeters: Float(hoseLengthMeters),
            fireCapsuleSize: capsuleSize,
            fireCapsuleCount: capsuleCount,
            raceTrack: resolvedRaceTrack(parameters: parameters),
            raceMode: raceMode,
            interception: kind == .attachedPayloadIntercept ? interception : nil
        )
        onStart(config)
    }

    /// The track a racing mission launches with. Nil is a real answer, not a failure: it means
    /// the pilot asked for an empty world and will build the course in it.
    private func resolvedRaceTrack(parameters: MissionScenarioParameters) -> RaceTrack? {
        guard kind == .droneRacing else { return nil }
        switch raceTrackSource {
        case .empty:
            return nil
        case .library:
            guard let id = selectedRaceTrackID,
                  let summary = raceLibrary.first(where: { $0.id == id }),
                  var track = try? RaceTrackStore.load(from: summary.url) else {
                return nil
            }
            track.laps = raceMode == .timed ? raceLaps : track.laps
            return track
        case .generated:
            var track = RaceTrackGenerator.generate(
                parameters: RaceTrackGenerator.Parameters.forDifficulty(
                    difficulty,
                    seed: parameters.seed
                ),
                worldHalfExtent: parameters.difficulty.recommendedMapScale.worldHalfExtentMeters
            )
            track.laps = raceLaps
            return track
        }
    }

    private func payloadTitleKey(_ type: PayloadType) -> String {
        switch type {
        case .thermalCamera: return "payload.type.thermal_camera"
        case .cameraGimbal: return "payload.type.camera_gimbal"
        case .laserRangefinder: return "payload.type.laser_rangefinder"
        case .fireHose: return "payload.type.fire_hose"
        case .fireCapsuleLauncher: return "payload.type.fire_capsule_launcher"
        case .agriculturalSprayer: return "payload.type.agricultural_sprayer"
        case .lidarModule: return "payload.type.lidar_module"
        case .cargoBox: return "payload.type.cargo_box"
        case .rescuePack: return "payload.type.rescue_pack"
        case .sensorModule: return "payload.type.sensor_module"
        case .radioRelay: return "payload.type.radio_relay"
        case .custom: return "payload.type.custom"
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(
        titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func labeledRow<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            content()
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
