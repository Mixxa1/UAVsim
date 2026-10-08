import SwiftUI

/// Preflight setup for a flight mission: pick a scenario, edit its parameters, choose the UAV
/// and payload, then start. Builds a `MissionScenarioConfiguration` handed to the simulation.
struct MissionSetupView: View {
    let availableProfiles: [DroneModelProfile]
    let onCancel: () -> Void
    let onStart: (MissionScenarioConfiguration) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: SetupStep = .scenario

    private enum SetupStep: Int, CaseIterable, Identifiable {
        case scenario, aircraft, conditions
        var id: Int { rawValue }
        var titleKey: String {
            switch self {
            case .scenario: return "mission.step.scenario"
            case .aircraft: return "mission.step.aircraft"
            case .conditions: return "mission.step.conditions"
            }
        }
    }

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
    @State private var groundVehicleModel: GroundVehicleModel = .cabover
    @State private var activeAircraftSlot: AircraftSlot = .player

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
        // The interception mission carries nothing from the payload catalogue, but it does carry
        // something: the module the operator chose. Its mass is what the airframe has to be able
        // to lift, so the list narrows live as a heavier one is picked.
        if kind == .attachedPayloadIntercept {
            var configuration = PayloadConfiguration(payloadType: .cargoBox)
            configuration.payloadMass = interception.moduleShape.massKg
            return availableProfiles.filter {
                PayloadController.capabilityCheck(for: configuration, profile: $0.resolvedUAVProfile).isAllowed
            }
        }
        // Racing mounts nothing, so no aircraft is excluded for being unable to carry it — the
        // pilot may fly a whoop, a Matrice or their own Workbench build through the gates.
        guard kind.requiresPayload else { return availableProfiles }
        var configuration = PayloadConfiguration(payloadType: payload)
        if payload == .fireHose {
            configuration.payloadMass = hoseDiameterClass.massForLength(Float(hoseLengthMeters))
        } else if payload == .fireCapsuleLauncher {
            configuration.payloadMass = FireCapsuleTuning.totalMass(size: capsuleSize, count: capsuleCount)
        }
        return availableProfiles.filter {
            PayloadController.capabilityCheck(for: configuration, profile: $0.resolvedUAVProfile).isAllowed
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
            return L10n.s("uav.badge.custom")
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
        case .vehiclePursuit, .vehicleEscort:
            return "ground.camera.hint"
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
            HStack(spacing: 0) {
                ForEach(SetupStep.allCases) { value in
                    ShellStepButton(number: value.rawValue + 1, title: L10n.s(value.titleKey), isSelected: step == value) {
                        step = value
                    }
                }
            }
            .padding(.horizontal, 20)
            Divider().overlay(GroundControlPalette.border)
            Group {
                if step == .aircraft {
                    aircraftWorkspace
                        .padding(20)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if step == .scenario {
                                scenarioSection
                            } else {
                                conditionsSection
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step)
            .transition(reduceMotion ? .opacity : .panelSwap)
            footer
        }
        .frame(maxWidth: 1080, maxHeight: .infinity)
        .background(GroundControlPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.12)))
        .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.panel, value: step)
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
        .onChange(of: difficulty) { _, newValue in
            timeLimitMinutes = defaultTimeLimit(for: kind, difficulty: newValue)
            applyInterceptDifficulty(newValue)
        }
        .onChange(of: resolvedProfile?.airframeClass) { _, airframeClass in
            if let airframeClass {
                terrain = terrain.compatiblePreset(for: airframeClass)
            }
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
            if newValue.isGroundVehicleMission {
                terrain = .field
                terrainDensity = .sparse
                activeAircraftSlot = .player
            }
            timeLimitMinutes = defaultTimeLimit(for: newValue, difficulty: difficulty)
        }
        // Switching sides changes what the aircraft would sensibly be carrying, and the two lists
        // only partly overlap. Left alone, the picker keeps a selection that is no longer on it.
        .onChange(of: interception.side) { _, newValue in
            let allowed = AttachedModuleShape.selectable(for: newValue)
            if !allowed.contains(interception.moduleShape) {
                interception.moduleShape = allowed.first ?? .charge
            }
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
        HStack(alignment: .top, spacing: 16) {
            ShellSectionHeading(title: L10n.s("mission.setup.title"), subtitle: L10n.s("mission.setup.guided.subtitle"))
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.s("common.cancel"))
        }
        .padding(20)
    }

    private func briefKey(for value: MissionScenarioKind) -> String {
        switch value {
        case .searchAndRescue: return "mission.brief.search"
        case .fireResponse: return "mission.brief.fire"
        case .agriculturalSpraying: return "mission.brief.agriculture"
        case .droneRacing: return "mission.brief.race"
        case .attachedPayloadIntercept: return "mission.brief.intercept"
        case .vehiclePursuit: return "ground.pursuit.brief"
        case .vehicleEscort: return "ground.escort.brief"
        }
    }

    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("mission.setup.choose_task")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(MissionScenarioKind.allCases) { value in
                    Button { kind = value } label: { scenarioChip(value) }
                        .buttonStyle(ShellButtonStyle(cornerRadius: 10, hoverScale: 1.008))
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: kind.iconSystemName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(GroundControlPalette.accent)
                    .frame(width: 46, height: 46)
                    .background(GroundControlPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(kind.titleKey)).font(.headline)
                    Text(LocalizedStringKey(kind.subtitleKey))
                        .font(.callout)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 18))
        }
        .foregroundStyle(.white)
    }

    private func scenarioChip(_ value: MissionScenarioKind) -> some View {
        let selected = value == kind
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: value.iconSystemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(selected ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(value.titleKey))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(LocalizedStringKey(briefKey(for: value)))
                    .font(.system(size: 11))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? GroundControlPalette.accent : Color.white.opacity(0.15))
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .topLeading)
        .background(selected ? GroundControlPalette.accent.opacity(0.07) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? GroundControlPalette.accent.opacity(0.4) : GroundControlPalette.border))
    }

    private var missionSummary: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.iconSystemName).font(.title2).foregroundStyle(GroundControlPalette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(kind.titleKey)).font(.headline)
                Text(resolvedProfile?.uiDisplayName ?? L10n.s("mission.setup.uav.none_compatible"))
                    .font(.callout).foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer(minLength: 8)
            Label("\(timeLimitMinutes) " + L10n.s("mission.setup.minutes"), systemImage: "clock")
                .font(.caption.monospacedDigit()).foregroundStyle(GroundControlPalette.textSecondary)
        }
        .padding(18)
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 16))
    }

    private var displayedAircraftSlot: AircraftSlot {
        kind == .attachedPayloadIntercept || kind.isGroundVehicleMission ? activeAircraftSlot : .player
    }

    private var displayingGroundTarget: Bool {
        displayedAircraftSlot == .target && kind.isGroundVehicleMission
    }

    private var selectedGroundModel: GroundVehicleModel {
        groundVehicleModel
    }

    private var groundModelBinding: Binding<GroundVehicleModel> {
        $groundVehicleModel
    }

    private var displayedAircraft: DroneModelProfile? {
        let list = profiles(for: displayedAircraftSlot)
        return list.first { $0.id == selection(for: displayedAircraftSlot) } ?? list.first
    }

    private var aircraftWorkspace: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                if kind == .attachedPayloadIntercept || kind.isGroundVehicleMission {
                    Picker("", selection: $activeAircraftSlot) {
                        ForEach(kind.isGroundVehicleMission ? [AircraftSlot.player, .target] : [.player, .target, .observer]) { slot in
                            Text(LocalizedStringKey(slot == .target && kind.isGroundVehicleMission
                                ? "ground.vehicle" : slot.titleKey)).tag(slot)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(height: 28)
                }

                if displayingGroundTarget {
                    Text(LocalizedStringKey(selectedGroundModel.titleKey)).font(.system(size: 19, weight: .semibold))
                } else if let profile = displayedAircraft {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.uiDisplayName)
                                .font(.system(size: 19, weight: .semibold))
                            Text(profile.manufacturer)
                                .font(.caption)
                                .foregroundStyle(GroundControlPalette.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Text(profileBadgeText(for: profile))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(profileBadgeTint(for: profile))
                            .lineLimit(1)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Group {
                        if displayingGroundTarget {
                            GroundVehiclePreviewView(model: selectedGroundModel)
                        } else if let profile = displayedAircraft {
                            UAVLivePreviewView(profile: previewProfile(for: profile), runtimeProfile: profile)
                                .accessibilityLabel(profile.uiDisplayName)
                        } else {
                            ShellEmptyState(symbol: "airplane", title: L10n.s("mission.setup.uav.none_compatible"),
                                            detail: L10n.s("mission.setup.uav.compatibility_help"))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10))

                    ScrollView {
                        if kind == .attachedPayloadIntercept {
                            interceptFields
                        } else {
                            platformFields
                        }
                    }
                    .frame(width: 250)
                }
                .frame(height: min(320, max(170, geometry.size.height * 0.44)))

                if displayingGroundTarget { groundVehicleList } else { aircraftList }
            }
            .foregroundStyle(GroundControlPalette.textPrimary)
        }
    }

    private var aircraftList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("mission.aircraft.model")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24)
                aircraftMetric(L10n.s("panel.mass"))
                aircraftMetric(L10n.s("mission.aircraft.speed"))
                aircraftMetric(L10n.s("mission.aircraft.duration"))
                aircraftMetric(L10n.s("mission.aircraft.range"))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(GroundControlPalette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(profiles(for: displayedAircraftSlot)) { profile in
                        aircraftListRow(profile)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(GroundControlPalette.border))
    }

    private var groundVehicleList: some View {
        VStack(spacing: 6) {
            ForEach(GroundVehicleModel.allCases) { model in
                Button { groundModelBinding.wrappedValue = model } label: {
                    HStack(spacing: 12) {
                        Image(systemName: model == selectedGroundModel ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model == selectedGroundModel ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                        Text(LocalizedStringKey(model.titleKey)).frame(maxWidth: .infinity, alignment: .leading)
                        Text("ground.vehicle.specs").font(.caption).foregroundStyle(GroundControlPalette.textSecondary)
                    }
                    .padding(12)
                    .background(model == selectedGroundModel ? GroundControlPalette.accent.opacity(0.1) : GroundControlPalette.inset,
                        in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func aircraftListRow(_ profile: DroneModelProfile) -> some View {
        let selected = profile.id == selection(for: displayedAircraftSlot)
        let range = profile.resolvedUAVProfile?.nominalMaxRangeM
        return Button { select(profile.id, for: displayedAircraftSlot) } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? GroundControlPalette.accent : GroundControlPalette.textSecondary.opacity(0.5))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.uiDisplayName).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(profile.manufacturer).font(.system(size: 10))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                aircraftMetric(String(format: L10n.s("mission.aircraft.mass.value"), profile.takeoffMassKg))
                aircraftMetric(String(format: L10n.s("mission.aircraft.speed.value"), profile.maxHorizontalSpeedMps * 3.6))
                aircraftMetric(profile.maxFlightTimeMin > 0
                    ? String(format: L10n.s("mission.aircraft.duration.value"), profile.maxFlightTimeMin) : "—")
                aircraftMetric(range.flatMap { value in
                    value > 0 ? String(format: L10n.s(value >= 1000 ? "mission.aircraft.range.km" : "mission.aircraft.range.m"),
                                       value >= 1000 ? value / 1000 : value) : nil
                } ?? "—")
            }
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .background(selected ? GroundControlPalette.accent.opacity(0.08) : Color.clear)
            .overlay(alignment: .bottom) { GroundControlPalette.border.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func aircraftMetric(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .lineLimit(1)
            .frame(width: 76, alignment: .trailing)
    }

    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            missionSummary

            HStack(alignment: .top, spacing: 16) {
                terrainConditions
                weatherConditions
            }

            sectionCard(titleKey: "mission.setup.section.parameters") {
                HStack(alignment: .top, spacing: 20) {
                    labeledRow("mission.setup.difficulty") {
                        Picker("", selection: $difficulty) {
                            ForEach(MissionDifficulty.allCases) { value in
                                Text(LocalizedStringKey(value.titleKey)).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(height: 28)
                    }
                    .frame(maxWidth: .infinity)
                    labeledRow("mission.setup.time_limit") {
                        Stepper(value: $timeLimitMinutes, in: 3...(kind == .agriculturalSpraying ? 180 : 30)) {
                            Text(String(format: L10n.s("mission.setup.time_limit.value"), timeLimitMinutes))
                                .font(.callout.monospacedDigit())
                        }
                        .frame(height: 28)
                    }
                    .frame(width: 170)
                }
                if kind == .agriculturalSpraying { agriBriefingRow }
                if kind == .droneRacing { raceFields }
                if kind == .attachedPayloadIntercept { interceptBriefingRow }
            }
        }
    }

    private var terrainConditions: some View {
        sectionCard(titleKey: "mission.conditions.terrain") {
            GeometryReader { geometry in
                Group {
                    if let image = MapCardArtwork.image(for: terrain) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        MapCardArtwork.placeholder(for: terrain)
                    }
                }
                .frame(width: geometry.size.width, height: 165)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 165)

            labeledRow("mission.setup.terrain") {
                Picker("", selection: $terrain) {
                    ForEach(TerrainPreset.available(for: resolvedProfile?.airframeClass ?? .multirotor)) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(height: 28)
            }

            labeledRow("mission.setup.terrain_density") {
                Picker("", selection: $terrainDensity) {
                    ForEach(MissionTerrainDensity.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(height: 28)
            }
        }
    }

    private var weatherConditions: some View {
        sectionCard(titleKey: "mission.conditions.weather") {
            HStack(spacing: 12) {
                Image(systemName: weatherSymbol)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(GroundControlPalette.accent.opacity(0.85))
                    .frame(width: 46, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(weather.titleKey)).font(.headline)
                    Label(L10n.s(timeOfDay.titleKey), systemImage: timeOfDay.iconSystemName)
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            labeledRow("mission.setup.time_of_day") {
                Picker("", selection: $timeOfDay) {
                    ForEach(TimeOfDay.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(height: 28)
            }

            labeledRow("mission.setup.weather") {
                Picker("", selection: $weather) {
                    ForEach(WeatherPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(height: 28)
            }

            VStack(spacing: 4) {
                HStack {
                    Text("mission.setup.weather_intensity")
                    Spacer()
                    Text(String(format: "%.0f%%", weatherIntensity * 100)).monospacedDigit()
                }
                .font(.caption)
                Slider(value: $weatherIntensity, in: 0...1, step: 0.01)
            }

            Divider().overlay(GroundControlPalette.border)
            HStack {
                Label(L10n.s("mission.conditions.visibility"), systemImage: "eye")
                Spacer()
                Text(String(format: "%.0f%%", weatherFactors.visibilityFactor * 100)).monospacedDigit()
            }
            HStack {
                Label(L10n.s("mission.conditions.energy"), systemImage: "battery.100percent")
                Spacer()
                Text(String(format: "×%.2f", weatherFactors.batteryDrainMultiplier)).monospacedDigit()
            }
            .help(L10n.s("mission.conditions.factors_help"))
        }
        .font(.caption)
    }

    private var weatherFactors: WeatherFactors {
        WeatherModel(preset: weather, intensity: Float(weatherIntensity), windDirectionDeg: 0,
                     windSpeedMps: 0, gusts: 0).effectiveFactors
    }

    private var weatherSymbol: String {
        switch weather {
        case .normal: return timeOfDay.iconSystemName
        case .wind: return "wind"
        case .rain: return "cloud.rain"
        case .snow: return "cloud.snow"
        case .fog: return "cloud.fog"
        case .smog: return "sun.haze"
        case .thunderstorm: return "cloud.bolt.rain"
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
                    format: L10n.s("mission.setup.agri.briefing"),
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
                format: L10n.s("mission.setup.agri.window"),
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

    private func profiles(for slot: AircraftSlot) -> [DroneModelProfile] {
        switch slot {
        case .player: return compatibleProfiles
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
            labeledRow("intercept.side") {
                Picker("", selection: $interception.side) {
                    ForEach(InterceptMissionSide.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: false, vertical: true)
                .labelsHidden()
            }

            Text(LocalizedStringKey(interception.side.hintKey))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if isFixedWingTargetSelected, interception.side == .interceptor {
                Text("intercept.setup.fixed_wing.hint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The other aircraft's profile is the operator's choice only when they are the one
            // hunting it. On the delivery side there is exactly one thing it can be doing.
            if interception.side == .interceptor {
                labeledRow("intercept.target.behavior") {
                        Picker("", selection: $interception.targetBehavior) {
                            ForEach(InterceptTargetBehavior.selectable) { value in
                                Text(LocalizedStringKey(value.titleKey)).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize(horizontal: false, vertical: true)
                        .labelsHidden()
                        .tint(.white)
                    }
            }

            labeledRow("intercept.module.title") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                    ForEach(AttachedModuleShape.selectable(for: interception.side)) { shape in
                        Button {
                            interception.moduleShape = shape
                        } label: {
                            moduleCard(shape)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(LocalizedStringKey(interception.moduleShape.detailKey))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            // Who is allowed to call a target neutralised, and what the target carries, are both
            // questions about hunting something. On the delivery side the run is decided by where
            // the load comes to rest, and nobody has to confirm anything.
            if interception.side == .interceptor {
                labeledRow("intercept.confirmation") {
                    Picker("", selection: $interception.confirmationPolicy) {
                        ForEach(InterceptConfirmationPolicy.allCases) { value in
                            Text(LocalizedStringKey(value.titleKey)).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                .fixedSize(horizontal: false, vertical: true)
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
            } else {
                labeledRow("intercept.setup.zone_radius") {
                    HStack(spacing: 10) {
                        Text("\(Int(interception.deliveryZoneRadius)) м")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 54, alignment: .leading)
                        Slider(
                            value: $interception.deliveryZoneRadius,
                            in: 20...120,
                            step: 5
                        )
                        .labelsHidden()
                    }
                }
                Text("intercept.setup.zone_radius.hint")
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
                    format: L10n.s("intercept.setup.briefing"),
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

    /// One module, shown as the object it is. The turning preview is the same geometry the
    /// mission bolts under the aircraft, so what is picked here is what gets carried.
    private func moduleCard(_ shape: AttachedModuleShape) -> some View {
        let isSelected = interception.moduleShape == shape
        return VStack(alignment: .leading, spacing: 6) {
            AttachedModulePreviewView(shape: shape)
                .frame(height: 76)
                .background(GroundControlPalette.shell, in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(LocalizedStringKey(shape.titleKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
            Text(L10n.f("payload.mass_value", Double(shape.massKg)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? GroundControlPalette.accent.opacity(0.22) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? GroundControlPalette.accent : Color.white.opacity(0.1), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
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
                .fixedSize(horizontal: false, vertical: true)
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
                .fixedSize(horizontal: false, vertical: true)
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
                    format: L10n.s("race.setup.library.detail"),
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

    private var platformFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if kind.isGroundVehicleMission { groundModelPicker }
            // Interception selects its carried module in its own controls.
            if kind.requiresPayload, kind != .attachedPayloadIntercept {
                labeledRow("mission.setup.payload") {
                    Picker("", selection: $payload) {
                        ForEach(compatiblePayloads) { type in
                            Text(LocalizedStringKey(payloadTitleKey(type))).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize(horizontal: false, vertical: true)
                    .labelsHidden()
                    .tint(.white)
                }
            }

            Text(LocalizedStringKey(payloadHintKey))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if payload == .fireHose { hoseRiggingFields }
            if payload == .fireCapsuleLauncher { capsuleRiggingFields }
        }
    }

    private var groundModelPicker: some View {
        labeledRow("ground.vehicle") {
            Picker("", selection: groundModelBinding) {
                ForEach(GroundVehicleModel.allCases) { model in
                    Text(LocalizedStringKey(model.titleKey)).tag(model)
                }
            }
            .pickerStyle(.menu).labelsHidden()
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
                .fixedSize(horizontal: false, vertical: true)
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
                Text(String(format: L10n.s("payload.hose.rig_mass"), hoseDiameterClass.massForLength(Float(hoseLengthMeters))))
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
                .fixedSize(horizontal: false, vertical: true)
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
                Text(String(format: L10n.s("payload.capsule.rig_mass"), FireCapsuleTuning.totalMass(size: capsuleSize, count: capsuleCount)))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                if step == .scenario { onCancel() }
                else { step = SetupStep(rawValue: step.rawValue - 1) ?? .scenario }
            } label: {
                Label(L10n.s(step == .scenario ? "common.cancel" : "common.back"), systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(ShellButtonStyle(cornerRadius: 12, hoverScale: 1))
            Spacer(minLength: 12)
            if step == .conditions {
                Button(action: start) {
                    Label(L10n.s("mission.setup.start"), systemImage: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(GroundControlPalette.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(ShellButtonStyle(cornerRadius: 12, hoverScale: 1))
                .disabled(resolvedProfile == nil)
            } else {
                Button { step = SetupStep(rawValue: step.rawValue + 1) ?? .conditions } label: {
                    Label(L10n.s("mission.setup.next"), systemImage: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(GroundControlPalette.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(ShellButtonStyle(cornerRadius: 12, hoverScale: 1))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(GroundControlPalette.shell)
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
            interception: kind == .attachedPayloadIntercept ? interception : nil,
            groundVehicleModel: groundVehicleModel
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
