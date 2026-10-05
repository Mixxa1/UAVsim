import AppKit
import QuartzCore
import SceneKit
import simd

/// Scene imagery stays on the GPU. Thermal colours are calculated per fragment, using the
/// original UVs for material hints and world coordinates for stable temperature gradients.
/// No readback, image decoding or per-building bitmap generation runs on the UI thread.
final class ThermalImportedSurfaceMaterials {
    struct Key: Hashable {
        let sourceID: ObjectIdentifier
        let materialClass: ThermalMaterialClass
    }

    private struct Entry {
        // Retain the source while cached: its ObjectIdentifier must not be reused after eviction.
        let source: SCNMaterial
        let material: SCNMaterial
        var references: Int
    }

    private struct Inputs: Equatable {
        let temperatures: [Double]
        let responses: [ThermalMaterialModel.SurfaceResponse]
        let sunDirections: [SIMD3<Double>]
        let ambient: Double
        let sky: Double
        let extinction: Double
        let palette: ThermalPalette
        let displayMin: Double
        let displaySpan: Double
        let contrast: Double
        let brightness: Double
        let noise: Double

        init(context: ThermalEnvironmentContext, palette: ThermalPalette,
             normalization: ThermalNormalizationState, contrast: Double, brightness: Double, noise: Double) {
            // Quantize time, not surface position: five simulated minutes are small enough for
            // continuous heating, without rebinding thousands of materials every simulation tick.
            var sampledContext = context
            sampledContext.timeOfDayHours = (context.timeOfDayHours * 12).rounded() / 12
            temperatures = ThermalMaterialClass.allCases.map {
                ThermalMaterialModel.meanTemperature(for: $0, context: sampledContext)
            }
            responses = ThermalMaterialClass.allCases.map {
                ThermalMaterialModel.surfaceResponse(for: $0, context: sampledContext)
            }
            sunDirections = [0.0, -2, -4].map {
                ThermalMaterialModel.sunDirection(at: sampledContext.timeOfDayHours + $0)
            }
            ambient = context.ambientTemperatureCelsius
            sky = ThermalMaterialModel.skyTemperature(context: context)
            extinction = ThermalMaterialModel.atmosphericExtinction(context: context)
            self.palette = palette
            displayMin = (normalization.displayMinCelsius * 10).rounded() / 10
            displaySpan = max(0.5, (normalization.spanCelsius * 10).rounded() / 10)
            self.contrast = contrast
            self.brightness = brightness
            self.noise = min(1, max(0, noise))
        }

        func temperature(_ cls: ThermalMaterialClass) -> Double {
            temperatures[ThermalMaterialClass.allCases.firstIndex(of: cls)!]
        }

        func response(_ cls: ThermalMaterialClass) -> ThermalMaterialModel.SurfaceResponse {
            responses[ThermalMaterialClass.allCases.firstIndex(of: cls)!]
        }
    }

    private var entries: [Key: Entry] = [:]
    private var inputs: Inputs?
    private var pendingUniformKeys: [Key] = []
    private var pendingUniformSet: Set<Key> = []
    private var pendingUniformCursor = 0
    private(set) var uniformUpdateCount = 0
    var count: Int { entries.count }
    var hasPendingUniformUpdates: Bool { pendingUniformCursor < pendingUniformKeys.count }

