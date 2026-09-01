import AppKit
import AVFoundation
import SceneKit

enum ReplayVideoExportError: LocalizedError {
    case noFrames
    case cancelled
    case pixelBufferUnavailable
    case imageConversionFailed
    case writerFailed(String)

    var errorDescription: String? {
        let language = L10n.currentLanguage()
        switch self {
        case .noFrames:
            return L10n.s("replay.export.error.no_frames", language: language)
        case .cancelled:
            return L10n.s("replay.export.error.cancelled", language: language)
        case .pixelBufferUnavailable:
            return L10n.s("replay.export.error.pixel_buffer_unavailable", language: language)
        case .imageConversionFailed:
            return L10n.s("replay.export.error.image_conversion_failed", language: language)
        case .writerFailed(let message):
            return message
        }
    }
}

final class ReplayVideoExportService: ObservableObject {
    @Published private(set) var isExporting: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastErrorMessage: String?

    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    func export(
        session: MissionReplaySession,
        settings: ReplayVideoExportSettings,
        outputURL: URL,
        cameraMode: ReplayCameraMode,
        renderOverlay: Bool,
        selectedEvent: MissionReplayEvent? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        guard !session.frames.isEmpty else { throw ReplayVideoExportError.noFrames }
        let alreadyExporting = await MainActor.run { isExporting }
        guard !alreadyExporting else { return }

        let settings = settings.clamped
        setCancellationRequested(false)
        await MainActor.run {
            isExporting = true
            progress = 0
            lastErrorMessage = nil
        }

        do {
            try await performExport(
                session: session,
                settings: settings,
                outputURL: outputURL,
                cameraMode: cameraMode,
                renderOverlay: renderOverlay,
                selectedEvent: selectedEvent,
                progressHandler: progressHandler
            )
            await MainActor.run {
                isExporting = false
                progress = 1
            }
        } catch {
            await MainActor.run {
                isExporting = false
                lastErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func cancel() {
        setCancellationRequested(true)
    }

    private func setCancellationRequested(_ value: Bool) {
        cancellationLock.lock()
        cancellationRequested = value
        cancellationLock.unlock()
    }

    private func isCancellationRequested() -> Bool {
        cancellationLock.lock()
        let value = cancellationRequested
        cancellationLock.unlock()
        return value
    }

    private func checkCancellation() throws {
        if isCancellationRequested() || Task.isCancelled {
            throw ReplayVideoExportError.cancelled
        }
    }

    private func performExport(
        session: MissionReplaySession,
        settings: ReplayVideoExportSettings,
        outputURL: URL,
        cameraMode: ReplayCameraMode,
        renderOverlay: Bool,
        selectedEvent: MissionReplayEvent?,
        progressHandler: ((Double) -> Void)?
    ) async throws {
        let sortedFrames = session.frames.sorted { $0.timestamp < $1.timestamp }
        guard !sortedFrames.isEmpty else { throw ReplayVideoExportError.noFrames }

        let sourceDuration = sortedFrames.last?.timestamp ?? session.duration
        let trim = (settings.trimRange ?? ReplayTrimRange(startTime: 0, endTime: sourceDuration))
            .clamped(to: sourceDuration)
        let replayDuration = max(0.001, trim.duration)
        let outputDuration = replayDuration / settings.playbackSpeed
        let totalFrames = max(1, Int(ceil(outputDuration * Double(settings.framesPerSecond))))
        let exportStartTime = CFAbsoluteTimeGetCurrent()
        let renderOptions = MissionReplayExportRenderOptions.options(for: settings)
        let progressPublishInterval: Double = settings.exportMode == .fast ? 0.25 : 0.5
        let antialiasingMode: SCNAntialiasingMode = renderOptions.enableAntialiasing ? .multisampling2X : .none
        let resolvedBitrate = settings.resolvedBitrateBitsPerSecond
        let estimatedOutputSizeMB = Double(resolvedBitrate) * outputDuration / 8_000_000
        var totalRenderTime: Double = 0
        var totalWriterWaitTime: Double = 0
        var lastProgressPublish = exportStartTime

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let fileType: AVFileType = settings.format == .mp4 ? .mp4 : .mov

        // Quality mode gets HEVC — roughly 2x the compression efficiency of H.264 at the same
        // bitrate (so the existing bitrate presets go noticeably further), safe to assume
        // available since HEVC hardware encode has shipped on every Mac since 2017, well below
        // this app's deployment target. Fast mode keeps H.264: it encodes faster and that mode's
        // whole point is turnaround speed over maximum quality-per-bit.
        let codec: AVVideoCodecType = settings.exportMode == .quality ? .hevc : .h264

        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: resolvedBitrate,
            AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond
        ]
        if codec == .h264 {
            // Explicit High profile — AVFoundation otherwise defaults to a lower, less efficient
            // profile. High has been decodable by essentially everything for over a decade, so
            // this is a strict quality-per-bit win with no real compatibility cost. HEVC doesn't
            // need the equivalent here; its encoder defaults are already the efficient ones.
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        // Tags the output as standard Rec.709 (SDR) instead of leaving color interpretation to
        // whatever the encoder/player guesses — this is ordinary SDR render output, not HDR or a
        // wide-gamut source, so this is the correct tag rather than an enhancement.
        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let fallbackVideoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height
        ]

        let candidateInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let input: AVAssetWriterInput
        if writer.canAdd(candidateInput) {
            input = candidateInput
        } else {
            let fallbackInput = AVAssetWriterInput(mediaType: .video, outputSettings: fallbackVideoSettings)
            guard writer.canAdd(fallbackInput) else {
                throw ReplayVideoExportError.writerFailed(L10n.f("replay.export.error.cannot_add_input", language: L10n.currentLanguage(), settings.format.rawValue.uppercased()))
            }
            input = fallbackInput
        }
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        writer.add(input)
        guard writer.startWriting() else {
            throw ReplayVideoExportError.writerFailed(writer.error?.localizedDescription ?? L10n.s("replay.export.error.writer_start_failed", language: L10n.currentLanguage()))
        }
        writer.startSession(atSourceTime: .zero)

        let controller = MissionReplaySceneController()
        controller.loadSession(session, events: session.events)
        controller.prepareForVideoExport(renderOptions)
        controller.setCameraMode(cameraMode)
        if cameraMode == .cinematicEvent {
            controller.setSelectedEvent(selectedEvent.flatMap { trim.contains($0.timestamp) ? $0 : nil })
        }
        if cameraMode == .onboardMount {
            // setCameraMode defaults onboard-mount to its editing sub-state (gizmo visible,
            // camera orbiting outside the drone) — exactly right the first time someone picks
            // this mode interactively, completely wrong for a rendered export: it would bake the
            // move arrows/rotate rings/eye marker into the video and show the wide orbit framing
            // instead of the configured "through the lens" shot. Exports always want the final
            // preview result.
            controller.setOnboardMountEditing(false)
        }

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = controller.scene
        renderer.pointOfView = controller.cameraNode
        renderer.technique = controller.wantsWeatherDepthOfField ? WeatherDepthOfFieldTechnique.shared : nil
        let renderSize = NSSize(width: settings.width, height: settings.height)

        do {
            for frameIndex in 0..<totalFrames {
                try checkCancellation()

                let videoTime = Double(frameIndex) / Double(settings.framesPerSecond)
                let replayTime = min(trim.endTime, trim.startTime + videoTime * settings.playbackSpeed)
                if let frame = frameForExportTime(replayTime, frames: sortedFrames) {
                    controller.update(frame: frame, replayTime: replayTime, duration: sourceDuration)
                }

                guard let pool = adaptor.pixelBufferPool else {
                    throw ReplayVideoExportError.pixelBufferUnavailable
                }

                let writerWaitStart = CFAbsoluteTimeGetCurrent()
                var didWaitForWriter = false
                while !input.isReadyForMoreMediaData {
                    didWaitForWriter = true
                    try checkCancellation()
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                if didWaitForWriter {
                    totalWriterWaitTime += CFAbsoluteTimeGetCurrent() - writerWaitStart
                }

                let renderStart = CFAbsoluteTimeGetCurrent()
                let pixelBuffer = try renderPixelBuffer(
                    renderer: renderer,
                    renderSize: renderSize,
                    replayTime: replayTime,
                    trimStartTime: trim.startTime,
                    replayDuration: replayDuration,
                    cameraMode: cameraMode,
                    renderOverlay: renderOverlay,
                    includeOverlay: renderOptions.showOverlay,
                    antialiasingMode: antialiasingMode,
                    pool: pool,
                    width: settings.width,
                    height: settings.height
                )
                totalRenderTime += CFAbsoluteTimeGetCurrent() - renderStart

                let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.framesPerSecond))
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw ReplayVideoExportError.writerFailed(writer.error?.localizedDescription ?? L10n.s("replay.export.error.writer_append_failed", language: L10n.currentLanguage()))
                }

                let nextProgress = Double(frameIndex + 1) / Double(totalFrames)
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastProgressPublish >= progressPublishInterval || frameIndex == totalFrames - 1 {
                    await MainActor.run {
                        self.progress = nextProgress
                        progressHandler?(nextProgress)
                    }
                    lastProgressPublish = now
                }
                if settings.exportMode == .fast {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                await Task.yield()
            }

            input.markAsFinished()
            await writer.finishWriting()
            if writer.status == .failed {
                throw ReplayVideoExportError.writerFailed(writer.error?.localizedDescription ?? L10n.s("replay.export.error.writer_failed", language: L10n.currentLanguage()))
            }

            logExportSummary(
                settings: settings,
                cameraMode: cameraMode,
                renderOptions: renderOptions,
                totalFrames: totalFrames,
                startedAt: exportStartTime,
                totalRenderTime: totalRenderTime,
                totalWriterWaitTime: totalWriterWaitTime,
                resolvedBitrate: resolvedBitrate,
                estimatedOutputSizeMB: estimatedOutputSizeMB,
                cancelled: false
            )
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            logExportSummary(
                settings: settings,
                cameraMode: cameraMode,
                renderOptions: renderOptions,
                totalFrames: totalFrames,
                startedAt: exportStartTime,
                totalRenderTime: totalRenderTime,
                totalWriterWaitTime: totalWriterWaitTime,
                resolvedBitrate: resolvedBitrate,
                estimatedOutputSizeMB: estimatedOutputSizeMB,
                cancelled: true
            )
            throw error
        }
    }

    private func frameForExportTime(_ time: TimeInterval, frames sortedFrames: [MissionReplayFrame]) -> MissionReplayFrame? {
        guard let first = sortedFrames.first else { return nil }
        guard time > first.timestamp else { return first }
        guard let last = sortedFrames.last, time < last.timestamp else { return sortedFrames.last }

        var lo = 0
        var hi = sortedFrames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sortedFrames[mid].timestamp <= time {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        guard lo + 1 < sortedFrames.count else { return sortedFrames[lo] }
        return interpolate(sortedFrames[lo], sortedFrames[lo + 1], at: time)
    }

    private func interpolate(_ start: MissionReplayFrame, _ end: MissionReplayFrame, at time: TimeInterval) -> MissionReplayFrame {
        let span = max(0.0001, end.timestamp - start.timestamp)
        let t = max(0, min(1, (time - start.timestamp) / span))
        let chosen = t < 0.5 ? start : end
        return MissionReplayFrame(
            id: chosen.id,
            timestamp: time,
            position: lerp(start.position, end.position, t),
            velocity: lerp(start.velocity, end.velocity, t),
            attitude: MissionAttitudeSnapshot(
                rollRadians: lerpAngle(start.attitude.rollRadians, end.attitude.rollRadians, t),
                pitchRadians: lerpAngle(start.attitude.pitchRadians, end.attitude.pitchRadians, t),
                yawRadians: lerpAngle(start.attitude.yawRadians, end.attitude.yawRadians, t)
            ),
            flightModeDescription: chosen.flightModeDescription,
            autopilotDescription: chosen.autopilotDescription,
            activeWaypointIndex: chosen.activeWaypointIndex,
            batteryPercent: lerpOptional(start.batteryPercent, end.batteryPercent, t),
            payloadStatusDescription: chosen.payloadStatusDescription,
            warningCount: max(start.warningCount, end.warningCount),
            rfSnapshot: chosen.rfSnapshot
        )
    }

    private func lerp(_ a: CodableVector3D, _ b: CodableVector3D, _ t: Double) -> CodableVector3D {
        CodableVector3D(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
    }

    private func lerpOptional(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a, let b else { return a ?? b }
        return a + (b - a) * t
    }

    private func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + atan2(sin(b - a), cos(b - a)) * t
    }

    private func renderPixelBuffer(
        renderer: SCNRenderer,
        renderSize: NSSize,
        replayTime: TimeInterval,
        trimStartTime: TimeInterval,
        replayDuration: TimeInterval,
        cameraMode: ReplayCameraMode,
        renderOverlay: Bool,
        includeOverlay: Bool,
        antialiasingMode: SCNAntialiasingMode,
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var result: Result<CVPixelBuffer, Error>!
        autoreleasepool {
            result = Result {
                var image = renderer.snapshot(
                    atTime: replayTime,
                    with: renderSize,
                    antialiasingMode: antialiasingMode
                )
                if renderOverlay && includeOverlay {
                    image = overlayedImage(
                        image,
                        time: replayTime - trimStartTime,
                        duration: replayDuration,
                        cameraMode: cameraMode
                    )
                }
                return try makePixelBuffer(from: image, pool: pool, width: width, height: height)
            }
        }
        return try result.get()
    }

    private func logExportSummary(
        settings: ReplayVideoExportSettings,
        cameraMode: ReplayCameraMode,
        renderOptions: MissionReplayExportRenderOptions,
        totalFrames: Int,
        startedAt: CFAbsoluteTime,
        totalRenderTime: Double,
        totalWriterWaitTime: Double,
        resolvedBitrate: Int,
        estimatedOutputSizeMB: Double,
        cancelled: Bool
    ) {
        let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startedAt)
        let averageRenderMS = totalFrames > 0 ? (totalRenderTime / Double(totalFrames)) * 1_000 : 0
        let averageOutputFrameMS = totalFrames > 0 ? (elapsed / Double(totalFrames)) * 1_000 : 0
        let averageWriterWaitMS = totalFrames > 0 ? (totalWriterWaitTime / Double(totalFrames)) * 1_000 : 0
        let bitrateMbps = Double(resolvedBitrate) / 1_000_000
        let status = cancelled ? "cancelled" : "finished"
        let trimDescription = settings.trimRange.map { "\(String(format: "%.2f", $0.startTime))...\(String(format: "%.2f", $0.endTime))" } ?? "full"
        let loggedCodec = settings.exportMode == .quality ? "hevc" : "h264"
        print("[ReplayExport] \(status) mode=\(settings.exportMode.rawValue) codec=\(loggedCodec) format=\(settings.format.rawValue) resolutionPreset=\(settings.resolutionPreset.rawValue) resolution=\(settings.width)x\(settings.height) fps=\(settings.framesPerSecond) bitratePreset=\(settings.bitratePreset.rawValue) bitrate=\(String(format: "%.1f", bitrateMbps))Mbps estimatedSize=\(String(format: "%.1f", estimatedOutputSizeMB))MB camera=\(cameraMode.rawValue) trim=\(trimDescription) frames=\(totalFrames) elapsed=\(String(format: "%.2f", elapsed))s avgOutputFrame=\(String(format: "%.1f", averageOutputFrameMS))ms avgRender=\(String(format: "%.1f", averageRenderMS))ms avgWriterWait=\(String(format: "%.1f", averageWriterWaitMS))ms path=\(renderOptions.showPathTrail) markers=\(renderOptions.showEventMarkers) overlay=\(renderOptions.showOverlay) environment=\(renderOptions.environmentQuality)")
        if averageRenderMS > 50 {
            print("[ReplayExport] warning: average render time is high; keep export at 720p/24fps while stabilization continues.")
        }
    }

    private func overlayedImage(
        _ image: NSImage,
        time: TimeInterval,
        duration: TimeInterval,
        cameraMode: ReplayCameraMode
    ) -> NSImage {
        let copy = NSImage(size: image.size)
        copy.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let title = L10n.s("replay.title", language: L10n.currentLanguage())
        let text = "\(title)  \(cameraMode.displayName)  \(format(time)) / \(format(duration))"
        let rect = NSRect(x: 24, y: image.size.height - 48, width: image.size.width - 48, height: 28)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -6), xRadius: 8, yRadius: 8).fill()
        text.draw(in: rect, withAttributes: attributes)

        copy.unlockFocus()
        return copy
    }

    private func makePixelBuffer(from image: NSImage, pool: CVPixelBufferPool, width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ReplayVideoExportError.pixelBufferUnavailable
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ReplayVideoExportError.imageConversionFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            throw ReplayVideoExportError.imageConversionFailed
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(max(0, t))
        if total < 60 { return "\(total)s" }
        return String(format: "%dm%02ds", total / 60, total % 60)
    }
}
