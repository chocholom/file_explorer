import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageConverter {
    enum Format: String, CaseIterable {
        case jpg = "JPG"
        case png = "PNG"

        var fileExtension: String {
            switch self {
            case .jpg: return "jpg"
            case .png: return "png"
            }
        }

        var utType: UTType {
            switch self {
            case .jpg: return .jpeg
            case .png: return .png
            }
        }
    }

    /// Formats ImageIO can decode here (HEIC/WebP/AVIF/RAW/…); SVG is vector-only and excluded.
    nonisolated static let convertibleExtensions: Set<String> = [
        "heic", "heif", "webp", "avif", "tiff", "tif", "png", "jpg", "jpeg",
        "bmp", "gif", "psd", "cr2", "cr3", "nef", "arw", "dng", "raw", "ico",
    ]

    nonisolated static func canConvert(_ item: FileItem) -> Bool {
        !item.isDirectory && convertibleExtensions.contains(item.ext)
    }

    /// Converts and writes next to the source with a collision-free name. Returns the new URL.
    nonisolated static func convert(_ url: URL, to format: Format, destination: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        guard
            let sink = CGImageDestinationCreateWithURL(
                destination as CFURL, format.utType.identifier as CFString, 1, nil)
        else {
            throw ConversionError.unwritable(destination.lastPathComponent)
        }
        let options: [CFString: Any] =
            format == .jpg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(sink, image, options as CFDictionary)
        guard CGImageDestinationFinalize(sink) else {
            throw ConversionError.unwritable(destination.lastPathComponent)
        }
        return destination
    }

    enum ConversionError: LocalizedError {
        case unreadable(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Can't read “\(name)” as an image."
            case .unwritable(let name): return "Can't write “\(name)”."
            }
        }
    }
}
