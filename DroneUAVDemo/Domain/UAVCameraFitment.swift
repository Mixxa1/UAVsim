import Foundation

/// The fixed camera a pilot flies from. Separate from the mission camera on purpose: on a real
/// aircraft these are two different devices with different jobs, and conflating them is what left
/// every airframe in the catalogue carrying a camera it does not have.
enum NavigationCameraKind: String, Hashable, Sendable {
    /// Composite feed from a bolted-in FPV camera — the racer's own camera, no gimbal.
    case analogFPV
    /// Digital orientation camera fitted to enterprise platforms, low-light capable.
    case nightVisionFPV
    /// The mission gimbal doubles as the pilot's view. Consumer aircraft work this way: there is
    /// no second camera, you fly from the one that films.
    case gimbalDoublesAsPilotView

    /// Which camera in the catalogue this kind is. A racer's bolted-in analog camera and an
    /// enterprise platform's low-light orientation camera are different devices, and the feed
    /// should not pretend otherwise.
    var moduleID: String {
        switch self {
        case .analogFPV: return "fpv-analog-nano"
        // Digital, not composite: a Matrice-class platform's orientation camera runs down the same
        // digital link as everything else, and calling it analog gave it a 1280x960 feed that
        // arrived visibly soft on a full-size window.
        case .nightVisionFPV: return "fpv-digital-lowlight"
        case .gimbalDoublesAsPilotView: return "fpv-digital"
        }
    }
}

/// Where the mission camera comes from.
enum ImagingCameraFitment: Equatable, Hashable, Sendable {
    /// Bolted in at the factory and not removable — consumer gimbals and seeker heads.
    case integrated(moduleID: String)
    /// The airframe ships bare; the operator fits a camera as payload.
    case operatorFitted
    /// The airframe carries no imaging camera and is not meant to.
    case none
}

struct UAVCameraFitment: Hashable, Sendable {
    var navigationCamera: NavigationCameraKind?
    var imagingCamera: ImagingCameraFitment
    /// Set only where the pilot's camera is chosen rather than fitted at the factory — a Workbench
    /// build flies from whatever went into its camera slot.
    var navigationCameraModuleID: String?

    var hasPilotView: Bool { navigationCamera != nil }

    /// The camera the pilot's feed actually comes from. Fixed hardware: it is bolted to the
    /// airframe by the manufacturer, so unlike the mission camera there is nothing to choose here
    /// — only a Workbench build picks its own, in the camera slot.
    var navigationCameraModule: CameraModule? {
        if let navigationCameraModuleID {
            return CameraModuleCatalog.fpvCamera(id: navigationCameraModuleID)
        }
        guard let navigationCamera else { return nil }
        return CameraModuleCatalog.fpvCamera(id: navigationCamera.moduleID)
    }

    /// True where the operator may fit or remove a mission camera. An integrated gimbal cannot be
    /// taken off a Mavic, so the payload picker must not offer it.
    var allowsOperatorCameraPayload: Bool {
        imagingCamera == .operatorFitted
    }
}

/// Which cameras each airframe in the catalogue actually carries.
///
/// `payloadCapabilityMode` alone cannot answer this — `.sensor` covers consumer gimbals, mapping
/// VTOLs whose camera is a swappable payload, and target drones with no camera at all. So the
/// rule below is a default and the sets are the exceptions, kept as data rather than as branches.
enum UAVCameraFitmentCatalog {
    /// Built for flight test, target towing or anti-radiation work. No imaging camera, and the
    /// operator does not fly them from a video feed.
    private static let noCamera: Set<String> = [
        "epfl-delta-wing-uav",
        "ncstate-bwb-delta",
        "ryan-bqm-34f-firebee-ii",
        "northrop-aqm-35a",
        "northrop-aqm-35b",
        "rockwell-himat",
        "hermeus-quarterhorse-mk21",
        "north-american-x-10",
        "iai-harpy",
    ]

    /// Flown from a ground station on a planned route, with the camera as a swappable payload.
    /// WingtraOne's imaging head is literally sold separately — RX1R II, a6100, RedEdge, LiDAR.
    private static let surveyPayloadCamera: Set<String> = [
        "wingtraone-gen-ii",
        "quantum-systems-trinity-pro",
        "sensefly-ebee-tac",
        "freefly-alta-x",
    ]

    /// Electro-optical seeker bolted into the nose. Not removable, and it is the pilot's view.
    private static let integratedSeeker: Set<String> = [
        "iai-harop",
        "iai-harpy-ng",
        "hesa-karrar",
    ]

