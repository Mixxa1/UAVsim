import Foundation
import AVFoundation

/// The simulation's first audio output.
///
/// There was none before this. Nothing in the project touched `AVAudioEngine`,
/// `SCNAudioSource` or any other sound API, so the sonic boom the plan asks for could not
/// be a small addition to an existing layer — the layer had to exist first. This is that
/// layer, kept to exactly what the boom needs and no more: schedule one short sound, at a
/// time, at a level.
///
/// **The waveform is synthesised, not loaded.** A sonic boom is an N-wave — a near-
/// instantaneous rise, a linear fall through ambient to an equal underpressure, and a
/// second sharp rise back. That is a shape with two parameters, and generating it is both
/// more honest and more useful than shipping one recording: the duration and the
/// amplitude come from the flight condition, so a distant Mach 1.1 pass and a low Mach 2
/// pass genuinely sound different rather than being the same file at two volumes.
///
/// Deliberately silent about anything else. Engine noise, wind and rotor sound are not
/// here, are not implied by this being here, and would each need their own thought about
/// looping, Doppler and distance attenuation.
final class SimulationAudioService {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var isRunning = false
    /// Set once the engine has failed to start, so a machine with no audio device does
    /// not retry on every boom for the rest of the session.
    private var isDisabled = false

    private static let sampleRate: Double = 44_100.0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
            ?? AVAudioFormat()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Starts the audio engine lazily, on the first sound that actually needs to play.
    ///
    /// Lazily because most sessions never make one: the entire subsonic fleet flies
    /// without producing a single sound event, and spinning up an audio graph at launch
    /// for them would be cost with no benefit.
    private func startIfNeeded() -> Bool {
        if isDisabled { return false }
        if isRunning { return true }
        do {
            try engine.start()
            player.play()
            isRunning = true
            return true
        } catch {
            // A headless machine, a probe process, or no output device. Failing quietly is
            // right here — no sound is a lesser problem than a simulation that stops.
            isDisabled = true
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
    }

    /// Plays one sonic boom.
    ///
    /// `overpressurePa` sets both the loudness and the character: a weak boom from a high,
    /// distant aircraft is a soft double thud, and a strong one is a crack. `durationSeconds`
    /// is the N-wave's own length, which grows with the aircraft's size and with how far
    /// the wave has travelled — a boom heard from 20 km has stretched into a rumble.
    func playSonicBoom(overpressurePa: Float, durationSeconds: Float, delaySeconds: Float) {
        guard overpressurePa > 0.5, startIfNeeded() else { return }
        guard let buffer = Self.makeNWave(
            overpressurePa: overpressurePa,
            durationSeconds: durationSeconds,
            format: format
        ) else { return }

        let scheduleWork = { [weak self] in
            guard let self, self.isRunning else { return }
            self.player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }

        let delay = max(0.0, Double(delaySeconds))
        if delay < 0.02 {
            scheduleWork()
        } else {
            // The propagation delay is the point, so it is honoured rather than rounded
            // away: at 15 km the boom arrives three quarters of a minute after the pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: scheduleWork)
        }
    }

    /// Builds the N-wave.
    ///
    /// The shape is the physics: pressure jumps up at the bow shock, falls linearly
    /// through ambient to an equal underpressure, then jumps back at the tail shock. Two
    /// cracks with a rush between them, which is why a boom is heard as a double bang
    /// close up and as one rumble far away, where the two shocks have merged.
    ///
    /// The two shock faces are given a short but finite rise rather than a true
    /// discontinuity. A single-sample step is not more accurate — it is an alias, and it
    /// sounds like a click rather than like a shock.
    private static func makeNWave(
        overpressurePa: Float,
        durationSeconds: Float,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        // Tail padding so the wave has somewhere to decay rather than being cut off.
        let waveSeconds = max(0.02, min(1.2, durationSeconds))
        let totalSeconds = waveSeconds + 0.35
        let frameCount = AVAudioFrameCount(totalSeconds * Float(sampleRate))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount

        // Peak sample amplitude from the overpressure, on a logarithmic scale so that a
        // hundredfold range of overpressures maps onto a usable range of loudness. Capped
        // well below full scale: this is one sound in a mix that will eventually have
        // others, and a boom that clips is a boom that sounds like a fault.
        let level = SonicBoomTracker.soundPressureLevelDb(overpressurePa: overpressurePa)
        let amplitude = min(0.85, max(0.02, (level - 80.0) / 60.0))

        let waveFrames = Int(waveSeconds * Float(sampleRate))
        let riseFrames = max(4, Int(0.0006 * Float(sampleRate)))
        // A long-travelled wave loses its sharp faces to atmospheric absorption, so a
        // distant boom is dull. `durationSeconds` carries that: the same rise time is a
        // larger fraction of a longer wave.
        let decay = Float(0.35 * sampleRate)

        for frame in 0..<Int(frameCount) {
            let value: Float
            if frame < riseFrames {
                // Bow shock: up.
                value = amplitude * Float(frame) / Float(riseFrames)
            } else if frame < waveFrames - riseFrames {
                // The linear fall from +1 through zero to −1 that gives the N its shape.
                let t = Float(frame - riseFrames) / Float(max(1, waveFrames - 2 * riseFrames))
                value = amplitude * (1.0 - 2.0 * t)
            } else if frame < waveFrames {
                // Tail shock: back up to ambient.
                let t = Float(frame - (waveFrames - riseFrames)) / Float(riseFrames)
                value = -amplitude * (1.0 - t)
            } else {
                // Ring-down, so the buffer ends at silence instead of at a step.
                let t = Float(frame - waveFrames)
                value = 0.0 * exp(-t / decay)
            }
            channel[frame] = value.isFinite ? value : 0.0
        }
        return buffer
    }

    /// How long the wave lasts at the observer, s.
    ///
    /// Grows with the aircraft's length — the wave is generated over the whole body — and
    /// with the distance it has travelled, because the two shocks spread apart as they
    /// propagate. That spreading is why a boom from directly overhead is a sharp double
    /// crack and the same aircraft heard from thirty kilometres away is a roll of thunder.
    static func nWaveDuration(aircraftLengthM: Float, slantRangeMeters: Float) -> Float {
        let length = max(1.0, aircraftLengthM)
        let range = max(100.0, slantRangeMeters)
        return min(0.9, 0.0009 * length * pow(range / 1_000.0, 0.35) + 0.06)
    }
}
