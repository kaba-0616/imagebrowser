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
        let centered = values.map { $0 - mean }
        // Contrast-normalized too (to a typical photo's spread of 0.2), so a
        // screen dimmed by the site's own long-press overlay still compares
        // as the same photo. Near-flat images are left as they are.
        let spread = (centered.reduce(0) { $0 + $1 * $1 } / Double(centered.count)).squareRoot()
        guard spread > 0.02 else { return centered }
        return centered.map { $0 * 0.2 / spread }
    }

    /// The on-screen frame of the photo under `point` (both in the image's
    /// pixel coordinates), found from the pixels alone: a box is grown out
    /// from the touch point one line at a time, and a side stops growing
    /// once the line just beyond it is a single flat color -- the light-gray
    /// message bubble around a timeline photo, or the black letterbox of the
    /// full-screen viewer (Sakurazaka46 Message, seen in screenshots). The
    /// page's accessibility tree only ever reported the whole screen, so it
    /// can't be used for this. nil when the result is too small to be a
    /// photo (e.g. the press landed on text or a flat area).
    static func photoRect(in image: CGImage, around point: CGPoint) -> CGRect? {
        let scale = min(1, 300 / CGFloat(image.width))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Flat = every channel varies by at most this much along the line.
        // UI backgrounds are drawn as exact colors; photo content, even a
        // plain wall, has noise and gradients well above this.
        let tolerance = 6
        // "Mostly" one color (85% of the line), not entirely: a small UI
        // element overlapping the background beside a photo -- the floating
        // scroll-down button on Sakurazaka46 Message -- otherwise kept the
        // box growing past the photo's edge (seen on device: a 208pt-wide
        // photo detected as 259pt, and the match failed).
        func isFlat(_ indices: [Int]) -> Bool {
            guard !indices.isEmpty else { return true }
            // Reference color: the line's per-channel median.
            let reference = (0..<3).map { channel -> Int in
                let values = indices.map { Int(pixels[$0 * 4 + channel]) }.sorted()
                return values[values.count / 2]
            }
            let close = indices.filter { index in
                (0..<3).allSatisfy { abs(Int(pixels[index * 4 + $0]) - reference[$0]) <= tolerance }
            }.count
            return Double(close) >= Double(indices.count) * 0.85
        }
        func rowFlat(_ y: Int, _ x0: Int, _ x1: Int) -> Bool { isFlat((x0...x1).map { y * width + $0 }) }
        func columnFlat(_ x: Int, _ y0: Int, _ y1: Int) -> Bool { isFlat((y0...y1).map { $0 * width + x }) }

        let px = min(max(Int(point.x * scale), 0), width - 1)
        let py = min(max(Int(point.y * scale), 0), height - 1)
        // Seeded with a box of a few dozen pixels, not a single point: a
        // short line inside a smooth part of a photo (skin, sky) can easily
        // look flat and would stop the growth right away. If the seed pokes
        // out past the photo's edge, that strip of background is trimmed
        // again later (trimUniformBorders in rank).
        let seed = max(width / 16, 2)
        var left = max(px - seed, 0), right = min(px + seed, width - 1)
        var top = max(py - seed, 0), bottom = min(py + seed, height - 1)
        var grew = true
        while grew {
            grew = false
            if top > 0, !rowFlat(top - 1, left, right) { top -= 1; grew = true }
            if bottom < height - 1, !rowFlat(bottom + 1, left, right) { bottom += 1; grew = true }
            if left > 0, !columnFlat(left - 1, top, bottom) { left -= 1; grew = true }
            if right < width - 1, !columnFlat(right + 1, top, bottom) { right += 1; grew = true }
        }

        // Smaller than a fifth of the screen width either way: text, an
        // icon or a flat patch, not a photo.
        let minimum = width / 5
        guard right - left + 1 >= minimum, bottom - top + 1 >= minimum else { return nil }
        return CGRect(
            x: CGFloat(left) / scale, y: CGFloat(top) / scale,
            width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
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