    /// Military ISR: a fixed nose/landing camera for the crew plus a podded sensor turret that
    /// counts as payload.
    private static let militaryISR: Set<String> = [
        "mq-9b-skyguardian",
        "mq-9a-reaper",
        "hermes-900",
        "rq-21-integrator",
        "aerosonde-mk-4-7",
        "rq-7b-shadow",
        "ft5-los",
    ]

    /// Bolted-in analog FPV camera — the airframe is built around it.
    private static let analogFPVAirframes: Set<String> = [
        "fpv-tiny-whoop-65",
        "fpv-racer-5",
        "fpv-spec-5",
        "fpv-long-range-7",
        "fpv-open-class",
        "fpv-cinewhoop-3",
    ]

    static func fitment(for profile: UAVProfile) -> UAVCameraFitment {
        fitment(profileID: profile.id, capabilityMode: profile.payloadCapabilityMode)
    }

    static func fitment(
        profileID: String,
        capabilityMode: UAVPayloadCapabilityMode
    ) -> UAVCameraFitment {
        if noCamera.contains(profileID) {
            return UAVCameraFitment(navigationCamera: nil, imagingCamera: .none)
        }
        if analogFPVAirframes.contains(profileID) {
            return UAVCameraFitment(
                navigationCamera: .analogFPV,
                imagingCamera: .integrated(moduleID: "caddx-analog-fpv")
            )
        }
        if integratedSeeker.contains(profileID) {
            return UAVCameraFitment(
                navigationCamera: .gimbalDoublesAsPilotView,
                imagingCamera: .integrated(moduleID: "flir-boson-640")
            )
        }
        if surveyPayloadCamera.contains(profileID) {
            // Flown on a planned route from a tablet: there is no live pilot view to speak of.
            return UAVCameraFitment(navigationCamera: nil, imagingCamera: .operatorFitted)
        }
        if militaryISR.contains(profileID) {
            return UAVCameraFitment(
                navigationCamera: .nightVisionFPV,
                imagingCamera: .operatorFitted
            )
        }

        switch capabilityMode {
        case .sensor:
            // Consumer and enterprise all-in-ones: one gimbal, fixed, and you fly from it.
            return UAVCameraFitment(
                navigationCamera: .gimbalDoublesAsPilotView,
                imagingCamera: .integrated(moduleID: "dji-zenmuse-h20t")
            )
        case .modular:
            // Matrice-class: a night-vision FPV camera for the pilot, and the imaging head is a
            // separately purchased payload.
            return UAVCameraFitment(
                navigationCamera: .nightVisionFPV,
                imagingCamera: .operatorFitted
            )
        case .cargo:
            // Freight platforms carry an orientation camera and no imaging head unless one is
            // fitted deliberately.
            return UAVCameraFitment(
                navigationCamera: .nightVisionFPV,
                imagingCamera: .operatorFitted
            )
        }
    }

    /// The module an airframe already has bolted on, if any.
    static func integratedModule(for profile: UAVProfile) -> CameraModule? {
        guard case let .integrated(moduleID) = fitment(for: profile).imagingCamera else {
            return nil
        }
        return CameraModuleCatalog.module(id: moduleID)
    }
}


/// Optics of the pilot's view, resolved in one place.
///
/// The render, the barrel remap and the rolling-shutter model all need the same angle, and having
/// each work it out for itself is how they end up disagreeing. The manual lens (option-C) wins
/// where the operator has turned it on: it is a deliberate override, and its widening is what makes
/// the barrel warp read as a wide lens rather than as a zoom.
enum PilotViewOptics {
    static func fieldOfViewDegrees(
        module: CameraModule?,
        fovSetting: Float,
        lensEnabled: Bool,
        lensDistortion: Float
    ) -> Double {
        if lensEnabled {
            let distortion = Double(min(1, max(0, lensDistortion)))
            return min(150.0, max(30.0, Double(fovSetting) * (1.0 + distortion * 0.6)))
        }
        if let module {
            return min(150.0, max(30.0, module.horizontalFieldOfViewDegrees))
        }
        return Double(fovSetting)
    }

    /// Bow applied to the pilot's frame: the fitted camera's own lens, unless the operator has
    /// taken manual control of it.
    static func lensDistortion(
        module: CameraModule?,
        lensEnabled: Bool,
        lensDistortion: Float
    ) -> Double {
        if lensEnabled {
            return Double(min(1, max(0, lensDistortion)))
        }
        return module?.primaryChannel.barrelDistortion ?? 0
    }
}
