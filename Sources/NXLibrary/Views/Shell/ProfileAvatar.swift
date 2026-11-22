import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision
import NXLibraryCore

enum ProfileAvatar {
    struct Crop: Equatable {
        var x: CGFloat = 0.5
        var y: CGFloat = 0.5
        var zoom: CGFloat = 1

        func rectangle(width: Int, height: Int) -> CGRect {
            let side = max(1, floor(CGFloat(min(width, height)) / max(1, min(zoom, 3))))
            return CGRect(x: floor((CGFloat(width) - side) * max(0, min(x, 1))),
                          y: floor((CGFloat(height) - side) * max(0, min(y, 1))), width: side, height: side)
        }
    }

    static func source(_ url: URL) -> CGImageSource? {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (1...24_000_000).contains(values.fileSize ?? 0),
              let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let format = CGImageSourceGetType(image), UTType(format as String)?.conforms(to: .image) == true,
              let size = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = size[kCGImagePropertyPixelWidth] as? Int,
              let height = size[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(width), (1...16_384).contains(height) else { return nil }
        if format == UTType.gif.identifier as CFString,
           (CGImageSourceGetCount(image) > 180 || width * height > 4_194_304) { return nil }
        return image
    }

    static func thumbnail(_ image: CGImageSource, frame: Int = 0, size: Int = 512) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(image, frame, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size
        ] as CFDictionary)
    }

    static func cachedPortrait(_ url: URL) -> Data? {
        guard let source = source(url), let image = thumbnail(source) else { return nil }
        var crop = Crop()
        let faces = VNDetectFaceRectanglesRequest()
        if (try? VNImageRequestHandler(cgImage: image).perform([faces])) != nil,
           let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox {
            let width = CGFloat(image.width), height = CGFloat(image.height)
            crop.zoom = 1.4
            let square = crop.rectangle(width: image.width, height: image.height).width
            crop.x = (face.midX * width - square / 2) / max(1, width - square)
            crop.y = ((1 - face.midY) * height - square / 2) / max(1, height - square)
        }
        return still(image, crop)
    }

    static func still(_ image: CGImage, _ crop: Crop) -> Data? {
        guard let square = image.cropping(to: crop.rectangle(width: image.width, height: image.height)) else { return nil }
        return NSBitmapImageRep(cgImage: square).representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    static func render(_ url: URL, crop: Crop) -> Data? {
        guard let input = source(url) else { return nil }
        let count = CGImageSourceGetCount(input)
        guard count > 1, CGImageSourceGetType(input) == UTType.gif.identifier as CFString else {
            return thumbnail(input).flatMap { still($0, crop) }
        }
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, count, nil) else { return nil }
        if let properties = CGImageSourceCopyProperties(input, nil) as? [CFString: Any],
           let gif = properties[kCGImagePropertyGIFDictionary] {
            CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        }
        for index in 0..<count {
            guard !Task.isCancelled, let frame = thumbnail(input, frame: index, size: 256),
                  let square = frame.cropping(to: crop.rectangle(width: frame.width, height: frame.height)) else { return nil }
            let metadata = CGImageSourceCopyPropertiesAtIndex(input, index, nil) as? [CFString: Any]
            CGImageDestinationAddImage(output, square, metadata?[kCGImagePropertyGIFDictionary].map {
                [kCGImagePropertyGIFDictionary: $0] as CFDictionary
            })
        }
        guard CGImageDestinationFinalize(output), bytes.length <= LocalProfileStore.maximumPortraitBytes else { return nil }
        return bytes as Data
    }

    static func isGIF(_ data: Data) -> Bool { data.starts(with: [0x47, 0x49, 0x46, 0x38]) }
}

struct AnimatedProfilePortrait: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.data != data else { return }
        view.image = NSImage(data: data)
        context.coordinator.data = data
    }

    static func dismantleNSView(_ view: NSImageView, coordinator: Coordinator) { view.animates = false }
}
