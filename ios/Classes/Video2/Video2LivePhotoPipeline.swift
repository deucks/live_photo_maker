import Foundation
import AVFoundation
import UIKit

public final class Video2LivePhotoPipeline: NSObject {
    public struct Output {
        let keyPhotoURL: URL
        let pairedVideoURL: URL
        let assetIdentifier: String
    }

    private let livePhotoSize = CGSize(width: 1080, height: 1920)
    // iOS only enables wallpaper "motion" when the paired video is very
    // short (~0.92s) — longer clips get "Motion Not Available". The
    // lockscreen then plays this clip slowed down over ~3 seconds, so the
    // pipeline squeezes targetVideoSeconds of real-time motion into it:
    // 3s ÷ 0.9167s ≈ 3.27x, which cancels out to ~1x apparent speed on
    // the lockscreen. Feed this pipeline real-time (1x) video — or a clip
    // already at exactly this duration and size, which takes the fast
    // path below and is copied through without re-encoding.
    private let livePhotoDuration = CMTimeMake(value: 550, timescale: 600)
    private let targetVideoSeconds = 3.0

    override init() {
        super.init()
    }

    /// `startSeconds` selects where in the source the kept window begins.
    /// Pass nil to take the middle. It is ignored when the source is already
    /// at or under `targetVideoSeconds`, or when the fast path applies.
    func process(videoURL: URL, cacheDirectory: URL, customImageURL: URL?, startSeconds: Double? = nil, completion: @escaping (Output?, String?) -> Void) {
        let uniqueID = UUID().uuidString
        let documentPath = cacheDirectory
        let durationURL = documentPath.appendingPathComponent("\(uniqueID)-duration").appendingPathExtension("mp4")
        let acceleratedURL = documentPath.appendingPathComponent("\(uniqueID)-accelerate").appendingPathExtension("mp4")
        let resizeURL = documentPath.appendingPathComponent("\(uniqueID)-resize").appendingPathExtension("mp4")
        let imagePath = documentPath.appendingPathComponent("\(uniqueID)-photo").appendingPathExtension("heic")
        let finalVideoPath = documentPath.appendingPathComponent("\(uniqueID)-video").appendingPathExtension("mov")

        let incoming = AVURLAsset(url: videoURL)

        // Fastest path: the clip is already on the contract *and* carries
        // its own content identifier, so it was written as a paired video
        // (ContractClipRenderer does this during the encode). Nothing to
        // re-mux — pair it with a still bearing the same identifier.
        if matchesContract(incoming),
           let existingIdentifier = LivePhotoMetadata.existingContentIdentifier(of: incoming) {
            generateStill(for: incoming,
                          assetIdentifier: existingIdentifier,
                          imagePath: imagePath,
                          customImageURL: customImageURL) { keyPhotoURL, errorMessage in
                DispatchQueue.main.async {
                    guard let keyPhotoURL = keyPhotoURL else {
                        completion(nil, errorMessage)
                        return
                    }
                    completion(Output(keyPhotoURL: keyPhotoURL,
                                      pairedVideoURL: videoURL,
                                      assetIdentifier: existingIdentifier), nil)
                }
            }
            return
        }

        // Fast path: on the contract but with no metadata yet, so the
        // frames are copied through uncompressed-untouched and only the
        // metadata is added.
        if matchesContract(incoming) {
            let converter = Converter4Video(path: videoURL.path)
            generateOutput(converter: converter,
                           processedVideoPath: videoURL,
                           imagePath: imagePath,
                           finalVideoPath: finalVideoPath,
                           customImageURL: customImageURL,
                           passthrough: true) { output, errorMessage in
                DispatchQueue.main.async { completion(output, errorMessage) }
            }
            return
        }

        let converter = Converter4Video(path: resizeURL.path)

        let resizeAndFinish: (URL) -> Void = { retimedURL in
            converter.resizeVideo(at: retimedURL.path, outputPath: resizeURL.path, outputSize: self.livePhotoSize) { success, error in
                guard success else {
                    DispatchQueue.main.async { completion(nil, "resize failed: \(error?.localizedDescription ?? "unknown")") }
                    return
                }
                self.generateOutput(converter: converter,
                                     processedVideoPath: resizeURL,
                                     imagePath: imagePath,
                                     finalVideoPath: finalVideoPath,
                                     customImageURL: customImageURL,
                                     passthrough: false) { output, errorMessage in
                    try? FileManager.default.removeItem(at: durationURL)
                    try? FileManager.default.removeItem(at: acceleratedURL)
                    try? FileManager.default.removeItem(at: resizeURL)
                    DispatchQueue.main.async {
                        completion(output, errorMessage)
                    }
                }
            }
        }

        converter.durationVideo(at: videoURL.path, outputPath: durationURL.path, targetDuration: targetVideoSeconds, startSeconds: startSeconds) { success, error in
            guard success else {
                DispatchQueue.main.async { completion(nil, "duration adjust failed: \(error?.localizedDescription ?? "unknown")") }
                return
            }

            converter.accelerateVideo(at: durationURL.path, to: self.livePhotoDuration, outputPath: acceleratedURL.path) { success, error in
                guard success else {
                    DispatchQueue.main.async { completion(nil, "retime failed: \(error?.localizedDescription ?? "unknown")") }
                    return
                }
                resizeAndFinish(acceleratedURL)
            }
        }
    }

