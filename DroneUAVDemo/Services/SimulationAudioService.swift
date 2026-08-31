import Foundation
import AVFoundation
import simd

/// Identifies a running loop voice. Opaque on purpose — callers hold it to update or stop a
/// sound, and can hold a stale one safely: an update against a voice that has been recycled is
/// ignored rather than retargeting somebody else's sound.
struct AudioLoopHandle: Hashable {
    fileprivate let value: UInt64
}

/// The simulation's audio output.
///
/// Started as a single synthesised sonic boom — the first sound this project ever made — and is
/// now the graph everything else hangs off. It stays deliberately small in scope: it schedules
/// sounds at positions and levels it is told, and knows nothing about materials, impulses or
/// aircraft. What to play, how loud, and whether a contact even deserves a sound is decided
/// upstream and arrives here as an asset id and a gain.
///
/// **Two different paths, for two different jobs.**
///
/// One-shots — impacts, cracks, debris — go through `AVAudioEnvironmentNode`. They are point
/// events at a world position, HRTF is what makes them read as *over there*, and they never
/// need to change once started.
///
/// Loops — rotors, engines, airflow — do not. They need their pitch driven continuously from
/// real RPM, and `AVAudioEnvironmentNode` only accepts `AVAudioPlayerNode` as a spatialised
/// source: `AVAudioUnitVarispeed` does not adopt `AVAudio3DMixing` (verified — it has no
/// `position`), so a rate-controlled voice cannot also be an environment source. Loops
/// therefore get `player → varispeed → per-voice mixer`, with distance gain and pan computed
/// here. For the aircraft you are following — which is where nearly every loop in this
/// simulation comes from — continuous parameter control matters more than head-related
/// filtering, and this is the trade that buys it.
///
/// Everything is main-thread. The simulation tick is `@MainActor` and drives this directly;
/// SceneKit's render callbacks are not, and must not reach in here without hopping first.
@MainActor
final class SimulationAudioService {

    // MARK: Graph

    private let engine = AVAudioEngine()
    /// HRTF spatialiser for one-shots.
    private let environment = AVAudioEnvironmentNode()
    /// Everything meets here, so one volume control and one limiter cover the whole mix.
    private let master = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(
        audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    )
    /// The boom is not a point source in the scene — it is a wave that has already arrived at
    /// the listener — so it bypasses the spatialiser.
    private let boomPlayer = AVAudioPlayerNode()
    private let monoFormat: AVAudioFormat

    private var isRunning = false
    /// Set once the engine has failed to start, so a machine with no audio device does not
    /// retry on every event for the rest of the session.
    private var isDisabled = false

    private static let sampleRate: Double = 48_000.0
    /// Voice budget. The plan asks explicitly that simultaneous destruction not produce audio
    /// spam; this is the ceiling that makes that a property of the system rather than of luck.
    private static let oneShotVoiceCount = 16
    private static let loopVoiceCount = 6
    /// Beyond this a contact is not dropped for being quiet — it is dropped for being
    /// inaudible. At 3 km even a heavy crash is below the noise floor of anywhere a ground
    /// station actually stands.
    private static let maximumAudibleDistance: Float = 3_000.0

    // MARK: Pack

    private(set) var catalog: AudioAssetCatalog = .empty
    /// Decoded clips, keyed `"<assetID>#<variant>"`.
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    /// Assets this service generates rather than loads. They live outside the pack manifest
    /// because there is no file to describe, but they are addressed by the same ids and play
    /// through the same voices as everything else.
    private var syntheticDescriptors: [String: AudioAssetDescriptor] = [:]

    // MARK: Voices

    private struct OneShotVoice {
        let player: AVAudioPlayerNode
        var isBusy = false
        /// Linear gain at the moment of allocation — what a steal is judged against.
        var priority: Float = 0.0
        /// Bumped on every allocation so a completion handler from a previous sound cannot
        /// free the voice out from under the current one.
        var generation: UInt64 = 0
    }

    private struct LoopVoice {
        let player: AVAudioPlayerNode
        let speed: AVAudioUnitVarispeed
        let mixer: AVAudioMixerNode
        var handle: AudioLoopHandle?
    }

    private var oneShotVoices: [OneShotVoice] = []
    private var loopVoices: [LoopVoice] = []
    private var nextLoopHandleValue: UInt64 = 1

    // MARK: Listener

