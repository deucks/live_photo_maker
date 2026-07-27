import Foundation
import AVFoundation
import CoreMedia

/// The metadata that makes a still and a video read as one Live Photo.
///
/// Two pieces are required, and they are separate mechanisms:
///
/// * a **content identifier** — the same UUID on both halves. On the
///   video it is a movie-level `com.apple.quicktime.content.identifier`
///   item; on the still it lives in the Apple maker-note dictionary
///   under key "17" (see `Converter4Image`). If they disagree, iOS files
///   the two resources as unrelated assets.
/// * a **still-image-time marker** — a *timed* metadata track on the
///   video, `com.apple.quicktime.still-image-time`, whose time range
///   says which frame the still was taken from. Without the track the
///   video never registers as the live part of anything.
///
/// Both are synthesised here. Nothing needs to be copied out of a
/// template movie: a template contributes no information that is not
/// already known at write time, and its sample timing belongs to a
/// different video.
enum LivePhotoMetadata {

    static let contentIdentifierKey = "com.apple.quicktime.content.identifier"
    static let stillImageTimeKey = "com.apple.quicktime.still-image-time"
    static let keySpace = "mdta"

    /// Movie-level item pairing this video with a still.
    static func contentIdentifierItem(_ assetIdentifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = contentIdentifierKey as (NSCopying & NSObjectProtocol)
        item.keySpace = AVMetadataKeySpace(rawValue: keySpace)
        item.value = assetIdentifier as (NSCopying & NSObjectProtocol)
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }

    /// The marker sample itself. The value is unused by iOS — presence
    /// and placement are what matter.
    static func stillImageTimeItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = stillImageTimeKey as (NSCopying & NSObjectProtocol)
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.value = 0 as (NSCopying & NSObjectProtocol)
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    /// Format description for the timed metadata track carrying the
    /// marker.
    static func stillImageTimeFormatDescription() -> CMFormatDescription? {
        let spec: NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                "\(keySpace)/\(stillImageTimeKey)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                "com.apple.metadata.datatype.int8"
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &description)
        return description
    }

    /// A writer input wired up for the marker track, or nil if the
    /// format description could not be built.
    static func stillImageTimeAdaptor() -> AVAssetWriterInputMetadataAdaptor? {
        guard let description = stillImageTimeFormatDescription() else { return nil }
        let input = AVAssetWriterInput(mediaType: .metadata,
                                       outputSettings: nil,
                                       sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    /// Marker placed `fraction` of the way through a clip of `duration`,
    /// lasting one frame at `frameRate`.
    ///
    /// This has to line up with the frame the still was captured from —
    /// a still and a marker pointing at different frames is one of the
    /// ways iOS refuses to animate a wallpaper.
    static func stillImageTimeRange(duration: CMTime,
                                    fraction: Double,
                                    frameRate: Int32) -> CMTimeRange {
        let seconds = CMTimeGetSeconds(duration) * fraction
        let start = CMTimeMakeWithSeconds(seconds, preferredTimescale: duration.timescale)
        let frame = CMTimeMake(value: 1, timescale: max(frameRate, 1))
        return CMTimeRange(start: start, duration: frame)
    }

    /// Reads the content identifier already on a movie, if any.
    ///
    /// A clip that carries one was written as a paired video already, so
    /// it does not need re-muxing to attach metadata.
    static func existingContentIdentifier(of asset: AVAsset) -> String? {
        let item = asset.metadata(forFormat: .quickTimeMetadata).first { candidate in
            (candidate.key as? String) == contentIdentifierKey
        }
        guard let value = item?.value as? String, !value.isEmpty else { return nil }
        return value
    }
}