    /// True when the input already satisfies the Live Photo wallpaper
    /// contract: ~0.92s long and 1080x1920 after rotation.
    private func matchesContract(_ asset: AVURLAsset) -> Bool {
        let duration = CMTimeGetSeconds(asset.duration)
        guard abs(duration - CMTimeGetSeconds(livePhotoDuration)) <= 0.1 else { return false }
        guard let track = asset.tracks(withMediaType: .video).first else { return false }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        return abs(size.width - livePhotoSize.width) <= 2 && abs(size.height - livePhotoSize.height) <= 2
    }

    private func generateOutput(converter: Converter4Video,
                                processedVideoPath: URL,
                                imagePath: URL,
                                finalVideoPath: URL,
                                customImageURL: URL?,
                                passthrough: Bool,
                                completion: @escaping (Output?, String?) -> Void) {
        let assetIdentifier = UUID().uuidString
        let asset = AVURLAsset(url: processedVideoPath)

        generateStill(for: asset,
                      assetIdentifier: assetIdentifier,
                      imagePath: imagePath,
                      customImageURL: customImageURL) { keyPhotoURL, errorMessage in
            guard let keyPhotoURL = keyPhotoURL else {
                completion(nil, errorMessage)
                return
            }
            converter.write(to: finalVideoPath.path,
                            assetIdentifier: assetIdentifier,
                            passthrough: passthrough) { success, error in
                if success {
                    completion(Output(keyPhotoURL: keyPhotoURL,
                                      pairedVideoURL: finalVideoPath,
                                      assetIdentifier: assetIdentifier), nil)
                } else {
                    completion(nil, "paired video write failed: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }

    /// Captures the key photo and writes it with `assetIdentifier` in the
    /// Apple maker note, which is what pairs it with the video.
    ///
    /// The frame is taken at the same fraction of the clip as the
    /// still-image-time marker. Those two pointing at different frames is
    /// one of the ways iOS declines to animate a wallpaper, so the
    /// fraction comes from a single constant rather than being restated.
    private func generateStill(for asset: AVAsset,
                               assetIdentifier: String,
                               imagePath: URL,
                               customImageURL: URL?,
                               completion: @escaping (URL?, String?) -> Void) {
        let finalize: (UIImage) -> Void = { inputImage in
            let imageConverter = Converter4Image(image: inputImage)
            guard let keyPhotoURL = imageConverter.write(to: imagePath.path,
                                                         assetIdentifier: assetIdentifier) else {
                completion(nil, "key photo metadata write failed")
                return
            }
            completion(keyPhotoURL, nil)
        }

        if let customImageURL = customImageURL,
           let customImage = UIImage(contentsOfFile: customImageURL.path) {
            finalize(customImage)
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero

        let timescale = asset.duration.timescale == 0 ? 600 : asset.duration.timescale
        let captureTime = CMTimeMakeWithSeconds(
            CMTimeGetSeconds(asset.duration) * ContractClipRenderer.stillImageFraction,
            preferredTimescale: timescale)

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: captureTime)]) { _, image, _, result, error in
            guard result == .succeeded, let image = image else {
                completion(nil, "key photo capture failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            finalize(UIImage(cgImage: image))
        }
    }
}
