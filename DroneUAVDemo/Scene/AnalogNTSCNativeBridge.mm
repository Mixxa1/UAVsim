#import "AnalogNTSCNativeBridge.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>

#include "rf2/ntsc_processor.h"

namespace {

constexpr NSUInteger kFrameWidth = 720;
constexpr NSUInteger kFrameHeight = 480;
constexpr NSUInteger kRGBByteCount = kFrameWidth * kFrameHeight * 3;

float Clamp01(float value) {
  if (!std::isfinite(value)) return 1.0f;
  return std::min(1.0f, std::max(0.0f, value));
}

}  // namespace

@implementation UAVAnalogNTSCNativeBridge {
  std::unique_ptr<rf2::NtscProcessor> _processor;
  uint32_t _frameIndex;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _processor = std::make_unique<rf2::NtscProcessor>();
    _frameIndex = 0;

    // Receiver defaults appropriate for an FPV monitor. Dot crawl is intentionally enabled:
    // the upstream encoder/decoder then derives it from the composite carrier instead of
    // painting a screen-space texture over the image.
    auto& decoder = _processor->decoder().controls();
    decoder.comb_filter = true;
    decoder.dot_crawl = true;
    decoder.saturation = 0.90f;
  }
  return self;
}

- (nullable NSData *)processRGBFrame:(NSData *)rgbFrame
            noiseStandardDeviationIRE:(float)noiseStandardDeviationIRE
                       multipathGain:(float)multipathGain
                multipathDelayPixels:(float)multipathDelayPixels
                   multipathEnsemble:(float)multipathEnsemble
                         impulseNoise:(float)impulseNoise
                        burstNoiseIRE:(float)burstNoiseIRE
            horizontalSyncInstability:(float)horizontalSyncInstability
              verticalSyncInstability:(float)verticalSyncInstability
                       chromaFlutter:(float)chromaFlutter
                          signalLoss:(float)signalLoss {
  if (rgbFrame.length != kRGBByteCount || !_processor) return nil;

  const float horizontal = Clamp01(horizontalSyncInstability);
  const float vertical = Clamp01(verticalSyncInstability);
  const float loss = Clamp01(signalLoss);
  const float ghost = Clamp01(multipathGain);
  const float interference = Clamp01(impulseNoise);

  auto& effects = _processor->effects().controls();
  effects.noise_stddev_ire = std::min(
      20.0f, std::max(0.0f, noiseStandardDeviationIRE) + loss * 8.0f);
  effects.noise_color = 0.35f + 0.40f * std::max(horizontal, loss);
  effects.multipath_gain = ghost;
  // RF2 delay is measured in 4*fsc composite samples. Its active line contains 754 samples
  // for 720 pixels, so the conversion is nearly one-to-one but is kept explicit.
  effects.multipath_delay_samples = static_cast<uint32_t>(std::max(
      1.0f, std::round(std::max(0.0f, multipathDelayPixels) * 754.0f / 720.0f)));
  effects.multipath_ensemble = Clamp01(multipathEnsemble);
  effects.line_time_jitter_samples = horizontal * 2.0f;
  effects.afc_hunt = horizontal * 0.72f;
  effects.rf_drift = std::max(horizontal * 0.22f, loss * 0.38f);
  effects.am_nonlinearity = std::max(interference * 0.18f, loss * 0.24f);
  effects.impulse_noise = interference;
  effects.agc_pump = std::max(interference * 0.28f, loss * 0.42f);
  effects.hum = interference * 0.12f;
  effects.chroma_flutter = Clamp01(chromaFlutter);
  effects.yc_crosstalk = std::max(ghost * 0.20f, loss * 0.32f);
  effects.h_sync_noise_ire = std::min(16.0f, horizontal * 16.0f + loss * 5.0f);
  effects.v_sync_noise_ire = std::min(16.0f, vertical * 16.0f + loss * 6.0f);
  effects.burst_noise_ire = std::min(
      16.0f, std::max(0.0f, burstNoiseIRE) + loss * 4.0f);
  effects.vhs_tracking = 0.0f;
  effects.vhs_wrinkle = 0.0f;
  effects.vhs_head_switch = 0.0f;
  effects.vhs_dropouts = loss * 0.72f;
  effects.group_delay = std::max(ghost * 0.42f, loss * 0.25f);
  effects.random_seed = ++_frameIndex;

  auto& decoder = _processor->decoder().controls();
  decoder.h_lock_instability = horizontal;
  decoder.v_hold_instability = vertical;
  decoder.burst_lock_instability = std::min(
      1.0f, std::max(0.0f, burstNoiseIRE) / 16.0f + loss * 0.35f);
  decoder.random_seed = _frameIndex;

  std::vector<uint8_t> output;
  _processor->ProcessFrame(
      static_cast<const uint8_t *>(rgbFrame.bytes), &output);
  if (output.size() != kRGBByteCount) return nil;
  return [NSData dataWithBytes:output.data() length:output.size()];
}

- (void)reset {
  if (_processor) _processor->Reset();
  _frameIndex = 0;
}

@end
