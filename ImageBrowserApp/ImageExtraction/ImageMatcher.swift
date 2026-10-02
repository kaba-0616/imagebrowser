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
    ///
    /// Two ways a photo can sit on screen, and both are tried per candidate:
    /// - timeline bubble: the photo is cover-cropped into the bubble, so the
    ///   candidate is cropped to the snapshot's shape;
    /// - full-screen viewer: the whole photo is shown (letterbox bars are
    ///   trimmed off the snapshot first), while the candidate compared is a
    ///   thumbnail that may itself be cropped (e.g. square) -- so the
    ///   snapshot is cropped to the candidate's shape instead.
    static func rank(snapshot rawSnapshot: CGImage, candidates: [PageImage]) async -> [Score] {
        let snapshot = trimUniformBorders(rawSnapshot)
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
                    guard let image, image.height > 0, let print = fingerprint(image, aspect: aspect) else { return nil }
                    var best = distance(target, print)
                    let candidateAspect = CGFloat(image.width) / CGFloat(image.height)
                    if abs(candidateAspect - aspect) / aspect > 0.05,
                       let wholeCandidate = fingerprint(image, aspect: candidateAspect),
                       let snapshotCropped = fingerprint(snapshot, aspect: candidateAspect) {
                        best = min(best, distance(snapshotCropped, wholeCandidate))
                    }
                    return Score(image: candidate, distance: best)
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

    /// Cuts off flat, single-color bands along each edge -- the black/white
    /// letterbox a full-screen viewer puts around a photo whose shape
    /// doesn't match the screen. Measured on a small grayscale copy; a band
    /// counts as flat when its brightness barely varies. Returns the
    /// original when trimming would leave almost nothing (a mostly flat
    /// image, which is better compared as-is).
    static func trimUniformBorders(_ image: CGImage) -> CGImage {
        let scale = min(1, 128 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }

        func isFlat(_ values: [UInt8]) -> Bool {
            guard let low = values.min(), let high = values.max() else { return true }
            return Int(high) - Int(low) <= 12
        }
        func row(_ y: Int) -> [UInt8] { Array(pixels[(y * width)..<((y + 1) * width)]) }
        func column(_ x: Int) -> [UInt8] { (0..<height).map { pixels[$0 * width + x] } }

        // Bitmap rows run top to bottom here (CGContext memory order).
        var top = 0, bottom = height - 1, left = 0, right = width - 1
        while top < bottom, isFlat(row(top)) { top += 1 }
        while bottom > top, isFlat(row(bottom)) { bottom -= 1 }
        while left < right, isFlat(column(left)) { left += 1 }
        while right > left, isFlat(column(right)) { right -= 1 }

        let keptWidth = right - left + 1
        let keptHeight = bottom - top + 1
        guard keptWidth * keptHeight >= width * height / 5,
              keptWidth < width || keptHeight < height else { return image }
        let rect = CGRect(
            x: CGFloat(left) / scale, y: CGFloat(top) / scale,
            width: CGFloat(keptWidth) / scale, height: CGFloat(keptHeight) / scale
        ).integral
        return image.cropping(to: rect) ?? image
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }
}
