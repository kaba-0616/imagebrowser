import Foundation

struct PageImage: Identifiable, Hashable, Codable {
    let id: Int
    let url: URL
    let width: Int
    let height: Int
    /// The URL the page itself displayed, kept only when `url` was rewritten
    /// to ask a resize endpoint for its stored original.
    let renderedURL: URL?
    /// "dom" | "video" | "meta" | "background". Feed into filtering later if needed.
    let origin: String

    var formatLabel: String {
        switch url.pathExtension.lowercased() {
        case "heic", "heif": return "HEIF"
        case "webp": return "WebP"
        case "svg": return "SVG"
        case "gif": return "GIF"
        case "png": return "PNG"
        case "jpg", "jpeg": return "JPEG"
        default: return url.pathExtension.uppercased()
        }
    }

    var isSVG: Bool {
        url.pathExtension.lowercased() == "svg"
    }
}

/// The JS side hands back an array of these; `id` is assigned on the Swift
/// side (array index) since the JS collector has no stable notion of one.
private struct RawImage: Decodable {
    let url: URL
    let width: Double?
    let height: Double?
    let rendered: URL?
    let origin: String?
}

enum PageImageDecoding {
    static func decode(jsonString: String) -> [PageImage] {
        guard let data = jsonString.data(using: .utf8) else { return [] }
        guard let raw = try? JSONDecoder().decode([RawImage].self, from: data) else { return [] }
        return raw.enumerated().map { index, item in
            PageImage(
                id: index,
                url: item.url,
                width: Int(item.width ?? 0),
                height: Int(item.height ?? 0),
                renderedURL: item.rendered,
                origin: item.origin ?? "dom"
            )
        }
    }
}
