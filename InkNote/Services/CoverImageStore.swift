import UIKit
import ImageIO

/// Saves, loads and caches custom cover pictures in Documents/InkNote/covers.
enum CoverImageStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InkNote", isDirectory: true)
            .appendingPathComponent("covers", isDirectory: true)
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    // MARK: Decoding

    /// Decodes with ImageIO at a limited size. This handles HEIC, PNG and JPEG,
    /// applies the camera rotation, and avoids loading a 12 MP photo at full size.
    static func downsampled(data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    static func downsampled(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    // MARK: Saving

    /// Writes the cropped cover, and the original when there is a new one.
    /// Returns the file names to store in `Cover`.
    static func save(cropped: UIImage, original: UIImage?) -> (cover: String, original: String?)? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let coverData = cropped.jpegData(compressionQuality: 0.85) else { return nil }
        let coverName = UUID().uuidString + ".jpg"
        do {
            try coverData.write(to: url(coverName))
        } catch {
            return nil
        }
        var originalName: String?
        if let original = original, let originalData = original.jpegData(compressionQuality: 0.9) {
            let name = UUID().uuidString + "-original.jpg"
            if (try? originalData.write(to: url(name))) != nil {
                originalName = name
            }
        }
        cache.setObject(cropped, forKey: coverName as NSString)
        return (coverName, originalName)
    }

    static func remove(_ name: String?) {
        guard let name = name else { return }
        cache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: url(name))
    }

    // MARK: Loading for display

    static func cached(_ name: String) -> UIImage? {
        cache.object(forKey: name as NSString)
    }

    static func load(_ name: String) async -> UIImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        let fileURL = url(name)
        let image = await Task.detached(priority: .userInitiated) {
            downsampled(url: fileURL, maxPixel: 800)
        }.value
        if let image = image {
            cache.setObject(image, forKey: name as NSString)
        }
        return image
    }
}
