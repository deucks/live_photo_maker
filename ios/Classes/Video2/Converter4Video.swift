import Foundation
import AVFoundation

class Converter4Video: NSObject {
    private let metadataContentIdentifierKey = "com.apple.quicktime.content.identifier"
    private let metadataStillImageTimeKey = "com.apple.quicktime.still-image-time"
    private let metadataKeySpace = "mdta"
    private let path: String

    private lazy var asset: AVURLAsset = {
        let url = NSURL(fileURLWithPath: self.path)
        return AVURLAsset(url: url as URL)
    }()

    init(path: String) {
        self.path = path
    }

    func write(to destination: String, assetIdentifier: String, metadataURL: URL, completion: @escaping (Bool, Error?) -> Void) {
        do {
            let metadataAsset = AVURLAsset(url: metadataURL)
            let templateIdentifier = metadataAsset.metadata(forFormat: .quickTimeMetadata).first(where: { item in
                (item.key as? String) == metadataContentIdentifierKey
            })?.value as? String
            let readerVideo = try AVAssetReader(asset: asset)
            let readerMetadata = try AVAssetReader(asset: metadataAsset)
            let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: destination), fileType: .mov)

            var videoIOs = [(AVAssetWriterInput, AVAssetReaderTrackOutput)]()
            var metadataIOs = [(AVAssetWriterInputMetadataAdaptor, AVAssetReaderTrackOutput)]()