    private var listenerPosition = SIMD3<Float>(repeating: 0.0)
    private var listenerForward = SIMD3<Float>(0.0, 0.0, -1.0)
    private var listenerUp = SIMD3<Float>(0.0, 1.0, 0.0)
    private var lastAppliedVolume: Float = -1.0

    // MARK: Diagnostics

    private(set) var droppedEventCount: Int = 0
    private(set) var activeOneShotCount: Int = 0

    // MARK: Lifecycle

    init() {
        monoFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
            ?? AVAudioFormat()

        engine.attach(environment)
        engine.attach(master)
        engine.attach(limiter)
        engine.attach(boomPlayer)

        engine.connect(environment, to: master, format: nil)
        engine.connect(master, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        engine.connect(boomPlayer, to: master, format: monoFormat)

        for _ in 0..<Self.oneShotVoiceCount {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: environment, format: monoFormat)
            player.renderingAlgorithm = .HRTFHQ
            player.reverbBlend = 0.0
            oneShotVoices.append(OneShotVoice(player: player))
        }

        for _ in 0..<Self.loopVoiceCount {
            let player = AVAudioPlayerNode()
            let speed = AVAudioUnitVarispeed()
            let mixer = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(speed)
            engine.attach(mixer)
            engine.connect(player, to: speed, format: monoFormat)
            engine.connect(speed, to: mixer, format: monoFormat)
            engine.connect(mixer, to: master, format: nil)
            mixer.volume = 0.0
            loopVoices.append(LoopVoice(player: player, speed: speed, mixer: mixer))
        }

        // Inverse-square-ish falloff with a reference distance a little larger than the
        // aircraft itself, so a rotor a metre from the camera is loud without being a
        // singularity, and the same rotor at 200 m is faint rather than absent.
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 8.0
        environment.distanceAttenuationParameters.maximumDistance = Self.maximumAudibleDistance
        environment.distanceAttenuationParameters.rolloffFactor = 1.0

        lastAppliedVolume = AppAudioSettings.effectiveVolume
        master.outputVolume = lastAppliedVolume
    }

    /// Loads the sound pack.
    ///
    /// Synchronous, and it stays synchronous: the whole pack is a few megabytes of 16-bit PCM
    /// that decodes to float with no codec involved, so this is closer to a memcpy than to a
    /// load. The alternative — decoding lazily on first play — puts file I/O on the path of
    /// the first impact of every session, which is precisely the moment that must not stutter.
    func prepare(bundle: Bundle = .main) {
        guard buffers.isEmpty else { return }
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        // Generated first, and outside the pack check: airflow needs no files, so a build
        // with a missing or broken pack still has wind.
        registerAirflowLoop()

        catalog = AudioAssetCatalog.load(from: bundle)
        guard !catalog.isEmpty else {
            #if DEBUG
            print("[Audio] no sound pack in bundle — Audio/AudioPack.json missing or unreadable")
            #endif
            return
        }

        var loadedFrames: AVAudioFrameCount = 0
        for clip in catalog.allClipURLs {
            guard let file = try? AVAudioFile(forReading: clip.url),
                  file.length > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: AVAudioFrameCount(file.length)
                  ),
                  (try? file.read(into: buffer)) != nil else {
                #if DEBUG
                print("[Audio] failed to load \(clip.url.lastPathComponent)")
                #endif
                continue
            }
            buffers[Self.bufferKey(clip.id, clip.variant)] = buffer
            loadedFrames += buffer.frameLength
        }

