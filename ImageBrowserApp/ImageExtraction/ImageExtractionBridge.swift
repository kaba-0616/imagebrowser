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
    static func findImage(in webView: WKWebView, at point: CGPoint) async -> URL? {
        let script = "window.__ImageBrowserCollector.findImageAt(\(point.x), \(point.y))"
        guard let result = try? await webView.evaluateJavaScript(script) else { return nil }
        guard let urlString = result as? String else { return nil }
        return URL(string: urlString)
    }
}
