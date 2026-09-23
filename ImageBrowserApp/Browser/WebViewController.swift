import WebKit
import Combine

/// Owns one WKWebView instance (one per browser tab -- see TabManager). A
/// full browser (unlike ImageSaver's Action Extension) can inject scripts
/// and call evaluateJavaScript at any time, so there is no
/// completionFunction-style one-shot handoff here -- the collector script is
/// injected once as a WKUserScript (function definitions only) and invoked
/// on demand.
@MainActor
final class WebViewController: NSObject, ObservableObject {

    let webView: WKWebView

    @Published private(set) var urlString: String = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress: Double = 0
    @Published private(set) var pageTitle: String = ""
    /// Set when the long-press gesture resolves to an image URL on the page.
    /// BrowserView watches this to present the save menu.
    @Published var longPressedImageURL: URL?
    /// Where the long press landed, in the same coordinate space as
    /// `webView` itself -- lets the save menu anchor near the touch point
    /// the way Safari's own does, instead of a generic bottom sheet.
    @Published private(set) var longPressLocation: CGPoint?

    private var kvoObservations: [NSKeyValueObservation] = []
    private var adBlockRuleList: WKContentRuleList?
    private var adBlockObserver: NSObjectProtocol?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let userContentController = WKUserContentController()
        if let script = WebViewController.loadCollectorScript() {
            userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            )
        }
        // WebKit's own text-selection interaction is a separate gesture
        // path from the context menu (which contextMenuConfigurationForElement
        // already suppresses below) -- on a site that disables its own
        // save affordances, long-pressing an image was instead starting a
        // text/loupe selection, since nothing had told WebKit not to. This
        // disables that native callout/selection specifically on images,
        // leaving our own gesture recognizer as the only thing that reacts.
        userContentController.addUserScript(
            WKUserScript(
                source: WebViewController.disableImageCalloutCSS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        // The built-in long-press preview/menu would otherwise compete with
        // our own gesture recognizer below, and its behavior is subject to
        // whatever the page's own CSS/JS does (-webkit-touch-callout etc.) --
        // exactly the kind of site-side interference this app exists to
        // bypass.
        webView.allowsLinkPreview = false

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeWebView()
        installLongPressRecognizer()
        installAdBlockIfNeeded()
    }

    deinit {
        kvoObservations.forEach { $0.invalidate() }
        if let adBlockObserver {
            NotificationCenter.default.removeObserver(adBlockObserver)
        }
    }

    // MARK: - Navigation

    func load(urlString input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let target: URL
        if let url = URL(string: trimmed), url.scheme != nil {
            target = url
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            target = URL(string: "https://" + trimmed) ?? BrowserDefaults.searchURL(for: trimmed)
        } else {
            target = BrowserDefaults.searchURL(for: trimmed)
        }
        webView.load(URLRequest(url: target))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    // MARK: - Image extraction

    func extractImages(withBackgrounds: Bool = true) async throws -> [PageImage] {
        try await ImageExtractionBridge.collect(in: webView, withBackgrounds: withBackgrounds)
    }

    // MARK: - Setup

    private func observeWebView() {
        kvoObservations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.urlString = webView.url?.absoluteString ?? "" }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.estimatedProgress = webView.estimatedProgress }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.pageTitle = webView.title ?? "" }
            }
        ]
    }

    private func installLongPressRecognizer() {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        recognizer.minimumPressDuration = 0.45
        recognizer.delegate = self
        // Without these three set to false, UIKit's default touch-forwarding
        // rules let this recognizer swallow ordinary taps inside the page --
        // search boxes, buttons, links all stopped responding, because a
        // gesture recognizer added to WKWebView's scrollView competes with
        // WebKit's own internal tap-to-focus recognizer for the same
        // touches. This recognizer must observe without ever intercepting.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        webView.scrollView.addGestureRecognizer(recognizer)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        // WKWebView's point(in:) is already in CSS-pixel-equivalent points at
        // the default (non-zoomed) scale, which is what elementFromPoint
        // expects.
        let point = recognizer.location(in: webView)
        let webView = self.webView
        Task { [weak self] in
            if let url = await ImageExtractionBridge.findImage(in: webView, at: point) {
                AppLog.log("長押しで画像を検出: \(url.absoluteString)")
                self?.longPressLocation = point
                self?.longPressedImageURL = url
            } else {
                AppLog.log("長押し位置に画像なし (\(Int(point.x)), \(Int(point.y)))")
            }
        }
    }

    func dismissLongPressMenu() {
        longPressedImageURL = nil
        longPressLocation = nil
    }

    // MARK: - Ad block

    /// Compiling the rule list is async (WKContentRuleListStore's only API),
    /// so it's applied once the shared compile finishes rather than at
    /// WKWebView construction time. Listening for UserDefaults changes lets
    /// the Settings toggle take effect on already-open tabs immediately,
    /// without each tab needing to be told explicitly.
    private func installAdBlockIfNeeded() {
        Task { [weak self] in
            guard let self, let ruleList = await AdBlockManager.shared.ruleList() else { return }
            self.adBlockRuleList = ruleList
            self.applyAdBlockState()
        }
        adBlockObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyAdBlockState() }
        }
    }

    private func applyAdBlockState() {
        guard let adBlockRuleList else { return }
        let contentController = webView.configuration.userContentController
        contentController.remove(adBlockRuleList)
        if AdBlockStore.isEnabled {
            contentController.add(adBlockRuleList)
        }
    }

    private static func loadCollectorScript() -> String? {
        guard let url = Bundle.main.url(forResource: "ImageCollector", withExtension: "js") else {
            assertionFailure("ImageCollector.js is missing from the app bundle")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static let disableImageCalloutCSS = """
    (function () {
        var style = document.createElement('style');
        style.textContent = 'img, picture, svg {'
            + '-webkit-touch-callout: none !important;'
            + '-webkit-user-select: none !important;'
            + '}';
        (document.head || document.documentElement).appendChild(style);
    })();
    """
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        AppLog.log("読み込み開始: \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        AppLog.log("読み込み完了: \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Cancelled loads (e.g. tapping a link mid-load) surface the same
        // NSURLErrorCancelled every browser silently swallows -- logged
        // anyway since a save failure right after a cancelled load is a
        // plausible correlation to check.
        let nsError = error as NSError
        AppLog.log("読み込み失敗(遷移前): \(webView.url?.absoluteString ?? "?") — \(nsError.domain) \(nsError.code)",
                    isError: nsError.code != NSURLErrorCancelled)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        AppLog.log("読み込み失敗: \(webView.url?.absoluteString ?? "?") — \(nsError.domain) \(nsError.code)", isError: true)
    }
}

extension WebViewController: WKUIDelegate {
    /// Suppresses WebKit's own context menu so a site cannot substitute its
    /// own save-blocking behavior for it; our long-press recognizer is the
    /// only path to the save sheet.
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        completionHandler(nil)
    }

    /// `target="_blank"` links open in the same view -- this app has no tab
    /// model yet.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

extension WebViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

enum BrowserDefaults {
    static func searchURL(for query: String) -> URL {
        SearchEngineStore.current.searchURL(for: query)
    }

    static var homeURL: URL {
        SearchEngineStore.current.homeURL
    }
}
