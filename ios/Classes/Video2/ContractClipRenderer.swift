import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Renders a Live Photo paired clip in a single pass, and measures how
/// much motion a source window carries.
///
/// The three-stage path in `Converter4Video` (duration → accelerate →
/// resize) runs three `AVAssetExportSession` encodes at
/// `HighestQuality`, so the wallpaper takes three generations of loss.
/// Everything those stages do — trim to a window, retime it onto the
/// paired duration, letterbox to 1080x1920 at 60fps — is expressible as
/// one composition, so this renders it with one reader/writer pair and
/// exact control over bitrate and colour.
///
/// Output lands on the contract `Video2LivePhotoPipeline.matchesContract`
/// checks, so the pipeline copies it through without re-encoding.
final class ContractClipRenderer {

    struct Spec {
        /// Duration iOS requires of the paired video (~0.917s). Longer
        /// clips get "Motion Not Available".
        var pairedDuration = CMTimeMake(value: 550, timescale: 600)
        var renderSize = CGSize(width: 1080, height: 1920)
        var frameRate: Int32 = 60
        /// Tried in order; the first output at or under `maxBytes` wins.
        var bitrateCandidates: [Int] = [12_000_000, 9_000_000, 6_000_000]
        var maxBytes = 3 * 1024 * 1024
    }

