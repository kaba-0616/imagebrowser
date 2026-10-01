import WebKit
import UIKit
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
    /// A snapshot of the page, refreshed after each load finishes -- used by
    /// TabsView's grid so each cell shows the actual site instead of a
    /// generic placeholder icon.
    @Published private(set) var thumbnail: UIImage?
    /// Set when the long-press gesture resolves to an image URL on the page.
    /// BrowserView watches this to present the save menu.
    @Published var longPressedImageURL: URL?
    /// Where the long press landed, in the same coordinate space as
    /// `webView` itself -- lets the save menu anchor near the touch point
    /// the way Safari's own does, instead of a generic bottom sheet.
    @Published private(set) var longPressLocation: CGPoint?
    /// Set instead of `longPressedImageURL` when no image URL could be found
    /// at all but the page is canvas-rendered (see `handleLongPress`) -- a
    /// cropped screen capture around the touch point, saved as-is since
    /// there's no original file to fetch.
    @Published private(set) var longPressedSnapshotImage: UIImage?
    /// Set by TabManager right after creating this controller. `window.open()`/
    /// `target="_blank"` (see `createWebViewWith` below) calls this instead of
    /// loading in place, so the new page becomes an ordinary tab -- matching
    /// how Safari and other browsers actually handle it. This isn't only a
    /// UI preference: some sites (Google Sign-In's OAuth popup among them)
    /// keep using that window as their real, ongoing surface rather than a
    /// short-lived dialog, so it needs the full tab chrome (address bar,
    /// back/forward, long-press save, ...), not a bare modal sheet.
    var onOpenTab: ((WKWebView) -> Void)?
    /// Set by TabManager. Fires when this tab's own JS calls `window.close()`
    /// (an OAuth popup-turned-tab does this once it's posted its result back
    /// to whichever tab opened it).
    var onRequestClose: (() -> Void)?

    private var kvoObservations: [NSKeyValueObservation] = []
    private var adBlockRuleList: WKContentRuleList?
    private var adBlockObserver: NSObjectProtocol?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // WKWebView's default User-Agent has no trailing "Safari/..." token
        // (only Mobile Safari itself and SFSafariViewController send one).
        // Sites that sniff the UA -- Google's search page among them --
        // treat that as "unsupported browser" and serve a stripped-down,
        // years-old layout instead of the normal one. Appending this via
        // the official API keeps WebKit's own OS/device portion of the UA
        // intact and just adds the token those sites check for; it doesn't
        // need to track the actual Safari version since "Safari/605.1.15"
        // has stayed the same build marker across many iOS releases.
        configuration.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"

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
        super.init()
        commonSetup()
    }

    /// Wraps a WKWebView WebKit already created for a `window.open()`/
    /// `target="_blank"` popup (see `createWebViewWith`). It arrives with the
    /// opener's configuration already attached -- same scripts, ad-block
    /// rules and data store -- since that's what WebKit requires to keep
    /// `window.opener` working, so there's nothing to build here, just the
    /// same delegate/observer wiring any other tab gets.
    init(popupWebView: WKWebView) {
        webView = popupWebView
        super.init()
        commonSetup()
    }

    private func commonSetup() {
        webView.allowsBackForwardNavigationGestures = true
        // The built-in long-press preview/menu would otherwise compete with
        // our own gesture recognizer below, and its behavior is subject to
        // whatever the page's own CSS/JS does (-webkit-touch-callout etc.) --
        // exactly the kind of site-side interference this app exists to
        // bypass.
        webView.allowsLinkPreview = false
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

    /// Canvas-rendered pages' "network" fallback (see ImageCollector.js'
    /// resourceTimingImages) only ever reports what the browser's resource
    /// timing buffer currently holds, which a single extraction call can
    /// easily undershoot: a not-yet-rescrolled-into-view photo hasn't been
    /// fetched again since it's already cached, so it just isn't there this
    /// time. Accumulating across calls, here rather than in the page's own
    /// JS, is what makes repeated extraction behave like "everything found
    /// so far" instead of "only what's visible right now" -- and survives
    /// iOS silently recreating the WKWebView's content process while
    /// backgrounded, which wipes any state kept on the JS side (confirmed on
    /// a real device: results shrank right after a background/foreground
    /// cycle because the page's own bookkeeping had been reset to empty).
    private var seenNetworkImages: [URL: Date] = [:]
    private let networkImageMaxAge: TimeInterval = 3 * 60

    func extractImages(withBackgrounds: Bool = true) async throws -> [PageImage] {
        let rawCountBefore = await ImageExtractionBridge.rawResourceTimingCount(in: webView)
        let fresh = try await ImageExtractionBridge.collect(in: webView, withBackgrounds: withBackgrounds)

        var nonNetwork: [PageImage] = []
        let now = Date()
        let newNetworkCount = fresh.filter { $0.origin == "network" }.count
        for image in fresh where image.origin == "network" {
            seenNetworkImages[image.url] = now
        }
        for image in fresh where image.origin != "network" {
            nonNetwork.append(image)
        }
        seenNetworkImages = seenNetworkImages.filter { now.timeIntervalSince($0.value) <= networkImageMaxAge }
        AppLog.log("一括抽出の内訳: DOM等\(nonNetwork.count)件 / 通信履歴 全エントリ\(rawCountBefore)件中、画像\(newNetworkCount)件・蓄積合計\(seenNetworkImages.count)件")

        let networkImages = seenNetworkImages.keys.map { url in
            // A stable id per URL (not a running counter) so the same photo
            // keeps the same id across repeated extractions -- that's what
            // PhotoSaver.savedImageIDs/the grid's selection state key on, and
            // a counter-based id would reassign on every call depending on
            // dictionary ordering, making "already saved" tracking useless
            // for this fallback path. Offset well clear of the DOM-origin
            // items' 0..<N ids above.
            PageImage(
                // `abs(hashValue)` would trap if hashValue happened to be
                // Int.min; going through UInt sidesteps that.
                id: 1_000_000 + Int(UInt(bitPattern: url.absoluteString.hashValue) % 1_000_000),
                url: url, width: 0, height: 0, renderedURL: nil, origin: "network"
            )
        }
        return nonNetwork + networkImages
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
                return
            }
            // No DOM/CSS image URL at that point. On an ordinary site that
            // just means "nothing there" -- but on a canvas-rendered app
            // (Flutter Web etc.) it's *never* going to find one, since
            // there's no <img>/background-image to find in the first place;
            // everything is painted pixels. There, fall back to cropping a
            // snapshot of what's actually on screen at that point, which at
            // least saves what the user was looking at even without an
            // original file/URL.
            guard await ImageExtractionBridge.isCanvasRenderedPage(in: webView) else {
                AppLog.log("長押し位置に画像なし (\(Int(point.x)), \(Int(point.y)))")
                return
            }
            AppLog.log("長押し位置に画像なし、Canvas描画ページのためスナップショット切り出しにフォールバック (\(Int(point.x)), \(Int(point.y)))")
            guard let self else { return }
            let region = await ImageExtractionBridge.canvasRegion(in: webView, at: point)
            AppLog.log("切り出し範囲: \(region.map { "\($0)" } ?? "取得できず、固定サイズにフォールバック")")
            guard let cropped = await self.captureCrop(around: point, region: region) else {
                AppLog.log("スナップショット切り出しに失敗", isError: true)
                return
            }
            self.longPressLocation = point
            self.longPressedSnapshotImage = cropped
        }
    }

    func dismissLongPressMenu() {
        longPressedImageURL = nil
        longPressedSnapshotImage = nil
        longPressLocation = nil
    }

    /// A last-resort save target when no image URL could be found at all
    /// (see `handleLongPress`). `takeSnapshot` captures WebKit's own
    /// composited output -- the same thing the user's eyes see -- rather
    /// than reading pixels back through the page's own canvas/WebGL context,
    /// which would often throw a cross-origin "tainted canvas" error for
    /// photos loaded from a different domain than the page itself.
    ///
    /// `region`, when available, is the actual on-screen rect of the widget
    /// under the touch (from Flutter's accessibility DOM overlay -- see
    /// `ImageExtractionBridge.canvasRegion`), so a small avatar gets a tight
    /// crop and a large photo gets its whole frame, rather than always the
    /// same fixed square regardless of what was actually pressed. A small
    /// margin is added since that rect is exact and touch points land a few
    /// pixels inside an edge often enough that a literal 1:1 crop feels
    /// clipped.
    private func captureCrop(around point: CGPoint, region: CGRect?, fallbackSide: CGFloat = 320) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        if let region {
            let margin: CGFloat = 12
            config.rect = region.insetBy(dx: -margin, dy: -margin)
        } else {
            let half = fallbackSide / 2
            config.rect = CGRect(x: point.x - half, y: point.y - half, width: fallbackSide, height: fallbackSide)
        }
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    AppLog.log("スナップショット切り出し失敗: \(error.localizedDescription)", isError: true)
                }
                continuation.resume(returning: image)
            }
        }
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

    // MARK: - Thumbnail

    private func captureThumbnail() {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self else { return }
            if let error {
                AppLog.log("タブプレビューの取得失敗: \(error.localizedDescription)", isError: true)
                return
            }
            self.thumbnail = image
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
        captureThumbnail()
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

    /// `window.open()`/`target="_blank"` becomes a new tab (via `onOpenTab`,
    /// wired up by TabManager) rather than loading in the same view or a
    /// disposable modal. Earlier this returned nil and just loaded the URL
    /// in place, which broke Google Sign-In and similar OAuth popups outright
    /// (their result never has anywhere to be posted back to). A modal sheet
    /// fixed the handshake but not the whole picture: several sites,
    /// including that same sign-in flow once it completes, keep using the
    /// opened window as an ordinary page from then on -- exactly what a real
    /// tab (address bar, back/forward, everything else this app has) is for.
    ///
    /// Reusing the `configuration` WebKit hands us here (not building a new
    /// one) is what makes `window.opener` resolve in the new tab -- that
    /// configuration carries the related-web-content-process link back to
    /// this page.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        onOpenTab?(popup)
        return popup
    }

    /// Fires when this tab's own JS calls `window.close()` -- an OAuth
    /// popup-turned-tab does this once it's posted its result back to
    /// whichever tab opened it.
    func webViewDidClose(_ webView: WKWebView) {
        onRequestClose?()
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
