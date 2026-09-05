import Foundation

/// What part of the spectrum a sensor records. Drives which presentation path the feed takes —
/// the thermal overlay, the analog composite chain, or the ordinary digital one.
enum CameraSpectrum: String, CaseIterable, Hashable, Sendable {
    case visibleLight
    case longwaveInfrared
    case multispectral
}

/// A selectable imaging channel on a module.
///
/// Hybrid turrets are not one camera: a Zenmuse H20T carries a zoom camera and a separate 640x512
/// thermal core behind the same window, each with its own optics and its own sensor. Modelling a
/// module as a single sensor is what made the "T" payloads — the ones that actually have a thermal
/// channel — unable to show thermal at all, while a bare thermal core was stuck in it.
enum CameraImagingChannel: String, CaseIterable, Hashable, Sendable {
    case optical
    case thermal

    var payloadCameraMode: PayloadCameraMode {
        switch self {
        case .optical: return .optical
        case .thermal: return .thermalStub
        }
    }

    init?(payloadCameraMode: PayloadCameraMode) {
        switch payloadCameraMode {
        case .optical: self = .optical
        case .thermalStub: self = .thermal
        case .nightStub: return nil
        }
    }

    var titleKey: String { "camera.channel.\(rawValue)" }
}

/// Rolling shutter reads the sensor line by line, so a fast pan skews vertical edges; a global
/// shutter exposes every line at once and does not. This is a real, visible difference between
/// a mapping camera and a consumer one, not a stylistic choice.
enum CameraShutter: String, CaseIterable, Hashable, Sendable {
    case rolling
    case global
}

/// How the video leaves the aircraft. Analog feeds the composite NTSC chain; digital feeds the
/// packet-loss/macroblock path. A camera is one or the other, and that is a property of the
/// module rather than of the radio.
enum CameraVideoOutput: String, CaseIterable, Hashable, Sendable {
    case analogComposite
    case digital
}

/// Confidence in the figures below, mirroring `UAVSpecConfidence` in the airframe catalogue: some
/// channels publish full sensor geometry, others only a field of view.
///
/// This describes the *geometry*. The auto-exposure and colour figures below are characterisations
/// of how a camera of that class behaves, not datasheet numbers — manufacturers do not publish AE
/// convergence times or colour-matrix chroma gains. They are stated as the same measurable
/// quantities for every camera rather than as a per-camera list of effects, but they are not
/// measured, and this comment is the honest place to say so.
enum CameraSpecConfidence: String, Hashable, Sendable {
    case verified
    case estimated
}

/// How the camera's auto-exposure behaves.
///
/// This separates cameras by eye more than anything else on a real aircraft: flying out of a
/// shaded gate into direct sun, one camera recovers in a fraction of a second and another stays
/// blind for a second. A camera whose loop runs out of range simply stays blown, or stays dark.
struct CameraAutoExposure: Hashable, Sendable {
    /// Mid-grey the metering drives the frame toward, in display units.
    let targetLevel: Double
    /// Time constant of the loop, seconds — roughly the time to cover 63 % of a step change.
    let responseSeconds: Double
    /// How far the loop may brighten, in stops.
    ///
    /// Deliberately much smaller than the darkening range, and this asymmetry is the whole point: a
    /// video camera's shutter is already pinned near the frame interval, so the only headroom left
    /// for a dark scene is analogue gain. A symmetric range let a night field be pulled all the way
    /// back to daylight, which is not something any camera can do.
    ///
    /// Composite cameras sit lowest of all. A digital camera can spend coding gain on a dark scene;
    /// a composite one has only the sensor's own amplifier, and it runs out while the picture is
    /// still dark. Set too high they turned a moonless field into late dusk.
    let gainUpStops: Double
    /// How far the loop may darken, in stops. Generous — in daylight the shutter can go very short.
    let gainDownStops: Double

