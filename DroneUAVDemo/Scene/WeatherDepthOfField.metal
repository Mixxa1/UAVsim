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
// Tried a depth-edge-detection boost (probe neighbor pixels, raise radius further only where
// depth jumps sharply) to target the horizon seam specifically without blurring everything else
// distant any harder. Couldn't get a trustworthy visual verification either way — the offscreen
// SCNView.snapshot() test harness turned out to not reliably reflect `.technique` shader changes
// (even an unconditional solid-red fragment shader didn't show up in the snapshot) — and the
// user's live test showed no visible difference. Reverted it rather than ship unverified
// complexity; pushing this single global value is the lever already confirmed working live.
constant float kMaxBlurRadiusPixels = 55.0;
constant float kZNear = 0.01;
constant float kZFar = 900.0;

// Blur alone can soften an edge but can't erase a hard *color* contrast between two flat
// regions (fogged-white ground vs untouched-blue sky) — softening that needs an explicit color
// blend, not more spatial sampling. Both sides of the horizon seam reach blurAmount's max at the
// same point (anything past focusDistance+blurRange saturates to 1.0, whether it's far ground or
// the sky background, which has no real depth and reads as maximally far) — pulling both toward
// one shared haze tone, scaled by that same blurAmount, fades them into each other rather than
// leaving a flat-color-vs-flat-color line. This is also just how real atmospheric haze behaves:
// distant ground and the sky near the horizon really do converge toward a similar pale color.
// Matched close to the fog's own white tone (not a blue-grey) — the user's clean-build test
// showed the previous blue-ish haze color making the seam read as *more* blue right at the
// horizon, the opposite of the intent. A near-white haze means the sky fades toward the same
// white the ground is already fogged to, instead of fighting it with a different hue.
constant float4 kHazeColor = float4(0.88, 0.89, 0.90, 1.0);
constant float kHazeStrength = 0.8;

float weatherDOFLinearDepth(float rawDepth) {
    // Metal/SceneKit uses reversed-Z here (near plane = 1, far plane = 0) — confirmed by
    // amplifying raw depth x300 and visualizing it directly: values for everything visible sit
    // in an extremely tiny sliver near 0 (expected, given zFar/zNear = 90000), but consistently
    // *larger* for closer geometry. The standard (non-reversed) linearization formula always
    // produced a near-zero linear distance regardless of true depth, so blur never triggered.
    // Reversed-Z linear depth: d = (zNear*zFar) / (zNear + ndc*(zFar-zNear)).
    return (kZNear * kZFar) / (kZNear + rawDepth * (kZFar - kZNear));
}

fragment float4 weatherDOFFragment(WeatherDOFVertexOut in [[stage_in]],
                                    texture2d<float, access::sample> sceneColor [[texture(0)]],
                                    texture2d<float, access::sample> sceneDepth [[texture(1)]]) {
    constexpr sampler colorSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    constexpr sampler depthSampler(filter::nearest, address::clamp_to_edge);

    float2 uv = in.texCoord;
    float2 texSize = float2(sceneColor.get_width(), sceneColor.get_height());
    float2 pixelStep = 1.0 / texSize;

    // SceneKit exposes a technique's "depth" target as a plain texture (depth value in the red
    // channel), not a Metal depth2d<T> resource — depth2d sampling here silently read garbage/a
    // constant value, which is why no blur showed up at all despite the math being correct.
    float rawDepth = sceneDepth.sample(depthSampler, uv).r;
    float linearDepth = weatherDOFLinearDepth(rawDepth);

    float blurAmount = clamp((linearDepth - kFocusDistance) / kBlurRange, 0.0, 1.0);
    float radius = blurAmount * kMaxBlurRadiusPixels;

    float4 baseColor = sceneColor.sample(colorSampler, uv);
    float4 resultColor = baseColor;

    if (radius >= 0.5) {
        float4 sum = baseColor;
        float weightSum = 1.0;
        const int sampleCount = 8;
        for (int i = 0; i < sampleCount; i++) {
            float angle = (float(i) / float(sampleCount)) * 2.0 * M_PI_F;
            float2 offset = float2(cos(angle), sin(angle)) * radius * pixelStep;
            sum += sceneColor.sample(colorSampler, uv + offset);
            weightSum += 1.0;
        }
        resultColor = sum / weightSum;
    }

    return mix(resultColor, kHazeColor, blurAmount * kHazeStrength);
}
