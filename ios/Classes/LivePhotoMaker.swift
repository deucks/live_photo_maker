import UIKit
import AVFoundation
import MobileCoreServices
import Photos

class LivePhotoMaker {
    typealias LivePhotoResources = (pairedImage: URL, pairedVideo: URL)

    private static let shared = LivePhotoMaker()
    private static let queue = DispatchQueue(label: "com.limit-point.LivePhotoQueue", attributes: .concurrent)

    private lazy var cacheDirectory: URL? = {
        guard let cacheDirectoryURL = try? FileManager.default.url(for: .cachesDirectory,
                                                                   in: .userDomainMask,
                                                                   appropriateFor: nil,
                                                                   create: false) else { return nil }
        let fullDirectory = cacheDirectoryURL.appendingPathComponent("com.limit-point.LivePhoto", isDirectory: true)
        if !FileManager.default.fileExists(atPath: fullDirectory.path) {
            try? FileManager.default.createDirectory(at: fullDirectory, withIntermediateDirectories: true, attributes: nil)
        }
        return fullDirectory
    }()

    private lazy var metadataTemplateURL: URL? = {
        Bundle(for: LivePhotoMaker.self).url(forResource: "metadata", withExtension: "mov")
    }()

    deinit {
        if let cacheDirectory = cacheDirectory {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    // MARK: - Public API

    public class func extractResources(from livePhoto: PHLivePhoto, completion: @escaping (LivePhotoResources?) -> Void) {
        queue.async {
            shared.extractResources(from: livePhoto, completion: completion)
        }
    }

    public class func generate(from imageURL: URL?,
                               videoURL: URL,
                               startSeconds: Double? = nil,
                               progress: @escaping (CGFloat) -> Void,
                               completion: @escaping (PHLivePhoto?, LivePhotoResources?, String?) -> Void) {
        queue.async {
            shared.generate(from: imageURL, videoURL: videoURL, startSeconds: startSeconds, progress: progress, completion: completion)
        }
    }

    public class func saveToLibrary(_ resources: LivePhotoResources, completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let creationRequest = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            creationRequest.addResource(with: .pairedVideo, fileURL: resources.pairedVideo, options: options)
            creationRequest.addResource(with: .photo, fileURL: resources.pairedImage, options: options)
        }, completionHandler: { success, error in
            // The library copies the resource data during the change
            // block, so the staged pair is dead weight either way —
            // without this the cache grew by a few MB per creation.
            try? FileManager.default.removeItem(at: resources.pairedVideo)
            try? FileManager.default.removeItem(at: resources.pairedImage)
            completion(success, error?.localizedDescription)
        })
    }

    // MARK: - Generation

    private func generate(from imageURL: URL?,
                          videoURL: URL,
                          startSeconds: Double? = nil,
                          progress: @escaping (CGFloat) -> Void,
                          completion: @escaping (PHLivePhoto?, LivePhotoResources?, String?) -> Void) {
        guard let cacheDirectory = cacheDirectory, let metadataURL = metadataTemplateURL else {
            DispatchQueue.main.async { completion(nil, nil, "plugin cache directory or metadata template unavailable") }
            return
        }

        // Sweep leftovers from earlier runs (aborted pipelines, pairs
        // staged before the post-save cleanup existed).
        if let stale = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in stale {
                try? FileManager.default.removeItem(at: url)
            }
        }

        DispatchQueue.main.async { progress(0.0) }

        let pipeline = Video2LivePhotoPipeline(metadataURL: metadataURL)
        pipeline.process(videoURL: videoURL, cacheDirectory: cacheDirectory, customImageURL: imageURL, startSeconds: startSeconds) { output, errorMessage in
            guard let output = output else {
                DispatchQueue.main.async { completion(nil, nil, errorMessage ?? "Live Photo pipeline failed") }
                return
            }

            let resources: LivePhotoResources = (pairedImage: output.keyPhotoURL, pairedVideo: output.pairedVideoURL)
            let resourceURLs: [URL] = [output.pairedVideoURL, output.keyPhotoURL]

            PHLivePhoto.request(withResourceFileURLs: resourceURLs,
                                placeholderImage: nil,
                                targetSize: .zero,
                                contentMode: .aspectFit) { livePhoto, info in
                if let isDegraded = info[PHLivePhotoInfoIsDegradedKey] as? Bool, isDegraded {
                    return
                }
                DispatchQueue.main.async {
                    progress(1.0)
                    completion(livePhoto, resources, nil)
                }
            }
        }
    }

    // MARK: - Extraction

    private func extractResources(from livePhoto: PHLivePhoto,
                                  to directoryURL: URL,
                                  completion: @escaping (LivePhotoResources?) -> Void) {
        let assetResources = PHAssetResource.assetResources(for: livePhoto)
        let group = DispatchGroup()
        var keyPhotoURL: URL?
        var videoURL: URL?
        for resource in assetResources {
            let buffer = NSMutableData()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            group.enter()
            PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { data in
                buffer.append(data)
            }) { error in
                if error == nil {
                    if resource.type == .pairedVideo {
                        videoURL = self.saveAssetResource(resource, to: directoryURL, resourceData: buffer as Data)
                    } else {
                        keyPhotoURL = self.saveAssetResource(resource, to: directoryURL, resourceData: buffer as Data)
                    }
                } else {
                    print("Extract resource error: \(String(describing: error))")
                }
                group.leave()
            }
        }
        group.notify(queue: DispatchQueue.main) {
            guard let pairedPhotoURL = keyPhotoURL, let pairedVideoURL = videoURL else {
                completion(nil)
                return
            }
            completion((pairedPhotoURL, pairedVideoURL))
        }
    }

    private func extractResources(from livePhoto: PHLivePhoto, completion: @escaping (LivePhotoResources?) -> Void) {
        if let cacheDirectory = cacheDirectory {
            extractResources(from: livePhoto, to: cacheDirectory, completion: completion)
        } else {
            completion(nil)
        }
    }

    private func saveAssetResource(_ resource: PHAssetResource,
                                   to directory: URL,
                                   resourceData: Data) -> URL? {
        let fileExtension = UTTypeCopyPreferredTagWithClass(resource.uniformTypeIdentifier as CFString,
                                                           kUTTagClassFilenameExtension)?.takeRetainedValue()
        guard let ext = fileExtension else {
            return nil
        }

        var fileURL = directory.appendingPathComponent(UUID().uuidString)
        fileURL.appendPathExtension(ext as String)

        do {
            try resourceData.write(to: fileURL, options: .atomic)
        } catch {
            print("Could not save resource \(resource) to \(fileURL): \(error)")
            return nil
        }
        return fileURL
    }
}

