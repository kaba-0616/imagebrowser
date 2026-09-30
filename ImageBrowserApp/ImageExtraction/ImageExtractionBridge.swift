import WebKit

/// Thin wrapper around evaluateJavaScript for the two entry points
/// ImageCollector.js exposes. No WKScriptMessageHandler is used here --
/// the full browser can call into the page whenever it likes and read the
/// return value directly, unlike the Action Extension original which only
/// ever got one shot via `completionFunction`.
enum ImageExtractionBridge {

    enum ExtractionError: Error {
        case scriptFailed
    }

    /// Scans the current page for every image candidate it can find (DOM,
    /// CSS backgrounds, OGP meta, lazy-load attributes, resize-URL originals).
    static func collect(in webView: WKWebView, withBackgrounds: Bool) async throws -> [PageImage] {
        let script = "JSON.stringify(window.__ImageBrowserCollector.collect(\(withBackgrounds)))"
        let result = try await webView.evaluateJavaScript(script)
        guard let jsonString = result as? String else { throw ExtractionError.scriptFailed }
        return PageImageDecoding.decode(jsonString: jsonString)
    }

    /// Resolves a single image URL at a CSS point (used for long-press).
    /// Also logs the full decision trail (every element examined at that
    /// point, and what each yielded) to AppLog -- image-saving obstructions
    /// vary a lot by site (overlay decoys, swapped src, lazy layers), and
    /// reproducing them locally isn't possible, so this is what real-device
    /// reports get diagnosed from instead of guessing.
    static func findImage(in webView: WKWebView, at point: CGPoint) async -> URL? {
        let script = "JSON.stringify(window.__ImageBrowserCollector.findImageAtDebug(\(point.x), \(point.y)))"
        guard let result = try? await webView.evaluateJavaScript(script) else { return nil }
        guard let jsonString = result as? String else { return nil }
        AppLog.log("長押し判定の詳細: \(jsonString)")
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FindImageDebugResult.self, from: data),
              let urlString = decoded.url else { return nil }
        return URL(string: urlString)
    }

    private struct FindImageDebugResult: Decodable {
        let url: String?
    }

    /// Flutter Web pages (and similar canvas-rendered apps) never put photos
    /// in the DOM at all -- `findImage` above will always come back nil on
    /// them, not because of some save-blocking trick but because there is no
    /// URL to find. WebViewController falls back to a screen-capture crop
    /// when this is true (see `captureCrop`).
    static func isCanvasRenderedPage(in webView: WKWebView) async -> Bool {
        let script = "!!(window.__ImageBrowserCollector && window.__ImageBrowserCollector.isFlutterPage())"
        let result = try? await webView.evaluateJavaScript(script)
        return (result as? Bool) ?? false
    }

    /// The on-screen rect of the widget at `point`, from Flutter's
    /// accessibility DOM overlay (see `findCanvasRegionAt` in
    /// ImageCollector.js) -- lets the snapshot-crop fallback frame tightly
    /// on the actual photo/avatar instead of an arbitrary fixed square.
    static func canvasRegion(in webView: WKWebView, at point: CGPoint) async -> CGRect? {
        let script = "JSON.stringify(window.__ImageBrowserCollector.findCanvasRegionAt(\(point.x), \(point.y)))"
        guard let result = try? await webView.evaluateJavaScript(script),
              let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let rect = try? JSONDecoder().decode(CanvasRegion.self, from: data) else { return nil }
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private struct CanvasRegion: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}
