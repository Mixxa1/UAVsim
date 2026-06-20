#include <metal_stdlib>
using namespace metal;

struct WeatherDOFVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// DRAW_QUAD passes don't feed SceneKit-semantic vertex attributes the way DRAW_SCENE does —
// generate the full-screen triangle strip procedurally from vertex_id instead of relying on a
// stage_in struct (which only works for real scene geometry with SCNGeometrySource data).
vertex WeatherDOFVertexOut weatherDOFVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
    };
    float2 texCoords[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0)
    };
    WeatherDOFVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Hardcoded rather than passed in as technique symbols/uniforms — SCNTechnique's Metal-side
// symbol binding for ad-hoc scalar uniforms is poorly documented and this is the first working
// version of a from-scratch SCNTechnique in this codebase, so the binary on/off toggle (whether
// the technique is attached to the view at all) carries the weather-intensity dependency instead
// of a smoothly varying blur strength.
constant float kFocusDistance = 9.0;
constant float kBlurRange = 40.0;
// Native scene.fog only tints real depth-tested geometry, never the sky background — ground
// recedes into solid fog color well before the actual horizon, but the sky right above it stays
// clear, producing a hard seam exactly at the skyline. Blur is already maxed out there (anything
// past focusDistance+blurRange=49m saturates to this radius), so the seam needs a *bigger* max
// radius, not a wider distance range, to actually get soft enough to read as blurred rather than
// a crisp edge with merely-blurred content on either side of it.
constant float kMaxBlurRadiusPixels = 30.0;
constant float kZNear = 0.01;
constant float kZFar = 900.0;

fragment float4 weatherDOFFragment(WeatherDOFVertexOut in [[stage_in]],
                                    texture2d<float, access::sample> sceneColor [[texture(0)]],
                                    texture2d<float, access::sample> sceneDepth [[texture(1)]]) {
    constexpr sampler colorSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    constexpr sampler depthSampler(filter::nearest, address::clamp_to_edge);

    float2 uv = in.texCoord;
    // SceneKit exposes a technique's "depth" target as a plain texture (depth value in the red
    // channel), not a Metal depth2d<T> resource — depth2d sampling here silently read garbage/a
    // constant value, which is why no blur showed up at all despite the math being correct.
    float rawDepth = sceneDepth.sample(depthSampler, uv).r;

    // Metal/SceneKit uses reversed-Z here (near plane = 1, far plane = 0) — confirmed by
    // amplifying raw depth x300 and visualizing it directly: values for everything visible sit
    // in an extremely tiny sliver near 0 (expected, given zFar/zNear = 90000), but consistently
    // *larger* for closer geometry. The standard (non-reversed) linearization formula always
    // produced a near-zero linear distance regardless of true depth, so blur never triggered.
    // Reversed-Z linear depth: d = (zNear*zFar) / (zNear + ndc*(zFar-zNear)).
    float linearDepth = (kZNear * kZFar) / (kZNear + rawDepth * (kZFar - kZNear));

    float blurAmount = clamp((linearDepth - kFocusDistance) / kBlurRange, 0.0, 1.0);
    float radius = blurAmount * kMaxBlurRadiusPixels;

    float4 baseColor = sceneColor.sample(colorSampler, uv);
    if (radius < 0.5) {
        return baseColor;
    }

    float2 texSize = float2(sceneColor.get_width(), sceneColor.get_height());
    float2 pixelStep = 1.0 / texSize;

    float4 sum = baseColor;
    float weightSum = 1.0;
    const int sampleCount = 8;
    for (int i = 0; i < sampleCount; i++) {
        float angle = (float(i) / float(sampleCount)) * 2.0 * M_PI_F;
        float2 offset = float2(cos(angle), sin(angle)) * radius * pixelStep;
        sum += sceneColor.sample(colorSampler, uv + offset);
        weightSum += 1.0;
    }

    return sum / weightSum;
}