    /// Both zero disables the loop entirely, which is what a cinema camera shot on manual does.
    static let manual = CameraAutoExposure(
        targetLevel: 0.42,
        responseSeconds: 1,
        gainUpStops: 0,
        gainDownStops: 0
    )
}

/// The sensor and ISP's colour and detail rendering — the camera's signature.
struct CameraColorResponse: Hashable, Sendable {
    /// Warm/cool bias of the colour matrix relative to neutral daylight, -1...1. Positive is warm.
    let whiteBalanceBias: Double
    /// Chroma gain of the colour matrix. 1 is neutral; an FPV camera tuned to look punchy is above
    /// it, a camera recording a log curve for grading is below.
    let saturation: Double
    /// How far the camera lifts true black, 0...0.2. Analog FPV cameras lift shadows heavily, and
    /// so does a log curve — for opposite reasons.
    let blackLift: Double
    /// Edge enhancement the ISP applies, 0...1. Analog FPV cameras sharpen hard; a thermal core's
    /// digital detail enhancement does the same to its AGC output; a stills camera barely does.
    let edgeEnhancement: Double

    static let neutral = CameraColorResponse(
        whiteBalanceBias: 0,
        saturation: 1,
        blackLift: 0,
        edgeEnhancement: 0
    )
}

/// One sensor behind the glass, described by what it physically is.
///
/// Everything the picture does is derived from these numbers rather than assigned: the field of
/// view comes out of sensor width, focal length and the lens projection, the barrel bow drives
/// `FisheyeLensProcessor`, and resolution, noise and latitude drive `CameraSensorProcessor`.
/// Nothing here is a look-up table of "effects".
struct CameraChannelSpec: Hashable, Sendable {
    let channel: CameraImagingChannel
    let spectrum: CameraSpectrum
    let shutter: CameraShutter
    let specConfidence: CameraSpecConfidence

    /// Sensor width and focal length at the wide end, millimetres. Together they give the field
    /// of view; there is no separately authored FOV to drift away from them.
    let sensorWidthMM: Double
    let focalLengthMM: Double
    /// Optical zoom factor at the long end. 1 means a prime lens — or, on a thermal core, digital
    /// zoom only, which adds no coverage and is deliberately not modelled as optics.
    let maximumOpticalZoom: Double

    let horizontalResolution: Int
    let verticalResolution: Int

    /// How far the lens departs from rectilinear, 0...1, fed straight to the lens processor.
    /// Short focal lengths on small sensors bow noticeably; a 35 mm prime on full frame does not.
    let barrelDistortion: Double
    /// Relative luminance noise at the sensor's base sensitivity, 0...1. Small pixels are noisier.
    let baseNoise: Double
    let dynamicRangeStops: Double

    let autoExposure: CameraAutoExposure
    let colorResponse: CameraColorResponse

    /// Horizontal field of view in degrees, from the sensor geometry and the lens projection.
    ///
    /// A rectilinear lens places a ray at angle `t` on the sensor at height `f·tan(t)`, so its
    /// coverage is `atan(h/f)`. A barrel-distorted lens moves toward an equidistant projection,
    /// `f·t`, which reaches the sensor edge at a *wider* angle — `h/f` radians. Blending the two by
    /// the channel's own distortion figure is the same projection blend `FisheyeLensProcessor`
    /// applies to the picture, so the number quoted here is the coverage actually rendered.
    ///
    /// This matters: on the 2.1 mm FPV lens the rectilinear formula alone gives 98°, while the
    /// blend gives 124°, which is where cameras of that class really sit.
    var horizontalFieldOfViewDegrees: Double {
        guard focalLengthMM > 0, sensorWidthMM > 0 else { return 60 }
        let halfHeights = sensorWidthMM / (2 * focalLengthMM)
        let rectilinear = atan(halfHeights)
        let equidistant = halfHeights
        let bow = min(1, max(0, barrelDistortion))
        return 2 * (rectilinear * (1 - bow) + equidistant * bow) * 180 / .pi
    }