    enum RenderError: LocalizedError {
        case noVideoTrack
        case compositionFailed(String)
        case encodeFailed(String)
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "source has no video track"
            case .compositionFailed(let m): return "composition failed: \(m)"
            case .encodeFailed(let m): return "encode failed: \(m)"
            case .tooLarge(let limit):
                return "could not produce a segment under \(limit / (1024 * 1024)) MB"
            }
        }
    }

    /// Where the still is taken from, as a fraction of the clip. The
    /// key-photo sampler and the still-image-time marker both read this
    /// so they cannot drift apart.
    static let stillImageFraction = 0.5

    private let spec: Spec

    init(spec: Spec = Spec()) {
        self.spec = spec
    }

    // MARK: - Render

    /// Takes `windowSeconds` of source starting at `startSeconds` and
    /// squeezes it into the paired duration — so a 3s window becomes a
    /// ~3.27x retime, and doubling the window doubles apparent speed.
    /// `assetIdentifier` is embedded as the content identifier, and a
    /// still-image-time marker is written at the clip midpoint, so the
    /// output is already a valid paired video. Pass the same identifier
    /// to the still and no re-mux is needed afterwards.
    func render(sourceURL: URL,
                startSeconds: Double,
                windowSeconds: Double,
                outputURL: URL,
                assetIdentifier: String,
                completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = asset.tracks(withMediaType: .video).first else {
            completion(.failure(RenderError.noVideoTrack))
            return
        }

        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        do {
            (composition, videoComposition) = try buildComposition(
                asset: asset,
                sourceTrack: sourceTrack,
                startSeconds: startSeconds,
                windowSeconds: windowSeconds)
        } catch {
            completion(.failure(error))
            return
        }

        // Walk the ladder until one lands inside the size budget. Each
        // attempt is a full encode, but the clip is under a second.
        var lastError: Error?
        for bitrate in spec.bitrateCandidates {
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try encode(composition: composition,
                           videoComposition: videoComposition,
                           bitrate: bitrate,
                           outputURL: outputURL,
                           assetIdentifier: assetIdentifier)
            } catch {
                lastError = error
                continue
            }

            let size = (try? FileManager.default
                .attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? nil
            if let size = size, size > spec.maxBytes {
                lastError = RenderError.tooLarge(spec.maxBytes)
                continue
            }
            completion(.success(outputURL))
            return
        }

        try? FileManager.default.removeItem(at: outputURL)
        completion(.failure(lastError ?? RenderError.tooLarge(spec.maxBytes)))
    }

    private func buildComposition(asset: AVURLAsset,
                                  sourceTrack: AVAssetTrack,
                                  startSeconds: Double,
                                  windowSeconds: Double)
        throws -> (AVMutableComposition, AVMutableVideoComposition) {

        let assetSeconds = CMTimeGetSeconds(asset.duration)
        let timescale = asset.duration.timescale == 0 ? 600 : asset.duration.timescale

        // Clamp the window so it always sits inside the asset; a source
        // shorter than the requested window just contributes what it has.
        let window = max(min(windowSeconds, assetSeconds), 0.05)
        let start = min(max(startSeconds, 0), max(assetSeconds - window, 0))

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.compositionFailed("could not add a video track")
        }

        let range = CMTimeRange(
            start: CMTimeMakeWithSeconds(start, preferredTimescale: timescale),
            duration: CMTimeMakeWithSeconds(window, preferredTimescale: timescale))

        do {
            try track.insertTimeRange(range, of: sourceTrack, at: .zero)
        } catch {
            throw RenderError.compositionFailed(error.localizedDescription)
        }
        track.preferredTransform = sourceTrack.preferredTransform

        // Audio is deliberately absent: wallpapers are silent and the
        // Live Photo writer discards it anyway, so it would only eat
        // into the size budget.

        // Retime the whole composition so the window plays back over the
        // paired duration.
        composition.scaleTimeRange(
            CMTimeRange(start: .zero, duration: composition.duration),
            toDuration: spec.pairedDuration)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = spec.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: spec.frameRate)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(aspectFitTransform(for: sourceTrack), at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        return (composition, videoComposition)
    }

    /// Scales the source to fit inside the render size without cropping
    /// and centres it — the equivalent of ffmpeg's
    /// `scale=…:force_original_aspect_ratio=decrease` followed by `pad`.
    private func aspectFitTransform(for track: AVAssetTrack) -> CGAffineTransform {
        let preferred = track.preferredTransform
        let transformed = track.naturalSize.applying(preferred)
        let natural = CGSize(width: abs(transformed.width),
                             height: abs(transformed.height))
        guard natural.width > 0, natural.height > 0 else { return preferred }

        let scale = min(spec.renderSize.width / natural.width,
                        spec.renderSize.height / natural.height)
        let translateX = (spec.renderSize.width - natural.width * scale) / 2
        let translateY = (spec.renderSize.height - natural.height * scale) / 2
        let fit = CGAffineTransform(translationX: translateX, y: translateY)
            .scaledBy(x: scale, y: scale)
        return preferred.concatenating(fit)
    }

    private func encode(composition: AVMutableComposition,
                        videoComposition: AVMutableVideoComposition,
                        bitrate: Int,
                        outputURL: URL,
                        assetIdentifier: String) throws {
        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ])
        readerOutput.videoComposition = videoComposition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw RenderError.encodeFailed("reader rejected the composition output")
        }
        reader.add(readerOutput)

        // Colour is pinned to bt709/tv explicitly. Left unset, the tags
        // follow the source, and mismatched primaries are one of the
        // ways iOS refuses to animate a wallpaper.
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(spec.renderSize.width),
                AVVideoHeightKey: Int(spec.renderSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: spec.frameRate,
                    AVVideoExpectedSourceFrameRateKey: spec.frameRate,
                ],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw RenderError.encodeFailed("writer rejected the video input")
        }
        writer.add(writerInput)

        // Live Photo metadata goes in during this same pass. Attaching
        // it afterwards would mean reading the file back and rewriting
        // it purely to add two small pieces of metadata.
        writer.metadata = [LivePhotoMetadata.contentIdentifierItem(assetIdentifier)]
        guard let stillAdaptor = LivePhotoMetadata.stillImageTimeAdaptor() else {
            throw RenderError.encodeFailed("could not build the still-image-time track")
        }
        guard writer.canAdd(stillAdaptor.assetWriterInput) else {
            throw RenderError.encodeFailed("writer rejected the metadata input")
        }
        writer.add(stillAdaptor.assetWriterInput)

        guard writer.startWriting() else {
            throw RenderError.encodeFailed(
                writer.error?.localizedDescription ?? "writer would not start")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw RenderError.encodeFailed(
                reader.error?.localizedDescription ?? "reader would not start")
        }

        // Marker sits at the midpoint, matching where the key photo is
        // sampled from. Appended before the video samples so the track
        // exists regardless of how the video pass terminates.
        let markerRange = LivePhotoMetadata.stillImageTimeRange(
            duration: spec.pairedDuration,
            fraction: Self.stillImageFraction,
            frameRate: spec.frameRate)
        let marker = AVTimedMetadataGroup(
            items: [LivePhotoMetadata.stillImageTimeItem()], timeRange: markerRange)
        if !stillAdaptor.append(marker) {
            reader.cancelReading()
            writer.cancelWriting()
            throw RenderError.encodeFailed("could not append the still-image-time marker")
        }
        stillAdaptor.assetWriterInput.markAsFinished()

        let queue = DispatchQueue(label: "com.deucks.livephoto.contractRender")
        let done = DispatchSemaphore(value: 0)

        writerInput.requestMediaDataWhenReady(on: queue) {
            while writerInput.isReadyForMoreMediaData {
                guard reader.status == .reading,
                      let buffer = readerOutput.copyNextSampleBuffer() else {
                    writerInput.markAsFinished()
                    done.signal()
                    return
                }
                if !writerInput.append(buffer) {
                    reader.cancelReading()
                    writerInput.markAsFinished()
                    done.signal()
                    return
                }
            }
        }

        done.wait()

        if reader.status == .failed {
            writer.cancelWriting()
            throw RenderError.encodeFailed(
                reader.error?.localizedDescription ?? "read failed")
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        if writer.status != .completed {
            throw RenderError.encodeFailed(
                writer.error?.localizedDescription ?? "write did not complete")
        }
    }

    // MARK: - Motion

    struct MotionSample {
        /// Mean absolute luma change between consecutive frames, on a
        /// 160-wide decode — the same quantity, at the same scale, as
        /// ffmpeg's `signalstats` YDIF.
        let meanYDiff: Double
        /// Frame rate measured from presentation timestamps, so 24/30/60
        /// sources are comparable.
        let fps: Double
        let frameCount: Int
    }

    /// Measures motion over a source window.
    ///
    /// The 160-wide downscale is not an optimisation — YDIF depends on
    /// the resolution it is measured at, because downscaling averages
    /// away high-frequency detail. Any calibration built on top of this
    /// number only holds if the scale matches.
    func measureMotion(sourceURL: URL,
                       startSeconds: Double,
                       windowSeconds: Double) -> MotionSample? {
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = asset.tracks(withMediaType: .video).first else {
            return nil
        }

        let assetSeconds = CMTimeGetSeconds(asset.duration)
        let timescale = asset.duration.timescale == 0 ? 600 : asset.duration.timescale
        let window = max(min(windowSeconds, assetSeconds), 0.05)
        let start = min(max(startSeconds, 0), max(assetSeconds - window, 0))

        let transformed = sourceTrack.naturalSize.applying(sourceTrack.preferredTransform)
        let natural = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard natural.width > 0, natural.height > 0 else { return nil }

        let targetWidth: CGFloat = 160
        // Height keeps aspect and is rounded to even, matching `-2`.
        let targetHeight = max(2, (targetWidth * natural.height / natural.width)
            .rounded() / 2 * 2)
        let renderSize = CGSize(width: targetWidth, height: targetHeight)

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let range = CMTimeRange(
            start: CMTimeMakeWithSeconds(start, preferredTimescale: timescale),
            duration: CMTimeMakeWithSeconds(window, preferredTimescale: timescale))
        guard (try? track.insertTimeRange(range, of: sourceTrack, at: .zero)) != nil else {
            return nil
        }
        track.preferredTransform = sourceTrack.preferredTransform

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        // Nominal frame rate of the source, so we sample every frame
        // rather than resampling to a fixed cadence.
        let nominal = sourceTrack.nominalFrameRate > 0 ? sourceTrack.nominalFrameRate : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(nominal.rounded()))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let scale = min(renderSize.width / natural.width, renderSize.height / natural.height)
        layer.setTransform(
            sourceTrack.preferredTransform.concatenating(
                CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        guard let reader = try? AVAssetReader(asset: composition) else { return nil }
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var previous: [UInt8]?
        var diffs: [Double] = []
        var firstPTS: Double?
        var lastPTS: Double?

        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
            if firstPTS == nil { firstPTS = pts }
            lastPTS = pts

            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { continue }
            let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)

            // Copy the luma plane row-wise, dropping the row padding so
            // successive frames are directly comparable.
            var luma = [UInt8](repeating: 0, count: width * height)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let src = bytes.advanced(by: row * stride)
                luma.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: row * width)
                        .update(from: src, count: width)
                }
            }

            if let prev = previous, prev.count == luma.count {
                var total = 0
                for i in 0..<luma.count {
                    total += abs(Int(luma[i]) - Int(prev[i]))
                }
                diffs.append(Double(total) / Double(luma.count))
            }
            previous = luma
        }

        guard diffs.count >= 8,
              let first = firstPTS,
              let last = lastPTS,
              last > first else { return nil }

        let fps = Double(diffs.count) / (last - first)
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        return MotionSample(meanYDiff: mean, fps: fps, frameCount: diffs.count + 1)
    }
}
