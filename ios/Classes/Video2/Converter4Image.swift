import UIKit
import UniformTypeIdentifiers
import ImageIO

/// Writes the still half of a Live Photo.
///
/// The pairing lives in the Apple maker-note dictionary: key "17" holds
/// the same content identifier the video carries. Without it the file is
/// just a photo.
class Converter4Image {
    private let assetIdentifierKey = "17"
    private let image: UIImage

    init(image: UIImage) {
        self.image = image
    }

    /// Encodes `image` to HEIC at `destinationPath` with `assetIdentifier`
    /// embedded, returning the URL or nil if anything failed.
    ///
    /// The image is encoded once, straight from its `CGImage`. Going via
    /// `heicData()` and `CGImageDestinationAddImageFromSource` cost three
    /// encodes and two generations of loss on the frame that *is* the
    /// visible wallpaper, and preserved only the metadata of a frame
    /// synthesised moments earlier.
    func write(to destinationPath: String, assetIdentifier: String) -> URL? {
        guard let cgImage = image.cgImage else { return nil }

        let destinationURL = URL(fileURLWithPath: destinationPath)
        guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.heic.identifier as CFString,
                1,
                nil) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: [assetIdentifierKey: assetIdentifier],
            kCGImagePropertyOrientation: cgOrientation(for: image.imageOrientation).rawValue,
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        // Finalize reports whether the file is actually usable; returning
        // a URL to a half-written still would fail later, at the point
        // where the pair is handed to the photo library.
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationURL
    }

    /// `CGImage` carries no orientation, so a `UIImage` that has one has
    /// to record it in the file's metadata instead.
    private func cgOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