    /// Narrowest field of view the channel can reach with its own optics.
    var narrowestFieldOfViewDegrees: Double {
        guard maximumOpticalZoom > 1 else { return horizontalFieldOfViewDegrees }
        return 2 * atan(sensorWidthMM / (2 * focalLengthMM * maximumOpticalZoom)) * 180 / .pi
    }

    var megapixels: Double {
        Double(horizontalResolution * verticalResolution) / 1_000_000
    }
}

/// A camera the operator can fit: one or more channels, a mass, and a video output.
struct CameraModule: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let manufacturer: String
    let videoOutput: CameraVideoOutput

    /// The channel the module comes up in, and the one its catalogue figures describe.
    let primaryChannel: CameraChannelSpec
    /// Further sensors behind the same window. Empty for a single-sensor camera. Held separately
    /// from the primary so that "a module always has at least one channel" is enforced by the type
    /// rather than by a runtime check.
    let additionalChannels: [CameraChannelSpec]

    let massKg: Double

    init(
        id: String,
        displayName: String,
        manufacturer: String,
        videoOutput: CameraVideoOutput,
        primaryChannel: CameraChannelSpec,
        additionalChannels: [CameraChannelSpec] = [],
        massKg: Double
    ) {
        self.id = id
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.videoOutput = videoOutput
        self.primaryChannel = primaryChannel
        self.additionalChannels = additionalChannels
        self.massKg = massKg
    }

    var channels: [CameraChannelSpec] { [primaryChannel] + additionalChannels }

    func channel(_ channel: CameraImagingChannel) -> CameraChannelSpec? {
        channels.first { $0.channel == channel }
    }

    /// The sensor behind a payload-camera mode, or nil when the module has no such channel.
    func channel(forPayloadMode mode: PayloadCameraMode) -> CameraChannelSpec? {
        guard let channel = CameraImagingChannel(payloadCameraMode: mode) else { return nil }
        return self.channel(channel)
    }

    var availableChannels: [CameraImagingChannel] { channels.map(\.channel) }

    /// Modes the operator may select on this module. A bare LWIR core offers thermal and nothing
    /// else; a hybrid turret offers both; a mapping camera offers only the optical channel.
    var availablePayloadCameraModes: [PayloadCameraMode] {
        channels.map(\.channel.payloadCameraMode)
    }

    var hasThermalChannel: Bool { channel(.thermal) != nil }

    // The primary channel's figures, for everything that describes the module as a whole —
    // selection cards, mass budgeting, payload typing.
    var spectrum: CameraSpectrum { primaryChannel.spectrum }
    var shutter: CameraShutter { primaryChannel.shutter }
    var specConfidence: CameraSpecConfidence { primaryChannel.specConfidence }
    var horizontalFieldOfViewDegrees: Double { primaryChannel.horizontalFieldOfViewDegrees }
    var narrowestFieldOfViewDegrees: Double { primaryChannel.narrowestFieldOfViewDegrees }
    /// The longest reach any channel has. This describes the physical optical assembly — the
    /// barrel a turret carries — rather than whichever channel happens to be selected.
    var maximumOpticalZoom: Double {
        channels.map(\.maximumOpticalZoom).max() ?? 1
    }
    var megapixels: Double { primaryChannel.megapixels }
}