    func acquire(source: SCNMaterial, materialClass: ThermalMaterialClass) -> (Key, SCNMaterial) {
        let key = Key(sourceID: ObjectIdentifier(source), materialClass: materialClass)
        if var entry = entries[key] {
            entry.references += 1
            entries[key] = entry
            return (key, entry.material)
        }
        let material = source.copy() as! SCNMaterial
        material.lightingModel = .constant
        material.normal.contents = nil
        material.multiply.contents = nil
        material.emission.contents = NSColor.black
        material.specular.contents = NSColor.black
        material.ambient.contents = NSColor.black
        material.ambientOcclusion.contents = nil
        // Keep every source material slot, texture transform, wrap mode and alpha channel.
        // A texture is a useful material hint; flat OSM colours already have a classified class.
        let hasImagery = source.diffuse.contents != nil && !(source.diffuse.contents is NSColor)
        let imageryWeight: Double = [.generic, .terrain, .bareSoil].contains(materialClass) ? 1 : 0
        material.setValue(NSNumber(value: hasImagery ? imageryWeight : 0), forKey: "thermalImageryWeight")
        material.setValue(NSNumber(value: ThermalMaterialModel.properties(for: materialClass).variationAmplitudeCelsius),
                          forKey: "thermalAmplitude")
        material.setValue(NSNumber(value: materialClass == .building ? 1.0 : 0.0), forKey: "thermalBuilding")
        material.setValue(NSNumber(value: 1.0), forKey: "thermalPhysicalEnabled")
        let glazingMask = UAVWorldFacadeMaterialFactory.thermalGlazingMask(for: source.name)
        material.setValue(NSNumber(value: glazingMask != nil ? 1.0 : 0.0), forKey: "thermalHasGlazingMask")
        material.shaderModifiers = [.geometry: Self.geometryShader(hasGlazing: glazingMask != nil),
                                    .surface: Self.surfaceShader(hasGlazing: glazingMask != nil)]
        // Explicit sampling: constant lighting can omit built-in texture coordinates/channels.
        // Transfer raw mesh UVs and apply the same transform as the visible facade texture.
        if let glazingMask {
            material.setValue(SCNMaterialProperty(contents: glazingMask), forKey: "thermalGlazingTexture")
            let uv = source.diffuse.contentsTransform
            material.setValue(NSValue(scnVector3: SCNVector3(uv.m11, uv.m21, uv.m41)), forKey: "thermalUVRowU")
            material.setValue(NSValue(scnVector3: SCNVector3(uv.m12, uv.m22, uv.m42)), forKey: "thermalUVRowV")
            material.setValue(NSValue(scnVector3: SCNVector3(uv.m14, uv.m24, uv.m44)), forKey: "thermalUVRowW")
        }
        entries[key] = Entry(source: source, material: material, references: 1)
        if let inputs { apply(inputs, to: material, materialClass: materialClass) }
        return (key, material)
    }

    func release(_ key: Key) {
        guard var entry = entries[key] else { return }
        entry.references -= 1
        entries[key] = entry.references > 0 ? entry : nil
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        pendingUniformKeys.removeAll(keepingCapacity: true)
        pendingUniformSet.removeAll(keepingCapacity: true)
        pendingUniformCursor = 0
        inputs = nil
    }

    func update(context: ThermalEnvironmentContext, palette: ThermalPalette,
                normalization: ThermalNormalizationState, contrast: Double, brightness: Double, noise: Double) {
        let next = Inputs(context: context, palette: palette, normalization: normalization,
                          contrast: contrast, brightness: brightness, noise: noise)
        if inputs != next {
            inputs = next
            // FIFO prevents frequently changing weather/time from starving the oldest tiles.
            for key in entries.keys where pendingUniformSet.insert(key).inserted {
                pendingUniformKeys.append(key)
            }
        }
        let deadline = CACurrentMediaTime() + 0.003
        for _ in 0..<64 {
            guard CACurrentMediaTime() < deadline, hasPendingUniformUpdates else { break }
            let key = pendingUniformKeys[pendingUniformCursor]
            pendingUniformCursor += 1
            pendingUniformSet.remove(key)
            if let entry = entries[key] { apply(next, to: entry.material, materialClass: key.materialClass) }
        }
        if !hasPendingUniformUpdates {
            pendingUniformKeys.removeAll(keepingCapacity: true)
            pendingUniformCursor = 0
        } else if pendingUniformCursor > 2048 {
            pendingUniformKeys.removeFirst(pendingUniformCursor)
            pendingUniformCursor = 0
        }
    }

    private func apply(_ inputs: Inputs, to material: SCNMaterial, materialClass: ThermalMaterialClass) {
        let values: [(String, Double)] = [
            ("thermalBase", inputs.response(materialClass).baseCelsius),
            ("thermalNoise", inputs.noise),
            ("thermalEmissivity", inputs.response(materialClass).emissivity),
            ("thermalDiffuseFraction", inputs.response(materialClass).diffuseFraction),
            ("thermalAmbient", inputs.ambient), ("thermalSky", inputs.sky),
            ("thermalExtinction", inputs.extinction),
            ("thermalPalette", inputs.palette == .iron ? 2 : (inputs.palette == .blackHot ? 1 : 0))
        ]
        for (key, value) in values { material.setValue(NSNumber(value: value), forKey: key) }
        func vector(_ v: SIMD3<Double>) -> NSValue {
            NSValue(scnVector3: SCNVector3(v.x, v.y, v.z))
        }
        // SceneKit assigns a Metal buffer slot to each argument; pack related scalars to stay
        // below Metal's 31-buffer limit, including SceneKit's own frame/node/material buffers.
        material.setValue(NSValue(scnVector4: SCNVector4(inputs.temperature(.grass), inputs.temperature(.water),
            inputs.temperature(.asphalt), inputs.temperature(.concrete))), forKey: "thermalGroundTemperatures")
        material.setValue(NSValue(scnVector4: SCNVector4(inputs.displayMin, inputs.displaySpan,
            inputs.contrast, inputs.brightness)), forKey: "thermalDisplay")
        material.setValue(vector(inputs.response(materialClass).solar), forKey: "thermalSolar")
        for (index, direction) in inputs.sunDirections.enumerated() {
            material.setValue(vector(direction), forKey: "thermalSun\(index)")
        }
        for (name, cls) in [("thermalRoofResponse", ThermalMaterialClass.roof),
                            ("thermalGlassResponse", .glass), ("thermalWallResponse", .building)] {
            let r = inputs.response(cls)
            material.setValue(NSValue(scnVector4: SCNVector4(r.baseCelsius, r.solar.x, r.solar.y, r.solar.z)), forKey: name)
        }
        uniformUpdateCount += 1
    }