            loadTracks(asset: self.asset, type: .video) { videoTracks in
                for track in videoTracks {
                    let trackReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA as UInt32)])
                    if readerVideo.canAdd(trackReaderOutput) {
                        readerVideo.add(trackReaderOutput)
                    }

                    let videoInput = AVAssetWriterInput(mediaType: .video,
                                                        outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: track.naturalSize.width,
                                                                         AVVideoHeightKey: track.naturalSize.height])
                    videoInput.transform = track.preferredTransform
                    videoInput.expectsMediaDataInRealTime = true
                    if writer.canAdd(videoInput) {
                        writer.add(videoInput)
                        videoIOs.append((videoInput, trackReaderOutput))
                    }
                }

                self.loadTracks(asset: metadataAsset, type: .metadata) { metadataTracks in
                    for track in metadataTracks {
                        let trackReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                        if readerMetadata.canAdd(trackReaderOutput) {
                            readerMetadata.add(trackReaderOutput)
                        }

                        let writerInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: track.formatDescriptions.first as! CMFormatDescription)
                        writerInput.expectsMediaDataInRealTime = false
                        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: writerInput)
                        if writer.canAdd(writerInput) {
                            writer.add(writerInput)
                            metadataIOs.append((adaptor, trackReaderOutput))
                        }
                    }

                    writer.metadata = [self.metadataForAssetID(assetIdentifier)]
                    let stillImageAdaptor = self.createMetadataAdaptorForStillImageTime()
                    writer.add(stillImageAdaptor.assetWriterInput)

                    writer.startWriting()
                    readerVideo.startReading()
                    readerMetadata.startReading()
                    writer.startSession(atSourceTime: .zero)

                    let frameCount = max(self.asset.countFrames(exact: false), 1)
                    stillImageAdaptor.append(AVTimedMetadataGroup(items: [self.metadataForStillImageTime()],
                                                                 timeRange: self.asset.makeStillImageTimeRange(percent: 0.5,
                                                                                                            inFrameCount: frameCount)))

                    let dispatchGroup = DispatchGroup()

                    for (videoInput, videoOutput) in videoIOs {
                        dispatchGroup.enter()
                        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "assetWriterQueue.video")) {
                            while videoInput.isReadyForMoreMediaData {
                                if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                                    videoInput.append(sampleBuffer)
                                } else {
                                    videoInput.markAsFinished()
                                    dispatchGroup.leave()
                                    break
                                }
                            }
                        }
                    }

                    for (metadataAdaptor, metadataOutput) in metadataIOs {
                        dispatchGroup.enter()
                        metadataAdaptor.assetWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "assetWriterQueue.metadata")) {
                            while metadataAdaptor.assetWriterInput.isReadyForMoreMediaData {
                                guard let sampleBuffer = metadataOutput.copyNextSampleBuffer() else {
                                    metadataAdaptor.assetWriterInput.markAsFinished()
                                    dispatchGroup.leave()
                                    break
                                }
                                guard let group = AVTimedMetadataGroup(sampleBuffer: sampleBuffer) else { continue }
                                if let templateIdentifier = templateIdentifier {
                                    let rewrittenItems: [AVMetadataItem] = group.items.compactMap { item in
                                        guard let mutable = item.mutableCopy() as? AVMutableMetadataItem else { return item }
                                        if let value = mutable.value as? String,
                                           value.contains(templateIdentifier) {
                                            mutable.value = value.replacingOccurrences(of: templateIdentifier, with: assetIdentifier) as (NSCopying & NSObjectProtocol)?
                                        }
                                        return mutable.copy() as? AVMetadataItem
                                    }
                                    let rewrittenGroup = AVTimedMetadataGroup(items: rewrittenItems, timeRange: group.timeRange)
                                    metadataAdaptor.append(rewrittenGroup)
                                } else {
                                    metadataAdaptor.append(group)
                                }
                            }
                        }
                    }

                    dispatchGroup.notify(queue: .main) {
                        if readerVideo.status == .completed && readerMetadata.status == .completed && writer.status == .writing {
                            writer.finishWriting {
                                completion(writer.status == .completed, writer.error)
                            }
                        } else {
                            if let error = readerVideo.error {
                                completion(false, error)
                            } else if let error = readerMetadata.error {
                                completion(false, error)
                            } else if let error = writer.error {
                                completion(false, error)
                            } else {
                                completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                            }
                        }
                    }
                }
            }
        } catch {
            completion(false, error)
        }
    }

    func durationVideo(at inputPath: String, outputPath: String, targetDuration: Double, completion: @escaping (Bool, Error?) -> Void) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
        let length = CMTimeGetSeconds(asset.duration)
        let timeScale = asset.duration.timescale == 0 ? 600 : asset.duration.timescale

        if length <= targetDuration {
            let composition = AVMutableComposition()
            guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let assetTrack = asset.tracks(withMediaType: .video).first else {
                completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
                return
            }

            compositionTrack.preferredTransform = assetTrack.preferredTransform
            do {
                try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: assetTrack, at: .zero)
            } catch {
                completion(false, error)
                return
            }

            guard let firstFrame = getFrame(from: asset, at: CMTime(value: 0, timescale: timeScale)),
                  let lastFrame = getFrame(from: asset, at: CMTimeSubtract(asset.duration, CMTime(value: 1, timescale: timeScale))) else {
                completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
                return
            }

            let prefixDuration = CMTime(seconds: (targetDuration - length) / 2, preferredTimescale: timeScale)
            let suffixDuration = CMTime(seconds: (targetDuration - length) / 2, preferredTimescale: timeScale)

            let tempDir = FileManager.default.temporaryDirectory
            let firstURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            let lastURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")

            let group = DispatchGroup()
            var prefixSuccess = prefixDuration.seconds == 0
            var suffixSuccess = suffixDuration.seconds == 0

            if prefixDuration.seconds > 0 {
                group.enter()
                createVideo(from: firstFrame, duration: CMTime(value: Int64(timeScale), timescale: timeScale), outputURL: firstURL) { success in
                    if success {
                        self.appendToComposition(compositionTrack, asset: AVAsset(url: firstURL), duration: prefixDuration, at: .zero)
                        prefixSuccess = true
                    }
                    group.leave()
                }
            }

            if suffixDuration.seconds > 0 {
                group.enter()
                let insertionPoint = CMTimeAdd(prefixDuration, asset.duration)
                createVideo(from: lastFrame, duration: CMTime(value: Int64(timeScale), timescale: timeScale), outputURL: lastURL) { success in
                    if success {
                        self.appendToComposition(compositionTrack, asset: AVAsset(url: lastURL), duration: suffixDuration, at: insertionPoint)
                        suffixSuccess = true
                    }
                    group.leave()
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                defer {
                    try? FileManager.default.removeItem(at: firstURL)
                    try? FileManager.default.removeItem(at: lastURL)
                }
                guard prefixSuccess && suffixSuccess else {
                    completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
                    return
                }
                self.exportAsset(composition, preset: AVAssetExportPresetHighestQuality, outputURL: URL(fileURLWithPath: outputPath), completion: completion)
            }
        } else {
            let startTime = length / 2 - targetDuration / 2
            let endTime = length / 2 + targetDuration / 2
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
                return
            }
            exportSession.outputURL = URL(fileURLWithPath: outputPath)
            exportSession.outputFileType = .mp4
            exportSession.timeRange = CMTimeRangeFromTimeToTime(start: CMTimeMakeWithSeconds(startTime, preferredTimescale: Int32(timeScale)),
                                                                end: CMTimeMakeWithSeconds(endTime, preferredTimescale: Int32(timeScale)))
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    completion(true, nil)
                default:
                    completion(false, exportSession.error)
                }
            }
        }
    }

    func accelerateVideo(at inputPath: String, to duration: CMTime, outputPath: String, completion: @escaping (Bool, Error?) -> Void) {
        let videoURL = URL(fileURLWithPath: inputPath)
        let asset = AVAsset(url: videoURL)
        let composition = AVMutableComposition()
        loadTracks(asset: asset, type: .video) { videoTracks in
            guard let videoTrack = videoTracks.first,
                  let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
                return
            }

            do {
                try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
            } catch {
                completion(false, error)
                return
            }

            compositionVideoTrack.preferredTransform = videoTrack.preferredTransform

            if let audioTrack = asset.tracks(withMediaType: .audio).first,
               let audioCompositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try audioCompositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                } catch {
                    // ignore audio failure
                }
            }

            compositionVideoTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: composition.duration), toDuration: duration)
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
                return
            }
            exportSession.outputURL = URL(fileURLWithPath: outputPath)
            exportSession.outputFileType = .mov
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    completion(true, nil)
                default:
                    completion(false, exportSession.error)
                }
            }
        }
    }

    func resizeVideo(at inputPath: String, outputPath: String, outputSize: CGSize, completion: @escaping (Bool, Error?) -> Void) {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        let asset = AVAsset(url: inputURL)
        loadTracks(asset: asset, type: .video) { videoTracks in
            guard let videoTrack = videoTracks.first else {
                completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
                return
            }

            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
                return
            }
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = true

            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = outputSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 60)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let preferredTransform = videoTrack.preferredTransform
            let originalSize = CGSize(width: videoTrack.naturalSize.width, height: videoTrack.naturalSize.height)
            let transformedSize = originalSize.applying(preferredTransform)
            let absoluteSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
            let widthRatio = outputSize.width / absoluteSize.width
            let heightRatio = outputSize.height / absoluteSize.height
            let scaleFactor = min(widthRatio, heightRatio)
            let newWidth = absoluteSize.width * scaleFactor
            let newHeight = absoluteSize.height * scaleFactor
            let translateX = (outputSize.width - newWidth) / 2
            let translateY = (outputSize.height - newHeight) / 2
            let translateTransform = CGAffineTransform(translationX: translateX, y: translateY).scaledBy(x: scaleFactor, y: scaleFactor)
            layerInstruction.setTransform(preferredTransform.concatenating(translateTransform), at: .zero)

            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]

            exportSession.videoComposition = videoComposition
            exportSession.exportAsynchronously {
                DispatchQueue.main.async {
                    switch exportSession.status {
                    case .completed:
                        completion(true, nil)
                    default:
                        completion(false, exportSession.error)
                    }
                }
            }
        }
    }

    private func metadata() -> [AVMetadataItem] {
        return asset.metadata(forFormat: AVMetadataFormat.quickTimeMetadata)
    }

    private func createMetadataAdaptorForStillImageTime() -> AVAssetWriterInputMetadataAdaptor {
        let keyStillImageTime = metadataStillImageTimeKey
        let keySpaceQuickTimeMetadata = metadataKeySpace
        let spec: NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                "\(keySpaceQuickTimeMetadata)/\(keyStillImageTime)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                "com.apple.metadata.datatype.int8"
        ]
        var desc: CMFormatDescription? = nil
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
                                                                    metadataType: kCMMetadataFormatType_Boxed,
                                                                    metadataSpecifications: [spec] as CFArray,
                                                                    formatDescriptionOut: &desc)
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    private func metadataForAssetID(_ assetIdentifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = metadataContentIdentifierKey as (NSCopying & NSObjectProtocol)?
        item.keySpace = AVMetadataKeySpace(rawValue: metadataKeySpace)
        item.value = assetIdentifier as (NSCopying & NSObjectProtocol)?
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }

    private func metadataForStillImageTime() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = metadataStillImageTimeKey as (NSCopying & NSObjectProtocol)?
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.value = 0 as (NSCopying & NSObjectProtocol)?
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item.copy() as! AVMetadataItem
    }

    private func loadTracks(asset: AVAsset, type: AVMediaType, completion: @escaping ([AVAssetTrack]) -> Void) {
        if #available(iOS 15.0, *) {
            asset.loadTracks(withMediaType: type) { tracks, error in
                if let error = error {
                    print("Load tracks error: \(error)")
                }
                completion(tracks ?? [])
            }
        } else {
            asset.loadValuesAsynchronously(forKeys: [#keyPath(AVAsset.tracks)]) {
                var error: NSError?
                let status = asset.statusOfValue(forKey: #keyPath(AVAsset.tracks), error: &error)
                if status == .loaded {
                    completion(asset.tracks(withMediaType: type))
                } else {
                    if let error = error { print("Load tracks error: \(error)") }
                    completion([])
                }
            }
        }
    }

    private func getFrame(from asset: AVAsset, at timestamp: CMTime) -> UIImage? {
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.appliesPreferredTrackTransform = true
        var actualTime = CMTime.zero
        guard let cgImage = try? imageGenerator.copyCGImage(at: timestamp, actualTime: &actualTime) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func appendToComposition(_ compositionTrack: AVMutableCompositionTrack, asset: AVAsset, duration: CMTime, at insertTime: CMTime) {
        guard let assetTrack = asset.tracks(withMediaType: .video).first else { return }
        let frameDuration = CMTime(value: 1, timescale: 30)
        var currentTime = insertTime
        let endTime = CMTimeAdd(insertTime, duration)

        while currentTime < endTime {
            let nextTime = CMTimeAdd(currentTime, frameDuration)
            do {
                try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: frameDuration), of: assetTrack, at: currentTime)
            } catch {
                break
            }
            currentTime = nextTime
        }
    }

    private func createVideo(from image: UIImage, duration: CMTime, outputURL: URL, completion: @escaping (Bool) -> Void) {
        do {
            try? FileManager.default.removeItem(at: outputURL)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: NSNumber(value: Float(image.size.width)),
                AVVideoHeightKey: NSNumber(value: Float(image.size.height))
            ])
            guard writer.canAdd(writerInput) else {
                completion(false)
                return
            }
            writer.add(writerInput)

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
            guard let buffer = pixelBuffer(from: image) else {
                completion(false)
                return
            }

            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let frameDuration = CMTime(value: 1, timescale: 30)
            let totalFrames = max(Int(duration.seconds * 30), 1)
            var frameIndex = 0
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "createVideoQueue")) {
                while writerInput.isReadyForMoreMediaData && frameIndex < totalFrames {
                    let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                    adaptor.append(buffer, withPresentationTime: presentationTime)
                    frameIndex += 1
                }
                writerInput.markAsFinished()
                writer.finishWriting {
                    completion(writer.status == .completed)
                }
            }
        } catch {
            completion(false)
        }
    }

    private func exportAsset(_ asset: AVAsset, preset: String, outputURL: URL, completion: @escaping (Bool, Error?) -> Void) {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            completion(false, NSError(domain: "VideoProcessing", code: -1, userInfo: nil))
            return
        }
        try? FileManager.default.removeItem(at: outputURL)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(true, nil)
            default:
                completion(false, exportSession.error)
            }
        }
    }

    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(image.size.width),
                                         Int(image.size.height),
                                         kCVPixelFormatType_32ARGB,
                                         attrs,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: Int(image.size.width),
                                      height: Int(image.size.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            return nil
        }

        context.translateBy(x: 0, y: image.size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        UIGraphicsPopContext()

        return buffer
    }
}