enum CameraModuleCatalog {
    /// Every module the operator can fit. Figures are the manufacturers' published sensor and lens
    /// geometry where available; entries marked `.estimated` derive focal length from a published
    /// field of view instead, and say so rather than presenting a guess as measured.
    static let modules: [CameraModule] = [
        CameraModule(
            id: "caddx-analog-fpv",
            displayName: "Analog FPV camera",
            manufacturer: "Caddx",
            videoOutput: .analogComposite,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                // 1/3" sensor behind a 2.1 mm lens — the short focal length on a small sensor is
                // exactly what makes an FPV feed bow the way it does.
                sensorWidthMM: 4.8,
                focalLengthMM: 2.1,
                maximumOpticalZoom: 1,
                horizontalResolution: 1200,
                verticalResolution: 960,
                barrelDistortion: 0.80,
                baseNoise: 0.35,
                dynamicRangeStops: 8.5,
                autoExposure: CameraAutoExposure(
                    // FPV cameras are tuned to recover fast — the pilot is committed to the gap
                    // before a slow loop would finish.
                    targetLevel: 0.45,
                    responseSeconds: 0.15,
                    gainUpStops: 1.1,
                    gainDownStops: 4.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.15,
                    saturation: 1.25,
                    blackLift: 0.06,
                    edgeEnhancement: 0.55
                )
            ),
            massKg: 0.012
        ),
        CameraModule(
            id: "dji-zenmuse-h20t",
            displayName: "Zenmuse H20T",
            manufacturer: "DJI",
            videoOutput: .digital,
            // The T is the thermal core. Modelling this turret as a visible-light camera alone was
            // simply wrong: it is a hybrid, and the operator is meant to switch between the zoom
            // camera and the radiometric channel in flight.
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                sensorWidthMM: 7.4,
                focalLengthMM: 6.83,
                maximumOpticalZoom: 23,
                horizontalResolution: 3840,
                verticalResolution: 2160,
                barrelDistortion: 0.10,
                baseNoise: 0.14,
                dynamicRangeStops: 11.0,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.42,
                    responseSeconds: 0.35,
                    gainUpStops: 2.2,
                    gainDownStops: 5.5
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.10,
                    blackLift: 0.02,
                    edgeEnhancement: 0.25
                )
            ),
            additionalChannels: [
                CameraChannelSpec(
                    channel: .thermal,
                    spectrum: .longwaveInfrared,
                    shutter: .global,
                    specConfidence: .estimated,
                    // 640x512 at a 12 um pitch is a 7.68 mm focal plane; DJI publish a 13.5 mm
                    // lens on it, which puts the horizontal coverage at 31.7 degrees.
                    sensorWidthMM: 7.68,
                    focalLengthMM: 13.5,
                    // The turret's 8x on this channel is digital, so it buys no coverage and is
                    // deliberately not modelled as optics.
                    maximumOpticalZoom: 1,
                    horizontalResolution: 640,
                    verticalResolution: 512,
                    barrelDistortion: 0.05,
                    baseNoise: 0.20,
                    dynamicRangeStops: 14.0,
                    autoExposure: CameraAutoExposure(
                        // A thermal core runs continuous AGC, and its range is enormous: it has to
                        // map whatever scene temperatures it finds onto 8 bits.
                        targetLevel: 0.46,
                        responseSeconds: 0.25,
                        gainUpStops: 4.0,
                        gainDownStops: 4.5
                    ),
                    colorResponse: CameraColorResponse(
                        whiteBalanceBias: 0.0,
                        saturation: 1.0,
                        blackLift: 0.0,
                        // Digital detail enhancement — the edge sharpening a thermal AGC applies.
                        edgeEnhancement: 0.35
                    )
                ),
            ],
            massKg: 0.828
        ),
        CameraModule(
            id: "dji-zenmuse-h30t",
            displayName: "Zenmuse H30T",
            manufacturer: "DJI",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                sensorWidthMM: 7.4,
                focalLengthMM: 6.7,
                maximumOpticalZoom: 34,
                horizontalResolution: 3840,
                verticalResolution: 2160,
                barrelDistortion: 0.09,
                baseNoise: 0.11,
                dynamicRangeStops: 12.0,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.42,
                    responseSeconds: 0.30,
                    gainUpStops: 2.4,
                    gainDownStops: 5.5
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.08,
                    blackLift: 0.02,
                    edgeEnhancement: 0.22
                )
            ),
            additionalChannels: [
                CameraChannelSpec(
                    channel: .thermal,
                    spectrum: .longwaveInfrared,
                    shutter: .global,
                    specConfidence: .estimated,
                    // 1280x1024 at 12 um gives a 15.36 mm focal plane; the focal length is derived
                    // from the published 45.5 degree diagonal, so it is marked estimated.
                    sensorWidthMM: 15.36,
                    focalLengthMM: 23.45,
                    maximumOpticalZoom: 1,
                    horizontalResolution: 1280,
                    verticalResolution: 1024,
                    barrelDistortion: 0.05,
                    baseNoise: 0.16,
                    dynamicRangeStops: 14.0,
                    autoExposure: CameraAutoExposure(
                        targetLevel: 0.46,
                        responseSeconds: 0.25,
                        gainUpStops: 4.0,
                        gainDownStops: 4.5
                    ),
                    colorResponse: CameraColorResponse(
                        whiteBalanceBias: 0.0,
                        saturation: 1.0,
                        blackLift: 0.0,
                        edgeEnhancement: 0.35
                    )
                ),
            ],
            massKg: 0.920
        ),
        CameraModule(
            id: "flir-boson-640",
            displayName: "Boson 640 LWIR",
            manufacturer: "Teledyne FLIR",
            videoOutput: .digital,
            // An uncooled microbolometer core, and nothing else. There is no visible-light channel
            // to switch to, which is why this one is locked to thermal.
            primaryChannel: CameraChannelSpec(
                channel: .thermal,
                spectrum: .longwaveInfrared,
                shutter: .global,
                specConfidence: .verified,
                // 640x512 at a 12 um pitch gives a 7.68 mm wide focal plane.
                sensorWidthMM: 7.68,
                focalLengthMM: 8.7,
                maximumOpticalZoom: 1,
                horizontalResolution: 640,
                verticalResolution: 512,
                barrelDistortion: 0.16,
                baseNoise: 0.22,
                dynamicRangeStops: 14.0,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.46,
                    responseSeconds: 0.20,
                    gainUpStops: 4.0,
                    gainDownStops: 4.5
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.0,
                    blackLift: 0.0,
                    edgeEnhancement: 0.40
                )
            ),
            massKg: 0.075
        ),
        CameraModule(
            id: "sony-rx1r-ii",
            displayName: "RX1R II",
            manufacturer: "Sony",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .verified,
                // Full frame, fixed 35 mm prime. The Wingtra payload kit weighs 590 g installed.
                sensorWidthMM: 35.9,
                focalLengthMM: 35.0,
                maximumOpticalZoom: 1,
                horizontalResolution: 7952,
                verticalResolution: 5304,
                barrelDistortion: 0.02,
                baseNoise: 0.05,
                dynamicRangeStops: 13.5,
                autoExposure: CameraAutoExposure(
                    // A stills camera is deliberate rather than quick.
                    targetLevel: 0.42,
                    responseSeconds: 0.60,
                    gainUpStops: 2.6,
                    gainDownStops: 6.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.00,
                    blackLift: 0.0,
                    edgeEnhancement: 0.05
                )
            ),
            massKg: 0.590
        ),
        CameraModule(
            id: "sony-a6100",
            displayName: "Alpha 6100",
            manufacturer: "Sony",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .verified,
                sensorWidthMM: 23.5,
                focalLengthMM: 20.0,
                maximumOpticalZoom: 1,
                horizontalResolution: 6000,
                verticalResolution: 4000,
                barrelDistortion: 0.05,
                baseNoise: 0.08,
                dynamicRangeStops: 13.0,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.42,
                    responseSeconds: 0.45,
                    gainUpStops: 2.4,
                    gainDownStops: 5.5
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.02,
                    saturation: 1.05,
                    blackLift: 0.0,
                    edgeEnhancement: 0.10
                )
            ),
            massKg: 0.470
        ),
        CameraModule(
            id: "micasense-rededge-p",
            displayName: "RedEdge-P",
            manufacturer: "MicaSense",
            videoOutput: .digital,
            // Narrow visible and red-edge/NIR bands, no thermal band — that is the Altum-PT, a
            // different head. So this one offers the optical channel only.
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .multispectral,
                // Band-to-band alignment is the whole point of a multispectral head, so these use
                // a global shutter; a rolling one would smear the bands against each other.
                shutter: .global,
                specConfidence: .estimated,
                sensorWidthMM: 5.5,
                focalLengthMM: 5.4,
                maximumOpticalZoom: 1,
                horizontalResolution: 1456,
                verticalResolution: 1088,
                barrelDistortion: 0.07,
                baseNoise: 0.12,
                dynamicRangeStops: 12.0,
                autoExposure: CameraAutoExposure(
                    // Band irradiance has to stay comparable between frames, so the loop is slow
                    // and narrow on purpose.
                    targetLevel: 0.44,
                    responseSeconds: 0.50,
                    gainUpStops: 1.6,
                    gainDownStops: 5.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.0,
                    blackLift: 0.0,
                    edgeEnhancement: 0.0
                )
            ),
            massKg: 0.232
        ),
        CameraModule(
            id: "cinema-super35",
            displayName: "Super 35 cinema camera",
            manufacturer: "Generic",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .global,
                specConfidence: .estimated,
                // What a heavy-lift platform like the Alta X is actually built to carry.
                sensorWidthMM: 27.0,
                focalLengthMM: 24.0,
                maximumOpticalZoom: 1,
                horizontalResolution: 6144,
                verticalResolution: 3240,
                barrelDistortion: 0.03,
                baseNoise: 0.04,
                dynamicRangeStops: 16.0,
                // Shot on manual exposure, like the real thing: the range is zero, so the picture
                // simply is what the light gives it.
                autoExposure: .manual,
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: -0.03,
                    saturation: 0.95,
                    // A log curve lifts the blacks so the grade has something to pull down.
                    blackLift: 0.04,
                    edgeEnhancement: 0.0
                )
            ),
            massKg: 2.100
        ),
    ]

    /// Cameras the pilot flies from, as opposed to the ones the mission is flown for.
    ///
    /// A pilot's camera is bolted to the airframe: on a fleet aircraft it is whatever the
    /// manufacturer fitted, and on a build it is whatever went into the Workbench camera slot. It
    /// is never a payload, and it is never on a gimbal — which is exactly why its lens bows, its
    /// sensor is small and its auto-exposure has to be quick.
    static let fpvCameras: [CameraModule] = [
        CameraModule(
            id: "fpv-analog-micro",
            displayName: "FPV Micro 1000TVL",
            manufacturer: "VisionLab",
            videoOutput: .analogComposite,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                // 1/3" behind a 1.8 mm lens. The shortest focal length in the catalogue, on the
                // smallest sensor: the widest, most bowed and noisiest picture there is.
                sensorWidthMM: 4.8,
                focalLengthMM: 1.8,
                maximumOpticalZoom: 1,
                horizontalResolution: 1200,
                verticalResolution: 960,
                barrelDistortion: 0.85,
                baseNoise: 0.40,
                dynamicRangeStops: 8.0,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.46,
                    responseSeconds: 0.12,
                    gainUpStops: 1.1,
                    gainDownStops: 4.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.18,
                    saturation: 1.30,
                    blackLift: 0.08,
                    edgeEnhancement: 0.60
                )
            ),
            massKg: 0.0035
        ),
        CameraModule(
            id: "fpv-analog-nano",
            displayName: "FPV Nano 1200TVL",
            manufacturer: "VisionLab",
            videoOutput: .analogComposite,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                // A 1/2" sensor takes a longer lens than a 1/3" one to reach the same coverage;
                // pairing every sensor with the same 2.1 mm lens made the bigger ones absurdly wide.
                sensorWidthMM: 6.4,
                focalLengthMM: 2.5,
                maximumOpticalZoom: 1,
                horizontalResolution: 1280,
                verticalResolution: 960,
                barrelDistortion: 0.78,
                baseNoise: 0.30,
                dynamicRangeStops: 9.0,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.45,
                    responseSeconds: 0.15,
                    gainUpStops: 1.3,
                    gainDownStops: 4.5
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.12,
                    saturation: 1.22,
                    blackLift: 0.06,
                    edgeEnhancement: 0.55
                )
            ),
            massKg: 0.008
        ),
        CameraModule(
            id: "fpv-analog-starlight",
            displayName: "FPV Starlight",
            manufacturer: "VisionLab",
            videoOutput: .analogComposite,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                // A big-pixel low-light sensor. Half the noise of the nano and two more stops of
                // latitude, at the cost of a slower loop and shadows it deliberately lifts.
                sensorWidthMM: 7.2,
                focalLengthMM: 3.0,
                maximumOpticalZoom: 1,
                horizontalResolution: 1280,
                verticalResolution: 960,
                barrelDistortion: 0.75,
                baseNoise: 0.16,
                dynamicRangeStops: 10.5,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.44,
                    responseSeconds: 0.22,
                    gainUpStops: 2.0,
                    gainDownStops: 5.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.05,
                    saturation: 1.12,
                    blackLift: 0.10,
                    edgeEnhancement: 0.45
                )
            ),
            massKg: 0.010
        ),
        CameraModule(
            id: "fpv-digital-mini",
            displayName: "HD Link Mini",
            manufacturer: "VisionLab",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                sensorWidthMM: 5.4,
                focalLengthMM: 2.2,
                maximumOpticalZoom: 1,
                horizontalResolution: 1920,
                verticalResolution: 1080,
                barrelDistortion: 0.70,
                baseNoise: 0.18,
                dynamicRangeStops: 10.0,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.43,
                    responseSeconds: 0.25,
                    gainUpStops: 2.0,
                    gainDownStops: 5.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.10,
                    blackLift: 0.02,
                    edgeEnhancement: 0.30
                )
            ),
            massKg: 0.012
        ),
        CameraModule(
            id: "fpv-digital",
            displayName: "HD Link Camera",
            manufacturer: "VisionLab",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                sensorWidthMM: 7.6,
                focalLengthMM: 2.85,
                maximumOpticalZoom: 1,
                horizontalResolution: 3840,
                verticalResolution: 2160,
                barrelDistortion: 0.62,
                baseNoise: 0.09,
                dynamicRangeStops: 12.5,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.42,
                    responseSeconds: 0.30,
                    gainUpStops: 2.2,
                    gainDownStops: 5.5
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.05,
                    blackLift: 0.0,
                    edgeEnhancement: 0.20
                )
            ),
            massKg: 0.024
        ),
        CameraModule(
            id: "fpv-digital-lowlight",
            displayName: "HD Night Vision FPV",
            manufacturer: "VisionLab",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                // The orientation camera an enterprise platform carries: a big-pixel low-light
                // sensor on a digital link, tuned for a usable picture rather than for latency.
                sensorWidthMM: 7.2,
                focalLengthMM: 2.9,
                maximumOpticalZoom: 1,
                horizontalResolution: 1920,
                verticalResolution: 1080,
                barrelDistortion: 0.55,
                baseNoise: 0.10,
                dynamicRangeStops: 11.5,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.42,
                    responseSeconds: 0.28,
                    gainUpStops: 3.0,
                    gainDownStops: 5.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.05,
                    blackLift: 0.0,
                    edgeEnhancement: 0.15
                )
            ),
            massKg: 0.018
        ),
        CameraModule(
            id: "fpv-action-mini",
            displayName: "Action Mini 4K",
            manufacturer: "ActionCam",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                sensorWidthMM: 6.2,
                focalLengthMM: 2.6,
                maximumOpticalZoom: 1,
                horizontalResolution: 3840,
                verticalResolution: 2160,
                barrelDistortion: 0.55,
                baseNoise: 0.13,
                dynamicRangeStops: 11.5,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.42,
                    responseSeconds: 0.35,
                    gainUpStops: 2.0,
                    gainDownStops: 5.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.15,
                    blackLift: 0.02,
                    edgeEnhancement: 0.28
                )
            ),
            massKg: 0.035
        ),
        CameraModule(
            id: "fpv-action",
            displayName: "Action 4K",
            manufacturer: "ActionCam",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                shutter: .rolling,
                specConfidence: .estimated,
                sensorWidthMM: 7.6,
                focalLengthMM: 3.4,
                maximumOpticalZoom: 1,
                horizontalResolution: 3840,
                verticalResolution: 2160,
                barrelDistortion: 0.45,
                baseNoise: 0.09,
                dynamicRangeStops: 12.5,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.42,
                    responseSeconds: 0.35,
                    gainUpStops: 2.2,
                    gainDownStops: 5.5
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.12,
                    blackLift: 0.02,
                    edgeEnhancement: 0.22
                )
            ),
            massKg: 0.074
        ),
        CameraModule(
            id: "fpv-mapping-24mp",
            displayName: "Mapping 24 MP",
            manufacturer: "GeoVision",
            videoOutput: .digital,
            primaryChannel: CameraChannelSpec(
                channel: .optical,
                spectrum: .visibleLight,
                // Global shutter: a mapping frame with skewed verticals is not much use as a
                // measurement.
                shutter: .global,
                specConfidence: .estimated,
                sensorWidthMM: 23.5,
                focalLengthMM: 21.0,
                maximumOpticalZoom: 1,
                horizontalResolution: 6000,
                verticalResolution: 4000,
                barrelDistortion: 0.05,
                baseNoise: 0.08,
                dynamicRangeStops: 13.0,
                autoExposure: CameraAutoExposure(
                    targetLevel: 0.42,
                    responseSeconds: 0.50,
                    gainUpStops: 1.8,
                    gainDownStops: 5.0
                ),
                colorResponse: CameraColorResponse(
                    whiteBalanceBias: 0.0,
                    saturation: 1.0,
                    blackLift: 0.0,
                    edgeEnhancement: 0.05
                )
            ),
            massKg: 0.145
        ),
    ]

    /// Workbench part IDs are persisted in saved builds, so they are mapped here rather than
    /// renamed to match the modules.
    private static let workbenchCameraModuleIDs: [String: String] = [
        "camera-fpv-micro": "fpv-analog-micro",
        "camera-fpv": "fpv-analog-nano",
        "camera-fpv-lowlight": "fpv-analog-starlight",
        "camera-hd-mini": "fpv-digital-mini",
        "camera-hd": "fpv-digital",
        "camera-action-mini": "fpv-action-mini",
        "camera-action": "fpv-action",
        "camera-mapping-24mp": "fpv-mapping-24mp",
    ]

    static func module(id: String) -> CameraModule? {
        modules.first { $0.id == id }
    }

    static func fpvCamera(id: String) -> CameraModule? {
        fpvCameras.first { $0.id == id }
    }

    /// The pilot's camera a Workbench build ends up with, from the part in its camera slot.
    static func fpvCamera(workbenchSpecID: String) -> CameraModule? {
        workbenchCameraModuleIDs[workbenchSpecID].flatMap(fpvCamera(id:))
    }

    /// Modules light enough for an airframe's remaining payload budget.
    static func modules(fittingWithinMassKg limit: Double) -> [CameraModule] {
        modules.filter { $0.massKg <= limit + 0.0001 }
    }
}
