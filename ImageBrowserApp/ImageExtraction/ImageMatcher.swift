import UIKit
import ImageIO

/// Finds which of the page's image files a long-pressed screen region shows,
/// by comparing pixels. Canvas-rendered pages (Flutter Web) have no DOM
/// element to read a URL from, but the files they draw are still known from
/// the network history (see WebViewController.extractImages) -- so a small
/// grayscale fingerprint of the on-screen crop is compared against one of
/// each candidate, and the closest one is the file behind those pixels.
enum ImageMatcher {
    struct Score {
        let image: PageImage
        /// Mean absolute difference of the brightness-normalized fingerprints,
        /// 0 = identical. Same photo at a different size lands well under 0.1.
        let distance: Double
    }

    private static let side = 24

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// Closest first. Candidates that couldn't be downloaded are left out.
    static func rank(snapshot: CGImage, candidates: [PageImage]) async -> [Score] {
        guard snapshot.height > 0 else { return [] }
        let aspect = CGFloat(snapshot.width) / CGFloat(snapshot.height)
        guard let target = fingerprint(snapshot, aspect: aspect) else { return [] }
        return await withTaskGroup(of: Score?.self) { group in
            for candidate in candidates where !candidate.isSVG {
                group.addTask {
                    // The thumbnail is what was actually drawn, and smaller.
                    var image = await loadSmall(candidate.renderedURL ?? candidate.url)
                    if image == nil, candidate.renderedURL != nil {
                        image = await loadSmall(candidate.url)
                    }
                    guard let image, let print = fingerprint(image, aspect: aspect) else { return nil }
                    return Score(image: candidate, distance: distance(target, print))
                }
            }
            var scores: [Score] = []
            for await score in group {
                if let score { scores.append(score) }
            }
            return scores.sorted { $0.distance < $1.distance }
        }
    }

    private static func loadSmall(_ url: URL) async -> CGImage? {
        guard let result = try? await session.data(from: url) else { return nil }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Center-crops to the on-screen region's aspect ratio first (the page
    /// draws photos "cover"-fitted into their frame), then shrinks to a
    /// side x side grayscale grid with the mean subtracted, so a slightly
    /// different brightness/compression still compares as the same photo.
    private static func fingerprint(_ image: CGImage, aspect: CGFloat) -> [Double]? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0, aspect > 0 else { return nil }
        var crop = CGRect(x: 0, y: 0, width: width, height: height)
        if width / height > aspect {
            let newWidth = height * aspect
            crop = CGRect(x: (width - newWidth) / 2, y: 0, width: newWidth, height: height)
        } else {
            let newHeight = width / aspect
            crop = CGRect(x: 0, y: (height - newHeight) / 2, width: width, height: newHeight)
        }
        guard let cropped = image.cropping(to: crop.integral) else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let values = pixels.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { $0 - mean }
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }
}