    // Constant-lighting shaders do not reliably initialize _surface.view/geometryNormal.
    // Export the mesh normal explicitly, with the inverse-transpose transform for scaled meshes.
    private static func geometryShader(hasGlazing: Bool) -> String { """
    #pragma varyings
    float3 thermalWorldPosition;
    float3 thermalWorldNormal;
    float2 thermalUV;
    #pragma body
    out.thermalWorldPosition = (scn_node.modelTransform * _geometry.position).xyz;
    out.thermalWorldNormal = (scn_frame.inverseViewTransform * scn_node.normalTransform
        * float4(_geometry.normal, 0.0)).xyz;
    out.thermalUV = \(hasGlazing ? "_geometry.texcoords[0]" : "float2(0.0)");
    """ }

    // Binding even a dummy custom texture makes SceneKit require a UV vertex attribute.
    // Only semantic facades need this sampler; plain meshes must retain a texture-free path.
    private static func surfaceShader(hasGlazing: Bool) -> String {
        hasGlazing ? glazingSurfaceShader : plainSurfaceShader
    }

    private static let glazingSurfaceShader = makeSurfaceShader(hasGlazing: true)
    private static let plainSurfaceShader = makeSurfaceShader(hasGlazing: false)

    private static func makeSurfaceShader(hasGlazing: Bool) -> String {
        surfaceShaderTemplate.replacingOccurrences(of: "__GLAZING_ARGUMENTS__", with: hasGlazing ? """
        texture2d<float> thermalGlazingTexture;
        float3 thermalUVRowU;
        float3 thermalUVRowV;
        float3 thermalUVRowW;
        """ : "").replacingOccurrences(of: "__GLAZING_SAMPLE__", with: hasGlazing ? glazingSampleShader : "float glazing = 0.0;")
    }

    private static let glazingSampleShader = """
    constexpr sampler glazingSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    float3 thermalMeshUV = float3(in.thermalUV, 1.0);
    float thermalUVHomogeneous = dot(thermalUVRowW, thermalMeshUV);
    float2 glazingUV = float2(dot(thermalUVRowU, thermalMeshUV), dot(thermalUVRowV, thermalMeshUV))
        / (abs(thermalUVHomogeneous) < 0.000001 ? 1.0 : thermalUVHomogeneous);
    float glazing = thermalGlazingTexture.sample(glazingSampler, glazingUV).r * vertical;
    """

