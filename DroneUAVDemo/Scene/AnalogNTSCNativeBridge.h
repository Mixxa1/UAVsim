#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C boundary around the upstream RF2 C++ processor. Input and output are exactly
/// 720x480 packed RGB888 frames, matching `rf2::NtscProcessor::ProcessFrame`.
@interface UAVAnalogNTSCNativeBridge : NSObject

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
                          signalLoss:(float)signalLoss;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