        #if DEBUG
        let ms = (CACurrentMediaTime() - started) * 1000.0
        print(String(
            format: "[Audio] pack loaded: %d clips, %.1f s of audio, %.1f ms",
            buffers.count,
            Double(loadedFrames) / Self.sampleRate,
            ms
        ))
        for gap in catalog.manifest.unavailable {
            print("[Audio] asset unavailable: \(gap.id) — \(gap.reason)")
        }
        #endif
    }

    /// Starts the audio engine lazily, on the first sound that actually needs to play.
    @discardableResult
    private func startIfNeeded() -> Bool {
        if isDisabled { return false }
        if isRunning { return true }
        do {
            try engine.start()
            boomPlayer.play()
            for voice in oneShotVoices {
                voice.player.play()
            }
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
        stopAllLoops()
        for index in oneShotVoices.indices {
            oneShotVoices[index].player.stop()
            oneShotVoices[index].isBusy = false
        }
        activeOneShotCount = 0
        boomPlayer.stop()
        engine.stop()
        isRunning = false
    }

    /// Applies the persisted volume/mute.
    ///
    /// Safe to call every tick: the settings screen writes through `@AppStorage` and has no way
    /// to tell the simulation it did, so the simulation asks. The value is compared before it
    /// is written so the common case — nothing changed — does not touch the engine at all.
    func refreshMasterVolume() {
        let volume = AppAudioSettings.effectiveVolume
        guard abs(volume - lastAppliedVolume) > 0.0005 else { return }
        lastAppliedVolume = volume
        master.outputVolume = volume
    }

    // MARK: Listener

    /// Where the operator is hearing from.
    ///
    /// Not necessarily where the aircraft is: in a chase view the listener is the camera, and
    /// for the sonic boom it is deliberately the ground station instead. The caller decides;
    /// this only applies it.
    func updateListener(position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
        listenerPosition = position
        listenerForward = simd_length_squared(forward) > 0.000001 ? simd_normalize(forward) : SIMD3<Float>(0.0, 0.0, -1.0)
        listenerUp = simd_length_squared(up) > 0.000001 ? simd_normalize(up) : SIMD3<Float>(0.0, 1.0, 0.0)

        environment.listenerPosition = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: listenerForward.x, y: listenerForward.y, z: listenerForward.z),
            up: AVAudio3DVector(x: listenerUp.x, y: listenerUp.y, z: listenerUp.z)
        )
    }

    var currentListenerPosition: SIMD3<Float> { listenerPosition }

    /// How long a sound emitted at `worldPosition` takes to reach the listener.
    ///
    /// The same arithmetic the sonic boom already used, promoted to something every event can
    /// use. It matters well below supersonic speeds: a wing hitting a tower a kilometre away
    /// is seen three seconds before it is heard, and playing it instantly is the single most
    /// obvious way for distant impacts to feel fake.
    func propagationDelay(from worldPosition: SIMD3<Float>, speedOfSoundMps: Float = 343.0) -> Float {
        let distance = simd_distance(worldPosition, listenerPosition)
        return distance / max(1.0, speedOfSoundMps)
    }

    // MARK: One-shots

    /// Plays one positioned sound.
    ///
    /// Returns false when nothing was played — no pack, no free voice worth stealing, or the
    /// event was too far away to hear. Callers are free to ignore that; it exists so
    /// diagnostics can tell "the resolver never asked" from "the mixer had no room".
    @discardableResult
    func playOneShot(
        _ id: AudioAssetID,
        at worldPosition: SIMD3<Float>,
        gainDb: Float = 0.0,
        pitchRatio: Float = 1.0,
        variant: Int = 1,
        delaySeconds: Float = 0.0
    ) -> Bool {
        guard !isDisabled, !buffers.isEmpty else { return false }
        guard let descriptor = resolveDescriptor(id) else { return false }
        guard simd_distance(worldPosition, listenerPosition) < Self.maximumAudibleDistance else {
            droppedEventCount &+= 1
            return false
        }

        let delay = max(0.0, delaySeconds)
        guard delay >= 0.02 else {
            return fireOneShot(descriptor: descriptor, at: worldPosition, gainDb: gainDb, pitchRatio: pitchRatio, variant: variant)
        }
        // The voice is allocated when the sound arrives, not when it was emitted: a hit three
        // seconds out over the city must not hold a voice hostage for those three seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.fireOneShot(
                    descriptor: descriptor,
                    at: worldPosition,
                    gainDb: gainDb,
                    pitchRatio: pitchRatio,
                    variant: variant
                )
            }
        }
        return true
    }

    private func fireOneShot(
        descriptor: AudioAssetDescriptor,
        at worldPosition: SIMD3<Float>,
        gainDb: Float,
        pitchRatio: Float,
        variant: Int
    ) -> Bool {
        guard startIfNeeded() else { return false }
        let level = Self.linearGain(descriptor.defaultGainDb + gainDb)
        guard level > 0.0008 else { return false }

        let resolvedVariant = min(max(1, variant), max(1, descriptor.variants))
        guard let source = buffers[Self.bufferKey(descriptor.id, resolvedVariant)] else { return false }
        guard let index = allocateOneShotVoice(priority: level) else {
            droppedEventCount &+= 1
            return false
        }

        let buffer = Self.resampled(source, ratio: pitchRatio, format: monoFormat) ?? source
        let voice = oneShotVoices[index]
        let generation = voice.generation

        voice.player.position = AVAudio3DPoint(x: worldPosition.x, y: worldPosition.y, z: worldPosition.z)
        voice.player.volume = min(1.0, level)
        voice.player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Fires on an audio thread. Nothing here may touch the engine or our state
            // directly — the hop is not optional.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.releaseOneShotVoice(at: index, generation: generation)
                }
            }
        }
        if !voice.player.isPlaying {
            voice.player.play()
        }
        return true
    }

    private func allocateOneShotVoice(priority: Float) -> Int? {
        if let free = oneShotVoices.firstIndex(where: { !$0.isBusy }) {
            oneShotVoices[free].isBusy = true
            oneShotVoices[free].priority = priority
            oneShotVoices[free].generation &+= 1
            activeOneShotCount = oneShotVoices.filter(\.isBusy).count
            return free
        }
        // Everything is busy. Steal only from something quieter than the newcomer — a
        // structural failure must be able to interrupt a patter of twigs, and twigs must
        // never interrupt it.
        guard let quietest = oneShotVoices.indices.min(by: { oneShotVoices[$0].priority < oneShotVoices[$1].priority }),
              oneShotVoices[quietest].priority < priority * 0.7 else {
            return nil
        }
        oneShotVoices[quietest].player.stop()
        oneShotVoices[quietest].player.play()
        oneShotVoices[quietest].priority = priority
        oneShotVoices[quietest].generation &+= 1
        return quietest
    }

    private func releaseOneShotVoice(at index: Int, generation: UInt64) {
        guard oneShotVoices.indices.contains(index),
              oneShotVoices[index].generation == generation else {
            return
        }
        oneShotVoices[index].isBusy = false
        oneShotVoices[index].priority = 0.0
        activeOneShotCount = oneShotVoices.filter(\.isBusy).count
    }

    // MARK: Loops

    /// Starts a continuous sound and returns its handle, or nil when no loop voice is free.
    ///
    /// The gain and pitch given here are the starting values; a running loop is expected to be
    /// driven every tick through `updateLoop`, which is the whole point of routing loops
    /// around the spatialiser.
    func startLoop(
        _ id: AudioAssetID,
        at worldPosition: SIMD3<Float>,
        gainDb: Float = 0.0,
        pitchRatio: Float = 1.0
    ) -> AudioLoopHandle? {
        guard !isDisabled, !buffers.isEmpty, startIfNeeded() else { return nil }
        guard let descriptor = resolveDescriptor(id),
              let buffer = buffers[Self.bufferKey(descriptor.id, 1)] else {
            return nil
        }
        guard let index = loopVoices.firstIndex(where: { $0.handle == nil }) else { return nil }

        let handle = AudioLoopHandle(value: nextLoopHandleValue)
        nextLoopHandleValue &+= 1
        loopVoices[index].handle = handle

        let voice = loopVoices[index]
        voice.speed.rate = Self.clampedRate(pitchRatio)
        voice.player.stop()
        voice.player.scheduleBuffer(buffer, at: nil, options: [.loops], completionCallbackType: .dataPlayedBack) { _ in }
        applyLoopPlacement(index: index, worldPosition: worldPosition, gainDb: descriptor.defaultGainDb + gainDb)
        voice.player.play()
        return handle
    }

    /// Moves a running loop and resets its level and rate. Silently ignores a handle whose
    /// voice has been recycled.
    func updateLoop(
        _ handle: AudioLoopHandle,
        at worldPosition: SIMD3<Float>,
        gainDb: Float = 0.0,
        pitchRatio: Float = 1.0
    ) {
        guard let index = loopVoices.firstIndex(where: { $0.handle == handle }) else { return }
        loopVoices[index].speed.rate = Self.clampedRate(pitchRatio)
        applyLoopPlacement(index: index, worldPosition: worldPosition, gainDb: gainDb)
    }

    func stopLoop(_ handle: AudioLoopHandle) {
        guard let index = loopVoices.firstIndex(where: { $0.handle == handle }) else { return }
        loopVoices[index].player.stop()
        loopVoices[index].mixer.volume = 0.0
        loopVoices[index].handle = nil
    }

    func stopAllLoops() {
        for index in loopVoices.indices where loopVoices[index].handle != nil {
            loopVoices[index].player.stop()
            loopVoices[index].mixer.volume = 0.0
            loopVoices[index].handle = nil
        }
    }

    /// Distance gain and stereo placement for a loop voice.
    ///
    /// This is the environment node's job done by hand, because a loop cannot be an
    /// environment source and still have its rate driven. The same inverse law and the same
    /// reference distance are used, so a loop and a one-shot at the same range come out at the
    /// same level rather than at two unrelated ones.
    private func applyLoopPlacement(index: Int, worldPosition: SIMD3<Float>, gainDb: Float) {
        let toSource = worldPosition - listenerPosition
        let distance = max(0.05, simd_length(toSource))
        let reference = environment.distanceAttenuationParameters.referenceDistance
        let attenuation = Float(reference) / max(Float(reference), distance)
        let level = Self.linearGain(gainDb) * attenuation
        loopVoices[index].mixer.volume = min(1.0, max(0.0, level))

        // Pan from the component of the source direction along the listener's right.
        let right = simd_cross(listenerForward, listenerUp)
        let lateral = simd_length_squared(right) > 0.000001
            ? simd_dot(simd_normalize(toSource), simd_normalize(right))
            : 0.0
        loopVoices[index].mixer.pan = min(1.0, max(-1.0, lateral))
    }

    // MARK: Sonic boom

    /// Plays one sonic boom.
    ///
    /// `overpressurePa` sets both the loudness and the character: a weak boom from a high,
    /// distant aircraft is a soft double thud, and a strong one is a crack. `durationSeconds`
    /// is the N-wave's own length, which grows with the aircraft's size and with how far
    /// the wave has travelled — a boom heard from 20 km has stretched into a rumble.
    ///
    /// **The waveform is synthesised, not loaded.** A sonic boom is an N-wave — a near-
    /// instantaneous rise, a linear fall through ambient to an equal underpressure, and a
    /// second sharp rise back. That is a shape with two parameters, and generating it is both
    /// more honest and more useful than shipping one recording: the duration and the
    /// amplitude come from the flight condition, so a distant Mach 1.1 pass and a low Mach 2
    /// pass genuinely sound different rather than being the same file at two volumes.
    func playSonicBoom(overpressurePa: Float, durationSeconds: Float, delaySeconds: Float) {
        guard overpressurePa > 0.5, startIfNeeded() else { return }
        guard let buffer = Self.makeNWave(
            overpressurePa: overpressurePa,
            durationSeconds: durationSeconds,
            format: monoFormat
        ) else { return }

        let scheduleWork = { [weak self] in
            guard let self, self.isRunning else { return }
            self.boomPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }

        let delay = max(0.0, Double(delaySeconds))
        if delay < 0.02 {
            scheduleWork()
        } else {
            // The propagation delay is the point, so it is honoured rather than rounded
            // away: at 15 km the boom arrives three quarters of a minute after the pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated(scheduleWork)
            }
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
        // well below full scale: this is one sound in a mix that has others, and a boom that
        // clips is a boom that sounds like a fault.
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

    // MARK: Synthetic sources

    /// An asset the service generates. Same ids, same voices, no file.
    private func registerSynthetic(
        _ id: AudioAssetID,
        buffer: AVAudioPCMBuffer,
        defaultGainDb: Float,
        loop: Bool
    ) {
        buffers[Self.bufferKey(id.rawValue, 1)] = buffer
        syntheticDescriptors[id.rawValue] = AudioAssetDescriptor(
            id: id.rawValue,
            category: .aero,
            path: "",
            variants: 1,
            loop: loop,
            durationSeconds: Double(buffer.frameLength) / Self.sampleRate,
            defaultGainDb: defaultGainDb
        )
    }

    /// The pack first, then what the service makes itself.
    private func resolveDescriptor(_ id: AudioAssetID) -> AudioAssetDescriptor? {
        catalog.descriptor(for: id) ?? syntheticDescriptors[id.rawValue]
    }

    /// Whether this id will actually produce a sound, from either source.
    func canPlay(_ id: AudioAssetID) -> Bool {
        resolveDescriptor(id) != nil && buffers[Self.bufferKey(id.rawValue, 1)] != nil
    }

    /// Registers the generated airflow bed, unless the pack ships a real one.
    ///
    /// Called before the manifest is read, so the check happens the other way round: the
    /// synthetic is registered first and the pack overwrites it, because `resolveDescriptor`
    /// consults the manifest before the synthetic table and `prepare` loads pack clips into
    /// the same buffer map afterwards. A recording of air over a microphone is better than a
    /// filtered noise generator; the generator is what keeps a build with no pack from flying
    /// in silence.
    private func registerAirflowLoop() {
        guard let buffer = Self.makeAirflowLoop() else { return }
        registerSynthetic(.airflowLoop, buffer: buffer, defaultGainDb: -6.0, loop: true)
    }

    /// Builds the airflow loop.
    ///
    /// Generated rather than recorded, for the same reason the sonic boom is: airflow noise
    /// over an airframe genuinely *is* broadband noise, so synthesising it is not a shortcut
    /// around a missing recording — it is the honest model. It also sidesteps the problem
    /// every recorded wind loop has, which is that it was recorded at one speed and carries
    /// that speed's character into every other one.
    ///
    /// The spectrum is shaped towards pink: a one-pole low-pass over white noise, which falls
    /// at roughly 6 dB per octave above its corner and is a fair stand-in for the turbulent
    /// boundary layer's slope. The clip then crossfades onto its own head so it repeats
    /// without a seam — the same construction the asset pack script uses for recorded loops,
    /// and necessary here for the same reason: a discontinuity in noise is a click, and a
    /// click once every four seconds is more noticeable than the noise itself.
    private static func makeAirflowLoop() -> AVAudioPCMBuffer? {
        let seconds = 4.0
        let crossfadeSeconds = 0.25
        let totalFrames = Int(seconds * sampleRate)
        let crossfadeFrames = Int(crossfadeSeconds * sampleRate)
        guard totalFrames > crossfadeFrames * 2,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(totalFrames)

        // A fixed seed, so the wind is the same wind on every launch and in every replay.
        var seed: UInt64 = 0x5EED_A1_F1_0000_0001
        func nextWhite() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let bits = (seed >> 33) & 0xFF_FFFF
            return Float(bits) / Float(0x7F_FFFF) - 1.0
        }

        // Generate the whole thing plus the crossfade tail, then fold the tail into the head.
        let generatedFrames = totalFrames + crossfadeFrames
        var scratch = [Float](repeating: 0.0, count: generatedFrames)
        var lowPassState: Float = 0.0
        // Corner near 1.2 kHz at 48 kHz: above it the slope does the pinking, below it the
        // noise stays flat, which is where the body of a rushing-air sound lives.
        let alpha: Float = 0.15
        for frame in 0..<generatedFrames {
            lowPassState += alpha * (nextWhite() - lowPassState)
            scratch[frame] = lowPassState
        }

        var peak: Float = 0.0
        for frame in 0..<totalFrames {
            var value = scratch[frame]
            if frame < crossfadeFrames {
                // The material that would have played next, faded in against the head fading
                // out — so the loop's last sample runs into its first without a step.
                let t = Float(frame) / Float(crossfadeFrames)
                value = value * t + scratch[frame + totalFrames] * (1.0 - t)
            }
            channel[frame] = value
            peak = max(peak, abs(value))
        }
        // Normalise to a known ceiling; the runtime's gain law expects a full-scale source.
        if peak > 0.0001 {
            let scale = 0.7 / peak
            for frame in 0..<totalFrames {
                channel[frame] *= scale
            }
        }
        return buffer
    }

    // MARK: Helpers

    private static func bufferKey(_ id: String, _ variant: Int) -> String { "\(id)#\(variant)" }

    private static func linearGain(_ db: Float) -> Float {
        guard db.isFinite else { return 0.0 }
        return pow(10.0, min(6.0, db) / 20.0)
    }

    private static func clampedRate(_ ratio: Float) -> Float {
        guard ratio.isFinite else { return 1.0 }
        return min(2.0, max(0.5, ratio))
    }

    /// Resamples a clip to shift its pitch.
    ///
    /// One-shots cannot use the varispeed unit — that node cannot be an environment source —
    /// so the rate change happens here, on the buffer, before it is scheduled. Linear
    /// interpolation is enough: these are impacts a fraction of a second long, the shift is at
    /// most a few percent, and the interpolation error sits far below the noise in the
    /// recordings themselves. A ratio of 1 returns nil and the original buffer is used
    /// unmodified, so the common case costs nothing.
    private static func resampled(
        _ source: AVAudioPCMBuffer,
        ratio: Float,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let rate = clampedRate(ratio)
        guard abs(rate - 1.0) > 0.001,
              let input = source.floatChannelData?[0] else {
            return nil
        }
        let inputFrames = Int(source.frameLength)
        let outputFrames = Int(Float(inputFrames) / rate)
        guard inputFrames > 1, outputFrames > 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outputFrames)),
              let output = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(outputFrames)
        for frame in 0..<outputFrames {
            let position = Float(frame) * rate
            let index = Int(position)
            guard index + 1 < inputFrames else {
                output[frame] = input[inputFrames - 1]
                continue
            }
            let fraction = position - Float(index)
            output[frame] = input[index] * (1.0 - fraction) + input[index + 1] * fraction
        }
        return buffer
    }
}