    private static let surfaceShaderTemplate = """
    #pragma arguments
    float thermalBase;
    float4 thermalGroundTemperatures;
    float4 thermalDisplay;
    float thermalNoise;
    float thermalPalette;
    float thermalImageryWeight;
    float thermalAmplitude;
    float thermalPhysicalEnabled;
    float thermalBuilding;
    float thermalHasGlazingMask;
    __GLAZING_ARGUMENTS__
    float3 thermalSolar;
    float3 thermalSun0;
    float3 thermalSun1;
    float3 thermalSun2;
    float4 thermalRoofResponse;
    float4 thermalGlassResponse;
    float4 thermalWallResponse;
    float thermalEmissivity;
    float thermalDiffuseFraction;
    float thermalAmbient;
    float thermalSky;
    float thermalExtinction;
    #pragma body
    float thermalGrass = thermalGroundTemperatures.x;
    float thermalWater = thermalGroundTemperatures.y;
    float thermalAsphalt = thermalGroundTemperatures.z;
    float thermalConcrete = thermalGroundTemperatures.w;
    float thermalMin = thermalDisplay.x;
    float thermalSpan = thermalDisplay.y;
    float thermalContrast = thermalDisplay.z;
    float thermalBrightness = thermalDisplay.w;
    float3 world = in.thermalWorldPosition;
    float3 toCamera = scn_frame.inverseViewTransform[3].xyz - world;
    float3 view = normalize(toCamera);
    // Some simplified/scanned meshes contain positions but no normal source. Recover the
    // triangle direction on the GPU instead of feeding normalize(0) into the radiance model.
    float3 normal = in.thermalWorldNormal;
    if (!all(isfinite(normal)) || dot(normal, normal) < 0.000001) {
        normal = cross(dfdx(world), dfdy(world));
        if (dot(normal, view) < 0.0) normal = -normal;
    }
    normal = dot(normal, normal) > 0.000001 ? normalize(normal) : float3(0.0, 1.0, 0.0);
    // Imagery helps identify materials, never acts as a temperature photograph. A dark patch
    // in visible light need not be cold in LWIR (asphalt is a common counterexample).
    float3 linear = max(_surface.diffuse.rgb, float3(0.0));
    float3 rgb = mix(linear * 12.92, 1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055,
                     step(float3(0.0031308), linear));
    float luminance = dot(rgb, float3(0.299, 0.587, 0.114));
    float vertical = 1.0 - smoothstep(0.25, 0.65, abs(normal.y));
    float temperature = thermalBase;
    float epsilon = thermalEmissivity;
    float diffuseFraction = thermalDiffuseFraction;
    if (thermalPhysicalEnabled > 0.5) {
        float3 incidence = max(float3(0.0), float3(dot(normal, thermalSun0),
            dot(normal, thermalSun1), dot(normal, thermalSun2)));
        // Roofs and walls can share an imported mesh/material: upward-facing building fragments
        // still respond as roofs. Dedicated roof slots bypass this fallback.
        float roof = thermalBuilding * smoothstep(0.65, 0.90, normal.y);
        float unknownWall = thermalImageryWeight * vertical;
        float3 solar = mix(thermalSolar, thermalWallResponse.yzw, unknownWall);
        temperature = mix(temperature, thermalWallResponse.x, unknownWall);
        solar = mix(solar, thermalRoofResponse.yzw, roof);
        temperature = mix(temperature, thermalRoofResponse.x, roof);
        float absorption = mix(1.0, 1.15 - 0.35 * luminance, max(thermalBuilding, thermalImageryWeight));
        temperature += dot(solar, incidence) * absorption;
        if (thermalImageryWeight > 0.0) {
            float hint = temperature;
            // Ground hints are gated by orientation, so blue/dark facade windows are never
            // classified as water or asphalt. Photogrammetry without semantic labels remains
            // an approximation; its RGB darkness contributes only a small residual detail.
            if (rgb.g > rgb.r * 1.18 && rgb.g > rgb.b * 1.18) {
                hint = thermalGrass;
            } else if (vertical < 0.4 && rgb.b > rgb.r * 1.20 && rgb.b > rgb.g * 1.05) {
                hint = thermalWater;
            } else if (vertical < 0.4 && max(rgb.r, max(rgb.g, rgb.b)) < 0.16) {
                hint = thermalAsphalt;
            } else if (vertical < 0.4 && max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b)) < 0.15) {
                hint = thermalConcrete;
            }
            temperature = mix(temperature, hint, thermalImageryWeight);
            temperature += (luminance - 0.5) * 0.5 * thermalImageryWeight;
        }
        __GLAZING_SAMPLE__
        if (thermalHasGlazingMask < 0.5 && (thermalBuilding > 0.5 || thermalImageryWeight > 0.5)) {
            // Conservative fallback for photographic windows; the generated city uses its
            // exact semantic mask instead, including mullions and frames.
            glazing = vertical * smoothstep(0.02, 0.10, rgb.b - rgb.r)
                * (1.0 - smoothstep(0.24, 0.42, luminance));
        }
        float glassTemperature = thermalGlassResponse.x + dot(thermalGlassResponse.yzw, incidence);
        temperature = mix(temperature, glassTemperature, glazing);
        epsilon = mix(epsilon, 0.92, glazing);
        diffuseFraction = mix(diffuseFraction, 0.03, glazing);
    }
    // Smooth, aperiodic patches in metres, with no time input or per-building images.
    // Integer hashes avoid the repeated diagonal waves and expensive trigonometric noise.
    float patches = 0.0;
    if (thermalNoise > 0.0) {
        for (int octave = 0; octave < 2; ++octave) {
            float3 point = world * (octave == 0 ? 0.035 : 0.14) + float3(17.3, 41.7, 9.2);
            int3 cell = int3(floor(point));
            float3 blend = fract(point);
            blend = blend * blend * (3.0 - 2.0 * blend);
            float value = 0.0;
            for (int corner = 0; corner < 8; ++corner) {
                int3 side = int3(corner & 1, (corner >> 1) & 1, corner >> 2);
                uint3 lattice = uint3(cell + side);
                uint hash = lattice.x * 374761393u ^ lattice.y * 668265263u ^ lattice.z * 2246822519u;
                hash = (hash ^ (hash >> 13)) * 1274126177u;
                hash ^= hash >> 16;
                float3 weight = mix(1.0 - blend, blend, float3(side));
                value += (float(hash & 65535u) / 65535.0) * weight.x * weight.y * weight.z;
            }
            patches += (value * 2.0 - 1.0) * (octave == 0 ? 0.75 : 0.25);
        }
    }
    temperature += patches * thermalAmplitude * thermalNoise;
    if (thermalPhysicalEnabled > 0.5) {
        // Emission and reflected surroundings are mixed in radiance, not degrees Celsius.
        // At grazing incidence glass/metal reflect much more. The environment is a cheap
        // sky/ground hemisphere approximation; no ray tracing or CPU texture reads occur.
        float cosView = saturate(abs(dot(normal, view)));
        epsilon *= 1.0 - (1.0 - diffuseFraction) * pow(1.0 - cosView, 5.0);
        float3 reflection = 2.0 * dot(normal, view) * normal - view;
        float skyFraction = saturate((reflection.y + 0.05) / 0.65);
        float skyRadiance = 1.0 / (exp(1438.8 / max(100.0, thermalSky + 273.15)) - 1.0);
        float ambientRadiance = 1.0 / (exp(1438.8 / max(100.0, thermalAmbient + 273.15)) - 1.0);
        float surroundings = 1.0 / (exp(1438.8 / max(100.0, thermalAmbient + 275.15)) - 1.0);
        float reflected = mix(mix(surroundings, skyRadiance, skyFraction),
            mix(surroundings, skyRadiance, 0.25), diffuseFraction);
        float emitted = 1.0 / (exp(1438.8 / max(100.0, temperature + 273.15)) - 1.0);
        float transmission = exp(-length(toCamera) * thermalExtinction);
        float received = mix(ambientRadiance, mix(reflected, emitted, epsilon), transmission);
        temperature = 1438.8 / log(1.0 + 1.0 / max(0.000001, received)) - 273.15;
    }
    float t = saturate((temperature - thermalMin) / thermalSpan);
    t = saturate((t - 0.5) * thermalContrast + 0.5 + thermalBrightness);
    t = t * t * (3.0 - 2.0 * t);
    float3 color = float3(0.03 + 0.95 * t);
    if (thermalPalette > 1.5) {
        if (t < 0.18) color = mix(float3(0.03, 0.03, 0.16), float3(0.16, 0.06, 0.36), t / 0.18);
        else if (t < 0.36) color = mix(float3(0.16, 0.06, 0.36), float3(0.45, 0.10, 0.45), (t - 0.18) / 0.18);
        else if (t < 0.52) color = mix(float3(0.45, 0.10, 0.45), float3(0.74, 0.16, 0.34), (t - 0.36) / 0.16);
        else if (t < 0.66) color = mix(float3(0.74, 0.16, 0.34), float3(0.91, 0.34, 0.14), (t - 0.52) / 0.14);
        else if (t < 0.80) color = mix(float3(0.91, 0.34, 0.14), float3(0.98, 0.62, 0.12), (t - 0.66) / 0.14);
        else if (t < 0.92) color = mix(float3(0.98, 0.62, 0.12), float3(1.00, 0.86, 0.30), (t - 0.80) / 0.12);
        else color = mix(float3(1.00, 0.86, 0.30), float3(1.00, 0.98, 0.86), (t - 0.92) / 0.08);
    } else if (thermalPalette > 0.5) {
        color = float3(0.98 - 0.95 * t);
    }
    // The ramp is sRGB. Shader outputs must be linear, otherwise SceneKit encodes it twice,
    // washing out both monochrome modes and turning ironbow into pale pink.
    _surface.diffuse.rgb = mix(color / 12.92, pow((color + 0.055) / 1.055, float3(2.4)),
                              step(float3(0.04045), color));
    _surface.emission = float4(0.0);
    """
}
