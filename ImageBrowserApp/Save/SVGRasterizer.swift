import UIKit
import SwiftDraw

enum ImageLoadError: Error {
    case decodeFailed
}

enum SVGRasterizer {
    static func rasterize(data: Data, maxPixelSize: CGFloat) throws -> UIImage {
        guard let svg = SwiftDraw.SVG(data: data) else {
            throw ImageLoadError.decodeFailed
        }

        let intrinsic = svg.size
        guard intrinsic.width > 0, intrinsic.height > 0 else {
            throw ImageLoadError.decodeFailed
        }

        let scale = maxPixelSize / max(intrinsic.width, intrinsic.height)
        let targetSize = CGSize(width: intrinsic.width * scale, height: intrinsic.height * scale)

        // scale: 1 so the rendered pixel dimensions equal targetSize exactly
        // (SwiftDraw would otherwise multiply by UIScreen.main.scale).
        return svg.rasterize(with: targetSize, scale: 1)
    }
}
