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
    private let livePhotoDuration = CMTimeMake(value: 550, timescale: 600)
    private let targetVideoSeconds = 3.0
    private let metadataURL: URL?

    init(metadataURL: URL?) {
        self.metadataURL = metadataURL
    }

    func process(videoURL: URL, cacheDirectory: URL, customImageURL: URL?, completion: @escaping (Output?) -> Void) {
        guard let metadataURL = metadataURL else {
            completion(nil)
            return
        }

        let uniqueID = UUID().uuidString
        let documentPath = cacheDirectory
        let durationURL = documentPath.appendingPathComponent("\(uniqueID)-duration").appendingPathExtension("mp4")
        let acceleratedURL = documentPath.appendingPathComponent("\(uniqueID)-accelerate").appendingPathExtension("mp4")
        let resizeURL = documentPath.appendingPathComponent("\(uniqueID)-resize").appendingPathExtension("mp4")
        let imagePath = documentPath.appendingPathComponent("\(uniqueID)-photo").appendingPathExtension("heic")
        let finalVideoPath = documentPath.appendingPathComponent("\(uniqueID)-video").appendingPathExtension("mov")

        let converter = Converter4Video(path: resizeURL.path)

        converter.durationVideo(at: videoURL.path, outputPath: durationURL.path, targetDuration: targetVideoSeconds) { success, error in
            guard success else {
                print("duration adjust failed: \(String(describing: error))")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            converter.accelerateVideo(at: durationURL.path, to: self.livePhotoDuration, outputPath: acceleratedURL.path) { success, error in
                guard success else {
                    print("accelerate failed: \(String(describing: error))")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                converter.resizeVideo(at: acceleratedURL.path, outputPath: resizeURL.path, outputSize: self.livePhotoSize) { success, error in
                    guard success else {
                        print("resize failed: \(String(describing: error))")
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    self.generateOutput(converter: converter,
                                         processedVideoPath: resizeURL,
                                         imagePath: imagePath,
                                         metadataURL: metadataURL,
                                         finalVideoPath: finalVideoPath,
                                         customImageURL: customImageURL) { output in
                        try? FileManager.default.removeItem(at: durationURL)
                        try? FileManager.default.removeItem(at: acceleratedURL)
                        try? FileManager.default.removeItem(at: resizeURL)
                        DispatchQueue.main.async {
                            completion(output)
                        }
                    }
                }
            }
        }
    }

    private func generateOutput(converter: Converter4Video,
                                processedVideoPath: URL,
                                imagePath: URL,
                                metadataURL: URL,
                                finalVideoPath: URL,
                                customImageURL: URL?,
                                completion: @escaping (Output?) -> Void) {
        let assetIdentifier = UUID().uuidString
        let asset = AVURLAsset(url: processedVideoPath)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero

        let captureTime = CMTime(seconds: min(0.5, asset.duration.seconds / 2), preferredTimescale: asset.duration.timescale == 0 ? 600 : asset.duration.timescale)
        let finalize: (UIImage) -> Void = { inputImage in
            let imageConverter = Converter4Image(image: inputImage)
            guard let keyPhotoURL = imageConverter.write(to: imagePath.path, assetIdentifier: assetIdentifier) else {
                completion(nil)
                return
            }

            converter.write(to: finalVideoPath.path, assetIdentifier: assetIdentifier, metadataURL: metadataURL) { success, error in
                if success {
                    completion(Output(keyPhotoURL: keyPhotoURL,
                                      pairedVideoURL: finalVideoPath,
                                      assetIdentifier: assetIdentifier))
                } else {
                    print("metadata write failed: \(String(describing: error))")
                    completion(nil)
                }
            }
        }

        if let customImageURL = customImageURL,
           let customImage = UIImage(contentsOfFile: customImageURL.path) {
            finalize(customImage)
        } else {
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: captureTime)]) { _, image, _, result, error in
                guard result == .succeeded, let image = image else {
                    print("image generation failed: \(String(describing: error))")
                    completion(nil)
                    return
                }
                let uiImage = UIImage(cgImage: image)
                finalize(uiImage)
            }
        }
    }
}

