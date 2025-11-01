import UIKit
import UniformTypeIdentifiers
import ImageIO

class Converter4Image {
    private let assetIdentifierKey = "17"
    private let image: UIImage

    init(image: UIImage) {
        self.image = image
    }

    func write(to destinationPath: String, assetIdentifier: String) -> URL? {
        let destinationURL = URL(fileURLWithPath: destinationPath)
        guard let dest = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        defer { CGImageDestinationFinalize(dest) }

        guard let imageSource = imageSource(),
              let metadata = metadata(index: 0)?.mutableCopy() as? NSMutableDictionary else {
            return nil
        }

        let makerNote = NSMutableDictionary()
        makerNote.setObject(assetIdentifier, forKey: assetIdentifierKey as NSCopying)
        metadata.setObject(makerNote, forKey: kCGImagePropertyMakerAppleDictionary as NSString)

        CGImageDestinationAddImageFromSource(dest, imageSource, 0, metadata as CFDictionary)
        return destinationURL
    }

    private func metadata(index: Int) -> NSDictionary? {
        return imageSource().flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, index, nil) as NSDictionary?
        }
    }

    private func imageSource() -> CGImageSource? {
        return imageData().flatMap {
            CGImageSourceCreateWithData($0 as CFData, nil)
        }
    }

    private func imageData() -> Data? {
        if #available(iOS 17.0, *) {
            return image.heicData()
        } else {
            return image.jpegData(compressionQuality: 1.0)
        }
    }
}

