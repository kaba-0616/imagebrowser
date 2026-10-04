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
    /// Started alongside `longPressedSnapshotImage`: looks for the actual
    /// image file behind the snapshot (see `findOriginal`), so saving can
    /// store the original instead of a screen crop. Kept past
    /// `dismissLongPressMenu` -- the save button reads it, then dismisses.
    private(set) var longPressOriginalLookup: Task<LongPressLookup, Never>?
    /// See `gestureRecognizer(_:shouldReceive:)`.
    fileprivate var touchDownScreen: (image: UIImage, at: Date)?
    /// Hosts seen to be canvas-rendered (Flutter Web), shared by all tabs.
    /// Remembered across launches: the first long press on a page is
    /// otherwise the only moment a host gets recognized, so that press could
    /// never use the touch-down snapshot (seen on device: the first press
    /// matched nothing, every later one matched).
    fileprivate static var canvasHosts: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "canvasHosts") ?? []) {
        didSet { UserDefaults.standard.set(Array(canvasHosts), forKey: "canvasHosts") }
    }
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
        // Diagnostic network tap (see NetworkTap.js): has to run before any
        // page script, so it can wrap fetch/XMLHttpRequest before the page
        // starts using them.
        if let tap = WebViewController.loadBundledScript(named: "NetworkTap") {
            userContentController.addUserScript(
                WKUserScript(source: tap, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // Registered only here, not in commonSetup(): popup tabs share this
        // userContentController, and registering the same name twice
        // raises an Objective-C exception. Goes through a weak proxy since
        // WKUserContentController retains its handlers strongly, which
        // would otherwise keep this controller (and its WKWebView) alive
        // forever after the tab is closed.
        userContentController.add(WeakScriptMessageHandler(target: self), name: "imageBrowserNet")
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

    /// Which controller owns which WKWebView. A popup-turned-tab shares its
    /// opener's WKUserContentController -- and with it the single
    /// "imageBrowserNet" handler, which points at the *opener's* controller.
    /// Without this lookup, a popup tab's NetworkTap reports (API origin,
    /// cached URLs, refresh results) all landed on the opener, so the popup
    /// tab's own refresh always timed out.
    private static let owners = NSMapTable<WKWebView, WebViewController>.weakToWeakObjects()

    private func commonSetup() {
        Self.owners.setObject(self, forKey: webView)
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
    ///
    /// No time-based expiry: the timeline loads all its thumbnails once at
    /// page open and scrolling fetches nothing new (confirmed on device --
    /// zero resource-timing entries after scrolling), so an age limit would
    /// just make every photo silently expire a few minutes in. Instead the
    /// history is reset whenever the page URL changes (see `observeWebView`),
    /// which is what actually marks "a different screen" for these sites.
    private var seenNetworkImages: [URL: Date] = [:]

    /// Clears the page's own resource-timing buffer unconditionally, even
    /// when nothing has been accumulated yet: an earlier version skipped the
    /// whole reset when `seenNetworkImages` was empty, so navigating
    /// timeline -> member list -> timeline without extracting in between left
    /// the member list's thumbnails in the buffer, and the next extraction
    /// on the timeline picked them up (seen on device).
    private func resetNetworkImageHistory(to newURL: String) {
        let path = URL(string: newURL).map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? newURL
        AppLog.debug("ページURL変更: \(path) (蓄積\(seenNetworkImages.count)件をリセット)")
        seenNetworkImages.removeAll()
        webView.evaluateJavaScript("performance.clearResourceTimings()", completionHandler: nil)
        requestStorageScan()
        prefetchTimelineIfNeeded()
    }

    func extractImages(withBackgrounds: Bool = true) async throws -> [PageImage] {
        // Both read the buffer *before* collect()'s resourceTimingImages()
        // clears it -- same timing constraint, so they have to happen first.
        // Refreshes `idbFullSizeByKey` for the *next* extraction too; results
        // arrive asynchronously, so this one uses what the page-load/URL-
        // change scan already collected.
        requestStorageScan()
        // Only needed for the verbose breakdown line -- skip the two extra
        // JS round trips otherwise.
        let verbose = DiagnosticsStore.isVerbose
        let rawCountBefore = verbose ? await ImageExtractionBridge.rawResourceTimingCount(in: webView) : 0
        let breakdown = verbose ? await ImageExtractionBridge.resourceTimingBreakdown(in: webView) : [:]
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

        // Full-size URLs the site's own app has cached in IndexedDB (see
        // `idbFullSizeByKey`). Signed URLs past their `Expires` would just
        // 403, so those aren't used.
        let cachedFiles = Array(idbFullSizeByKey.values)
        let validCached = cachedFiles.filter { !Self.isExpired($0, at: now) }
        var cachedByKey: [String: URL] = [:]
        for url in validCached { cachedByKey[Self.fullSizeKey(url)] = url }

        var baseCandidates = Self.dropThumbnailsWithFullSize(Self.latestPerPath(seenNetworkImages))

        // Freshly signed URLs per message, straight from the site's API.
        var freshFullByKey: [String: URL] = [:]
        var freshThumbByKey: [String: URL] = [:]
        var videoMessageIDs: Set<String> = []
        var refreshedIDs: Set<String> = []
        let messageIDs = Array(Set(baseCandidates.compactMap(Self.messageID)))
        if let origin = messageAPIOrigin, !messageIDs.isEmpty {
            let refreshed = await refreshMessageImages(ids: messageIDs, origin: origin)
            refreshedIDs = Set(refreshed.keys)
            videoMessageIDs = Set(refreshed.filter { $0.value.isVideo }.keys)
            let typeCounts = Dictionary(grouping: refreshed.values, by: { "\($0.type.isEmpty ? "不明" : $0.type)(\($0.fileExtension.isEmpty ? "-" : $0.fileExtension))" })
                .map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ", ")
            AppLog.debug("メッセージの種類内訳: \(typeCounts)")
            for url in refreshed.values.filter({ !$0.isVideo }).flatMap(\.images) {
                if url.path.contains("/files/") {
                    freshFullByKey[Self.fullSizeKey(url)] = url
                } else if url.path.contains("/thumbnails/") {
                    freshThumbByKey[Self.fullSizeKey(url)] = url
                }
            }
            AppLog.log("メッセージAPIで最新URLを再取得: 依頼\(messageIDs.count)件・フルサイズ取得\(freshFullByKey.count)件・縮小版取得\(freshThumbByKey.count)件")
        } else if !messageIDs.isEmpty {
            AppLog.debug("メッセージAPIの送信先が未確認のため最新URLの再取得をスキップ(\(messageIDs.count)件)")
        }

        // Video messages' images are just poster frames. The API's type is
        // authoritative; the filename pattern only covers messages the API
        // wasn't asked about.
        let beforeVideoFilter = baseCandidates.count
        baseCandidates.removeAll { url in
            if let id = Self.messageID(of: url), refreshedIDs.contains(id) {
                return videoMessageIDs.contains(id)
            }
            return Self.looksLikeVideoPoster(url)
        }
        if beforeVideoFilter != baseCandidates.count {
            AppLog.log("動画のサムネイルを除外: \(beforeVideoFilter - baseCandidates.count)件")
        }

        var upgradedFromAPI = 0
        var upgradedFromCache = 0
        var refreshedCount = 0
        let candidates: [(url: URL, rendered: URL?)] = baseCandidates
            .map { url in
                let key = Self.fullSizeKey(url)
                if let fresh = freshFullByKey[key] {
                    refreshedCount += 1
                    return (fresh, freshThumbByKey[key])
                }
                if let freshThumb = freshThumbByKey[key], url.path.contains("/thumbnails/") {
                    refreshedCount += 1
                    return (freshThumb, nil)
                }
                guard url.path.contains("/thumbnails/") else { return (url, nil) }
                if let fullSize = apiFullSizeByKey[key], !Self.isExpired(fullSize, at: now) {
                    upgradedFromAPI += 1
                    return (fullSize, url)
                }
                if let fullSize = cachedByKey[key] {
                    upgradedFromCache += 1
                    return (fullSize, url)
                }
                return (url, nil)
            }

        let breakdownText = breakdown.sorted { $0.value > $1.value }
            .map { "\($0.key):\($0.value)" }.joined(separator: ", ")
        AppLog.debug("一括抽出の内訳: DOM等\(nonNetwork.count)件 / 通信履歴 全エントリ\(rawCountBefore)件中、画像\(newNetworkCount)件・蓄積合計\(seenNetworkImages.count)件・重複除外後\(candidates.count)件 / 最新URLに差し替え\(refreshedCount)件 / フルサイズに置換: API応答から\(upgradedFromAPI)件・端末内キャッシュから\(upgradedFromCache)件 / 拡張子内訳: \(breakdownText)")
        AppLog.debug("端末内キャッシュのフルサイズURL: \(cachedFiles.count)件(期限内\(validCached.count)件・期限切れ\(cachedFiles.count - validCached.count)件)")
        AppLog.debug("抽出対象の画像URL一覧: \(candidates.map { Self.shortPath($0.url) }.joined(separator: ", "))")

        let networkImages = candidates.map { candidate -> PageImage in
            let url = candidate.url
            // A stable id per URL (not a running counter) so the same photo
            // keeps the same id across repeated extractions -- that's what
            // PhotoSaver.savedImageIDs/the grid's selection state key on, and
            // a counter-based id would reassign on every call depending on
            // dictionary ordering, making "already saved" tracking useless
            // for this fallback path. Offset well clear of the DOM-origin
            // items' 0..<N ids above.
            return PageImage(
                // `abs(hashValue)` would trap if hashValue happened to be
                // Int.min; going through UInt sidesteps that.
                id: 1_000_000 + Int(UInt(bitPattern: url.absoluteString.hashValue) % 1_000_000),
                // The thumbnail actually shown on screen stays as
                // renderedURL: ImageLoader uses it for the grid preview, and
                // PhotoSaver falls back to it if the full-size fetch fails.
                url: url, width: 0, height: 0, renderedURL: candidate.rendered, origin: "network"
            )
        }
        return nonNetwork + networkImages
    }

    /// Full-size (`/files/`) URLs found in the site's own IndexedDB cache,
    /// keyed like `fullSizeKey`. Sakurazaka46 Message keeps past messages in
    /// a SQLite database stored in IndexedDB and its timeline API only
    /// returns new ones, so for older photos this cache is the only place a
    /// full-size URL exists. Filled from NetworkTap.js' storage scan, which
    /// runs on page load, URL change and extraction -- an earlier attempt
    /// to read it synchronously during extraction via callAsyncJavaScript
    /// silently came back empty while the very same scan saw 86 URLs.
    private var idbFullSizeByKey: [String: URL] = [:]

    /// Origin of the site's message API (e.g. `https://api.message.sakurazaka46.com`),
    /// learned from NetworkTap reports. Set only for hosts starting with
    /// `api.message.` serving `/v2/...` -- the only API shape the refresh
    /// below knows how to call.
    private var messageAPIOrigin: String?
    private var pendingRefresh: [String: CheckedContinuation<[String: RefreshedMessage], Never>] = [:]
    private var pendingTimeline: [String: CheckedContinuation<[TimelineMessage], Never>] = [:]
    /// Per talk group, so repeated long presses don't re-walk the whole
    /// timeline. Kept 10 minutes -- the signed URLs inside expire.
    private var timelineCache: [String: (at: Date, messages: [TimelineMessage])] = [:]

    struct TimelineMessage {
        let id: String
        let type: String
        let file: URL?
        let thumbnail: URL?
        /// The thumbnail's pixel size, when the API reports it.
        let width: Int
        let height: Int

        var isVideo: Bool {
            let lower = type.lowercased()
            let ext = file?.pathExtension.lowercased() ?? ""
            return lower.contains("video") || lower.contains("movie")
                || ["mp4", "mov", "m4v", "m3u8", "webm"].contains(ext)
        }

        /// A photo message. Not just "not a video": voice messages carry an
        /// .m4a file too, and those showed up in the grid as undecodable
        /// (seen on device).
        var isPhoto: Bool {
            guard !isVideo else { return false }
            let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "jfif"]
            if let file { return imageExtensions.contains(file.pathExtension.lowercased()) }
            return thumbnail.map { imageExtensions.contains($0.pathExtension.lowercased()) } ?? false
        }
    }

    /// The whole timeline of one talk group, walked from the start via the
    /// site's own timeline API (see NetworkTap.js).
    private func fetchTimeline(groupID: String, origin: String) async -> [TimelineMessage] {
        if let cached = timelineCache[groupID], Date().timeIntervalSince(cached.at) < 600 {
            return cached.messages
        }
        let requestID = UUID().uuidString
        let messages: [TimelineMessage] = await withCheckedContinuation { continuation in
            pendingTimeline[requestID] = continuation
            let script = "window.__ImageBrowserFetchTimeline && window.__ImageBrowserFetchTimeline('\(requestID)', '\(origin)', '\(groupID)'); true"
            webView.evaluateJavaScript(script, completionHandler: nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if let pending = self?.pendingTimeline.removeValue(forKey: requestID) {
                    AppLog.log("タイムラインAPIの取得がタイムアウト(20秒)", isError: true)
                    pending.resume(returning: [])
                }
            }
        }
        // Later pages overlap the previous one at the boundary.
        var seen = Set<String>()
        let unique = messages.filter { seen.insert($0.id).inserted }
        if !unique.isEmpty { timelineCache[groupID] = (Date(), unique) }
        return unique
    }

    /// Whether "さかのぼり抽出" can run here: a talk timeline whose API
    /// origin is known (the name is deliberately site-neutral).
    var canLoadHistory: Bool {
        messageAPIOrigin != nil && currentTalkGroupID != nil
    }

    /// Every photo in the open talk, oldest first -- not just what has been
    /// scrolled into view. Pro only (enforced by the caller).
    func historyImages() async -> [PageImage] {
        guard let origin = messageAPIOrigin, let groupID = currentTalkGroupID else { return [] }
        let started = Date()
        var messages = await fetchTimeline(groupID: groupID, origin: origin)
        // Cached for up to 10 minutes; signed URLs that ran out in the
        // meantime would just 403 on save, so fetch once more.
        if messages.contains(where: { $0.file.map { Self.isExpired($0, at: Date()) } ?? false }) {
            timelineCache[groupID] = nil
            messages = await fetchTimeline(groupID: groupID, origin: origin)
        }
        let photos = messages.filter(\.isPhoto)
            .sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        AppLog.log("さかのぼり抽出: トーク\(groupID)のメッセージ\(messages.count)件中、写真\(photos.count)件 \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return photos.compactMap { message in
            guard let main = message.file ?? message.thumbnail else { return nil }
            return Self.candidate(main, rendered: message.file == nil ? nil : message.thumbnail)
        }
    }

    private var timelinePrefetching: Set<String> = []

    /// Opening a talk walks its whole timeline in the background, so the
    /// first long press doesn't wait for it (seen on device: 5-9 seconds
    /// for 15 pages, versus 0.5s once cached).
    private func prefetchTimelineIfNeeded() {
        guard let origin = messageAPIOrigin, let groupID = currentTalkGroupID,
              !timelinePrefetching.contains(groupID) else { return }
        if let cached = timelineCache[groupID], Date().timeIntervalSince(cached.at) < 600 { return }
        timelinePrefetching.insert(groupID)
        Task { [weak self] in
            _ = await self?.fetchTimeline(groupID: groupID, origin: origin)
            self?.timelinePrefetching.remove(groupID)
        }
    }

    /// Flutter builds its view after the document itself has loaded, so
    /// this checks a little later.
    private func detectCanvasPageLater() {
        Task { [weak self] in
            for delay in [2, 5] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self, let host = self.webView.url?.host else { return }
                if Self.canvasHosts.contains(host) { return }
                if await ImageExtractionBridge.isCanvasRenderedPage(in: self.webView) {
                    Self.canvasHosts.insert(host)
                    return
                }
            }
        }
    }

    /// `/organization/1/talk/timeline/58` -> `58`.
    private var currentTalkGroupID: String? {
        guard let path = webView.url?.path,
              let range = path.range(of: #"/timeline/(\d+)"#, options: .regularExpression) else { return nil }
        return path[range].split(separator: "/").last.map(String.init)
    }

    struct RefreshedMessage {
        let images: [URL]
        /// The API's own message type (e.g. "picture", "video", "text").
        let type: String
        /// Extension of the message's main `file` (e.g. "jpg", "mp4").
        let fileExtension: String

        /// A video message's images are only its poster frame, not a photo.
        var isVideo: Bool {
            type.lowercased().contains("video") || type.lowercased().contains("movie")
                || ["mp4", "mov", "m4v", "m3u8", "webm"].contains(fileExtension)
        }
    }

    /// Fallback for video posters when the API couldn't be asked: the site
    /// names a video's extracted poster frame `<name>.0000000.jpg`.
    private static func looksLikeVideoPoster(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: #"\.\d{7}\.(jpe?g|png)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The site's app caches signed image URLs for days; past their
    /// `Expires` CloudFront answers 403 -- for this app, even though the page
    /// still shows them from the browser cache (seen on device: every
    /// thumbnail and full-size in the grid failed with 403). Asks the site's
    /// own `/v2/messages/<id>` endpoint, with the page's own auth headers,
    /// for freshly signed URLs. Returns message ID -> image URLs.
    private func refreshMessageImages(ids: [String], origin: String) async -> [String: RefreshedMessage] {
        let requestID = UUID().uuidString
        guard let idsData = try? JSONSerialization.data(withJSONObject: ids),
              let idsJSON = String(data: idsData, encoding: .utf8) else { return [:] }
        return await withCheckedContinuation { continuation in
            pendingRefresh[requestID] = continuation
            let script = "window.__ImageBrowserRefreshMessageImages && window.__ImageBrowserRefreshMessageImages('\(requestID)', '\(origin)', \(idsJSON)); true"
            webView.evaluateJavaScript(script, completionHandler: nil)
            // 4 requests at a time: allow ~0.5s per round on top of 10s.
            let seconds = 10 + UInt64(ids.count / 4) / 2
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if let pending = self?.pendingRefresh.removeValue(forKey: requestID) {
                    AppLog.log("メッセージAPIでの最新URL再取得がタイムアウト(\(seconds)秒)", isError: true)
                    pending.resume(returning: [:])
                }
            }
        }
    }

    /// Leading number of a `/messages/` filename (`370571-20260919-....jpg`
    /// -> `370571`), which is the message ID the API takes.
    private static func messageID(of url: URL) -> String? {
        guard url.path.contains("/messages/"),
              let first = url.lastPathComponent.split(separator: "-").first,
              first.allSatisfy(\.isNumber) else { return nil }
        return String(first)
    }

    private func requestStorageScan() {
        webView.evaluateJavaScript("window.__ImageBrowserStorageReport && window.__ImageBrowserStorageReport(); true", completionHandler: nil)
    }

    /// CloudFront signed URLs carry an `Expires` epoch-seconds parameter;
    /// past it the CDN answers 403. URLs without one are treated as valid.
    private static func isExpired(_ url: URL, at now: Date) -> Bool {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "Expires" })?.value,
              let expires = TimeInterval(value) else { return false }
        // A minute of margin so a URL doesn't expire between listing and saving.
        return expires < now.timeIntervalSince1970 + 60
    }

    /// Signed CDN URLs (CloudFront's Expires/Signature query) come back with
    /// a different query string each time the page re-requests the same
    /// file, so the URL alone would count one photo several times. Keeps
    /// only the most recently seen URL per path.
    private static func latestPerPath(_ seen: [URL: Date]) -> [URL] {
        var newest: [String: (url: URL, at: Date)] = [:]
        for (url, at) in seen {
            if let kept = newest[url.path], kept.at >= at { continue }
            newest[url.path] = (url, at)
        }
        // Dictionary order is random per run, which scrambled the grid.
        // Message photos go oldest first by message number (the same
        // top-to-bottom order as the talk screen); anything else follows in
        // the order it was seen.
        return newest.values.sorted { a, b in
            let idA = messageID(of: a.url).flatMap { Int($0) } ?? Int.max
            let idB = messageID(of: b.url).flatMap { Int($0) } ?? Int.max
            if idA != idB { return idA < idB }
            if a.at != b.at { return a.at < b.at }
            return a.url.absoluteString < b.url.absoluteString
        }.map(\.url)
    }

    /// The timeline list only ever loads `/thumbnails/` versions; the
    /// `/files/` full-size version is fetched only once a photo is opened.
    /// So a thumbnail is dropped only when its full-size sibling has also
    /// been seen. The two filenames differ in their trailing timestamp
    /// (e.g. `371193-20260926-090559.jpg` vs `...-090600.jpg`), so they're
    /// matched on the leading message number instead of the whole name.
    private static func dropThumbnailsWithFullSize(_ urls: [URL]) -> [URL] {
        let fullSizeKeys = Set(urls.filter { $0.path.contains("/files/") }.map(fullSizeKey))
        return urls.filter { url in
            guard url.path.contains("/thumbnails/") else { return true }
            return !fullSizeKeys.contains(fullSizeKey(url))
        }
    }

    /// Same key for a `/thumbnails/` URL and its `/files/` sibling: host +
    /// directory (with thumbnails mapped to files) + leading number of the
    /// filename. See `dropThumbnailsWithFullSize` for why only the leading
    /// number is used.
    private static func fullSizeKey(_ url: URL) -> String {
        let dir = url.deletingLastPathComponent().path
            .replacingOccurrences(of: "/thumbnails", with: "/files")
        let messageID = url.lastPathComponent.split(separator: "-").first.map(String.init)
            ?? url.lastPathComponent
        return "\(url.host ?? "")\(dir)/\(messageID)"
    }

    /// Last three path components, e.g. `messages/thumbnails/370571-....jpg`
    /// -- enough to tell message photos from member icons etc. in the log
    /// without dumping whole signed URLs.
    static func shortPath(_ url: URL) -> String {
        url.pathComponents.suffix(3).joined(separator: "/")
    }

    /// Full-size (`/files/`) URLs seen inside the site's own API responses
    /// (via NetworkTap.js), keyed like `fullSizeKey`. The timeline only
    /// fetches thumbnails, but its API responses (`/v2/groups/<id>/timeline`,
    /// `/v2/messages/<id>`) already carry signed full-size URLs -- so a
    /// thumbnail actually shown on screen can be swapped for its full-size
    /// version without the user opening each photo. Only used as a lookup
    /// for thumbnails already being extracted: API responses also list
    /// images never displayed (news banners etc.), which shouldn't be added.
    /// Not reset on URL change -- it's a lookup table, not a list of what's
    /// on screen.
    private var apiFullSizeByKey: [String: URL] = [:]

    fileprivate func rememberAPIFullSize(_ urls: [URL]) {
        for url in urls where url.path.contains("/files/") {
            apiFullSizeByKey[Self.fullSizeKey(url)] = url
        }
        if apiFullSizeByKey.count > 5000 {
            apiFullSizeByKey.removeAll()
        }
    }

    // MARK: - Setup

    private func observeWebView() {
        kvoObservations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let newURL = webView.url?.absoluteString ?? ""
                    if newURL != self.urlString { self.resetNetworkImageHistory(to: newURL) }
                    self.urlString = newURL
                }
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
            if let host = webView.url?.host { Self.canvasHosts.insert(host) }
            // Taken at touch-down when this host was already known to be a
            // canvas page (see shouldReceive touch); otherwise right now,
            // which may already include the site's own long-press overlay.
            let early = self.touchDownScreen.flatMap { Date().timeIntervalSince($0.at) < 3 ? $0.image : nil }
            self.touchDownScreen = nil
            var screen = early
            if screen == nil {
                screen = await self.captureCrop(around: point, region: self.webView.bounds, margin: 0)
            }
            // Every press on a canvas page lands here, photo or not -- so
            // only offer the menu when the pixels show a photo frame at that
            // point (pressing empty space or text used to bring it up too).
            if let screen, !Self.hasPhotoFrame(in: screen, at: point) {
                AppLog.log("長押し位置に写真の枠がないためメニューを出さない (\(Int(point.x)), \(Int(point.y)))")
                return
            }
            // Outside a talk timeline (e.g. the talk list) there's nothing
            // to find an original among, so a "photo" there -- usually a
            // member icon -- could only end in the not-found notice.
            if self.currentTalkGroupID == nil {
                let seen = (try? await webView.evaluateJavaScript(
                    "window.__ImageBrowserSeenImages ? window.__ImageBrowserSeenImages().length : 0")) as? Int ?? 0
                if seen == 0 {
                    AppLog.log("長押し: 照合できる画像がないページのためメニューを出さない (\(Int(point.x)), \(Int(point.y)))")
                    return
                }
            }
            let region = await ImageExtractionBridge.canvasRegion(in: webView, at: point)
            AppLog.debug("切り出し範囲: \(region.map { "\($0)" } ?? "取得できず、固定サイズにフォールバック")")
            guard let cropped = await self.captureCrop(around: point, region: region) else {
                AppLog.log("スナップショット切り出しに失敗", isError: true)
                return
            }
            // The whole visible page, unmargined: the photo's frame is found
            // from the pixels themselves (see ImageMatcher.photoRect). The
            // accessibility region above turned out to be the entire screen
            // on Sakurazaka46 Message (both in the timeline and the viewer).
            AppLog.log("長押し画像の照合: 画面の撮影 \(early != nil ? "指が触れた時点" : "長押し判定後(サイトのメニューが写り込む可能性あり)")")
            if let screen {
                self.longPressOriginalLookup = Task { [weak self] in
                    await self?.findOriginal(onScreen: screen, at: point) ?? LongPressLookup()
                }
            } else {
                AppLog.log("長押し画像の照合: 画面全体のスナップショットを取れず照合せず切り出しで保存", isError: true)
                self.longPressOriginalLookup = nil
            }
            self.longPressLocation = point
            self.longPressedSnapshotImage = cropped
        }
    }

    /// The page's image file that a long-pressed canvas region shows, found
    /// by pixel comparison against everything the page has loaded (see
    /// ImageMatcher). nil when nothing is clearly the same picture -- the
    /// caller then saves the screen crop as before.
    struct LongPressLookup {
        /// The page's original file for the pressed photo, when found.
        var original: PageImage?
        /// Just the photo's own pixels on screen -- a far better fallback
        /// than the whole-screen crop when no original matched.
        var photoCrop: UIImage?
        /// The detected frame runs into the top or bottom of the page view
        /// -- most likely a photo scrolled partly out of sight, which is
        /// matched far less reliably (seen on device).
        var nearScreenEdge = false
    }

    /// Second attempt when the first found nothing (user request: try once
    /// more before reporting failure). The screen is captured again -- the
    /// first one may have caught the site's own long-press overlay -- and
    /// every photo in the talk is compared, without the shape filter or cap.
    func retryOriginalLookup(at point: CGPoint) async -> LongPressLookup {
        AppLog.log("長押し画像の照合: 再試行(画面を撮り直し、候補をトークの写真全件に広げる)")
        guard let screen = await captureCrop(around: point, region: webView.bounds, margin: 0) else {
            AppLog.log("長押し画像の照合: 再試行用の画面を撮れず中止", isError: true)
            return LongPressLookup()
        }
        return await findOriginal(onScreen: screen, at: point, thorough: true)
    }

    private static func hasPhotoFrame(in screen: UIImage, at point: CGPoint) -> Bool {
        guard let cgImage = bitmap(of: screen), screen.size.width > 0 else { return true }
        let pixelsPerPoint = CGFloat(cgImage.width) / screen.size.width
        let pixelPoint = CGPoint(x: point.x * pixelsPerPoint, y: point.y * pixelsPerPoint)
        return ImageMatcher.photoRect(in: cgImage, around: pixelPoint) != nil
    }

    private func findOriginal(onScreen screen: UIImage, at point: CGPoint, thorough: Bool = false) async -> LongPressLookup {
        let started = Date()
        // Always redrawn into a plain bitmap: takeSnapshot's UIImage isn't
        // guaranteed to be CGImage-backed, and `.cgImage` on it came back nil
        // on device -- the lookup then ended silently and every save fell
        // back to the crop with no log line at all.
        guard let cgImage = Self.bitmap(of: screen), screen.size.width > 0 else {
            AppLog.log("長押し画像の照合: 画面を画像データに変換できず中止", isError: true)
            return LongPressLookup()
        }
        let pixelsPerPoint = CGFloat(cgImage.width) / screen.size.width
        let pixelPoint = CGPoint(x: point.x * pixelsPerPoint, y: point.y * pixelsPerPoint)
        guard let rect = ImageMatcher.photoRect(in: cgImage, around: pixelPoint),
              let photo = cgImage.cropping(to: rect) else {
            AppLog.log("長押し画像の照合: 長押し位置の写真の枠を見つけられず切り出しで保存 (\(Int(point.x)), \(Int(point.y)))")
            // Too little of the photo showing to count as one -- usually a
            // photo mostly scrolled out under the header or off the bottom.
            var lookup = LongPressLookup()
            lookup.nearScreenEdge = point.y < screen.size.height * 0.15 || point.y > screen.size.height * 0.85
            return lookup
        }
        let rectInPoints = "x\(Int(rect.minX / pixelsPerPoint)) y\(Int(rect.minY / pixelsPerPoint)) \(Int(rect.width / pixelsPerPoint))x\(Int(rect.height / pixelsPerPoint))pt"
        AppLog.log("長押し画像の照合: 写真の枠 \(rectInPoints)")
        var result = LongPressLookup(original: nil, photoCrop: UIImage(cgImage: photo))
        let height = CGFloat(cgImage.height)
        result.nearScreenEdge = rect.minY < height * 0.1 || rect.maxY > height * 0.95

        let trimmed = ImageMatcher.trimUniformBorders(photo)
        let aspect = CGFloat(trimmed.width) / CGFloat(max(trimmed.height, 1))
        var candidates = await timelineCandidates(photoAspect: aspect, thorough: thorough) ?? []
        if candidates.isEmpty {
            candidates = await longPressCandidates()
        }
        let ranked = await ImageMatcher.rank(snapshot: photo, candidates: candidates)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let top = ranked.prefix(3)
            .map { "\(Self.shortPath($0.image.url))=\(String(format: "%.3f", $0.distance))" }
            .joined(separator: ", ")
        AppLog.log("長押し画像の照合: 候補\(candidates.count)件・比較できた\(ranked.count)件 \(elapsed)ms 上位: \(top.isEmpty ? "なし" : top)")

        guard let best = ranked.first, best.distance < Self.matchThreshold else {
            AppLog.log("長押し画像の照合: 一致する画像なし、写真の枠の切り出しで保存")
            return result
        }
        // Two near-identical candidates (e.g. the same photo posted twice
        // with different crops) can't be told apart reliably.
        if ranked.count > 1, ranked[1].distance < best.distance * 1.3, ranked[1].distance < Self.matchThreshold,
           Self.fullSizeKey(ranked[1].image.url) != Self.fullSizeKey(best.image.url) {
            AppLog.log("長押し画像の照合: 候補が拮抗しているため写真の枠の切り出しで保存")
            return result
        }
        result.original = best.image
        return result
    }

    /// Mean grayscale difference below which two fingerprints count as the
    /// same picture (see ImageMatcher.Score.distance).
    private static let matchThreshold = 0.1

    /// Photo messages of the talk being viewed, from the site's timeline API.
    /// Narrowed by shape when the API reports thumbnail sizes: the photo is
    /// shown whole both in the timeline and in the viewer, so its on-screen
    /// aspect ratio matches its thumbnail's. nil when this isn't a message
    /// site's talk page.
    private func timelineCandidates(photoAspect: CGFloat, thorough: Bool = false) async -> [PageImage]? {
        guard let origin = messageAPIOrigin, let groupID = currentTalkGroupID else { return nil }
        let messages = await fetchTimeline(groupID: groupID, origin: origin)
        let media = messages.filter(\.isPhoto)
        let withShape = media.filter { $0.width > 0 && $0.height > 0 }
        let sameShape = withShape.filter {
            abs(CGFloat($0.width) / CGFloat($0.height) - photoAspect) / photoAspect < 0.06
        }
        // Newest first (the API returns oldest first), capped so a member
        // with years of photos doesn't mean hundreds of downloads.
        let pool = thorough
            ? Array(media.reversed())
            : Array((sameShape.isEmpty ? media : sameShape).reversed().prefix(300))
        AppLog.log("長押し画像の照合: トーク\(groupID)のメッセージ\(messages.count)件中、写真\(media.count)件(サイズ情報あり\(withShape.count)件・縦横比が一致\(sameShape.count)件、画面上の縦横比\(String(format: "%.3f", photoAspect))) → 候補\(pool.count)件")
        if !pool.isEmpty {
            return pool.compactMap { message in
                guard let main = message.file ?? message.thumbnail else { return nil }
                return Self.candidate(main, rendered: message.file == nil ? nil : message.thumbnail)
            }
        }

        // The timeline listed messages but no image URLs: ask for each
        // non-text message individually (newest first, capped).
        let ids = messages.reversed()
            .filter { !$0.isVideo && $0.type.lowercased() != "text" }
            .prefix(150).map(\.id)
        guard !ids.isEmpty else { return [] }
        let refreshed = await refreshMessageImages(ids: Array(ids), origin: origin)
        AppLog.log("長押し画像の照合: タイムラインに画像URLが無いためメッセージ\(ids.count)件を個別取得 → \(refreshed.count)件")
        return ids.compactMap { id in
            guard let message = refreshed[id], !message.isVideo else { return nil }
            let full = message.images.first { $0.path.contains("/files/") }
            let thumb = message.images.first { $0.path.contains("/thumbnails/") }
            guard let main = full ?? thumb else { return nil }
            return Self.candidate(main, rendered: full == nil ? nil : thumb)
        }
    }

    /// Every image the page has loaded since it opened (NetworkTap.js keeps
    /// that list, unaffected by extraction draining the resource-timing
    /// buffer). Using the bulk-extraction pipeline here instead left only 3
    /// candidates right after a relaunch, none of them the pressed photo
    /// (seen on device). Message photos get freshly signed URLs from the
    /// site's API, since the page's own ones are often expired (403).
    private func longPressCandidates() async -> [PageImage] {
        let raw = (try? await webView.evaluateJavaScript(
            "window.__ImageBrowserSeenImages ? window.__ImageBrowserSeenImages() : []")) as? [String] ?? []
        let urls = Self.dropThumbnailsWithFullSize(raw.compactMap(URL.init(string:)))

        // Newest first, so the cap keeps what was loaded most recently --
        // most likely what's on screen.
        var messageIDs: [String] = []
        var urlsByID: [String: [URL]] = [:]
        var others: [URL] = []
        for url in urls.reversed() {
            if let id = Self.messageID(of: url) {
                if urlsByID[id] == nil { messageIDs.append(id) }
                urlsByID[id, default: []].append(url)
            } else {
                others.append(url)
            }
        }
        messageIDs = Array(messageIDs.prefix(150))

        var refreshed: [String: RefreshedMessage] = [:]
        if let origin = messageAPIOrigin, !messageIDs.isEmpty {
            refreshed = await refreshMessageImages(ids: messageIDs, origin: origin)
        }
        let now = Date()
        var candidates: [PageImage] = []
        for id in messageIDs {
            if let message = refreshed[id] {
                if message.isVideo { continue }
                let full = message.images.first { $0.path.contains("/files/") }
                let thumb = message.images.first { $0.path.contains("/thumbnails/") }
                if let main = full ?? thumb {
                    candidates.append(Self.candidate(main, rendered: full == nil ? nil : thumb))
                }
                continue
            }
            // Not refreshed (no message API on this site, e.g. yodel): the
            // page's own URLs, upgraded to full size where known.
            for url in urlsByID[id] ?? [] where !Self.looksLikeVideoPoster(url) {
                if url.path.contains("/thumbnails/"),
                   let full = apiFullSizeByKey[Self.fullSizeKey(url)], !Self.isExpired(full, at: now) {
                    candidates.append(Self.candidate(full, rendered: url))
                } else {
                    candidates.append(Self.candidate(url, rendered: nil))
                }
            }
        }
        candidates += others.map { Self.candidate($0, rendered: nil) }
        AppLog.log("長押し画像の照合の候補: ページの読み込み履歴\(raw.count)件・メッセージ\(messageIDs.count)件(最新URL取得\(refreshed.count)件)・その他\(others.count)件")
        return candidates
    }

    private static func bitmap(of image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    private static func candidate(_ url: URL, rendered: URL?) -> PageImage {
        PageImage(
            id: 1_000_000 + Int(UInt(bitPattern: url.absoluteString.hashValue) % 1_000_000),
            url: url, width: 0, height: 0, renderedURL: rendered, origin: "network"
        )
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
    private func captureCrop(around point: CGPoint, region: CGRect?, margin: CGFloat = 12, fallbackSide: CGFloat = 320) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        if let region {
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

    /// UserDefaults.didChangeNotification fires on *any* UserDefaults write --
    /// including every AppLog line -- so without this check the rule list
    /// was removed and re-added on every tab for every log line written.
    /// Only acts when the setting actually changed.
    private var appliedAdBlockState: Bool?

    private func applyAdBlockState() {
        guard let adBlockRuleList else { return }
        let enabled = AdBlockStore.isEnabled
        guard enabled != appliedAdBlockState else { return }
        appliedAdBlockState = enabled
        let contentController = webView.configuration.userContentController
        contentController.remove(adBlockRuleList)
        if enabled {
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
        loadBundledScript(named: "ImageCollector")
    }

    private static func loadBundledScript(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            assertionFailure("\(name).js is missing from the app bundle")
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
        requestStorageScan()
        detectCanvasPageLater()
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

extension WebViewController: WKScriptMessageHandler {
    /// Reports from NetworkTap.js: one per API-like response the page
    /// received, with any image URLs found inside its body. Diagnostic only
    /// for now -- logged so we can see whether a site's API already hands
    /// out full-size image URLs that the page itself never fetches.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "imageBrowserNet" else { return }
        // Forward to the tab the message actually came from (see `owners`).
        if let source = message.webView, source !== webView,
           let owner = Self.owners.object(forKey: source) {
            owner.userContentController(userContentController, didReceive: message)
            return
        }
        guard let body = message.body as? [String: Any] else { return }
        let kind = body["kind"] as? String ?? "api"
        let rawURL = body["url"] as? String ?? ""
        let total = body["total"] as? Int ?? 0
        let images = (body["images"] as? [String] ?? []).compactMap(URL.init(string:))
        rememberAPIFullSize(images)
        let fullSize = images.filter { $0.path.contains("/files/") }.count
        let thumbs = images.filter { $0.path.contains("/thumbnails/") }.count
        let samples = images.prefix(3).map(Self.shortPath).joined(separator: ", ")
        let imageSummary = total > 0
            ? "画像URL\(total)件(files:\(fullSize) thumbnails:\(thumbs)) 例: \(samples)"
            : "画像URLなし"

        switch kind {
        case "timeline":
            guard let requestID = body["requestID"] as? String,
                  let continuation = pendingTimeline.removeValue(forKey: requestID) else { return }
            let messages = (body["messages"] as? [[String: Any]] ?? []).map { item in
                TimelineMessage(
                    id: item["id"] as? String ?? "",
                    type: item["type"] as? String ?? "",
                    file: (item["file"] as? String).flatMap(URL.init(string:)),
                    thumbnail: (item["thumbnail"] as? String).flatMap(URL.init(string:)),
                    width: item["width"] as? Int ?? 0,
                    height: item["height"] as? Int ?? 0
                )
            }
            let keys = (body["keys"] as? [String] ?? []).sorted().joined(separator: ",")
            let error = body["error"] as? String ?? ""
            AppLog.log("タイムラインAPIの取得: HTTP\(body["status"] as? Int ?? 0) \(body["pages"] as? Int ?? 0)ページ メッセージ\(messages.count)件 項目[\(keys)]\(error.isEmpty ? "" : " エラー: \(error)")",
                       isError: !error.isEmpty)
            continuation.resume(returning: messages)
            return
        case "refresh":
            guard let requestID = body["requestID"] as? String,
                  let continuation = pendingRefresh.removeValue(forKey: requestID) else { return }
            let raw = body["results"] as? [String: [String: Any]] ?? [:]
            let results = raw.mapValues { item in
                RefreshedMessage(
                    images: (item["images"] as? [String] ?? []).compactMap(URL.init(string:)),
                    type: item["type"] as? String ?? "",
                    fileExtension: (item["ext"] as? String ?? "").lowercased()
                )
            }
            let statuses = (body["statuses"] as? [String: Int] ?? [:])
                .sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
            // Header *names* only -- values are auth tokens.
            let headerNames = (body["headerNames"] as? [String] ?? []).joined(separator: ", ")
            let summary = "メッセージAPI再取得の応答: HTTP内訳[\(statuses)] 付与した認証ヘッダー名[\(headerNames.isEmpty ? "なし" : headerNames)]"
            // Always recorded when anything other than 200 came back (expired
            // login, changed API...), otherwise only in verbose mode.
            let allOK = (body["statuses"] as? [String: Int] ?? [:]).keys.allSatisfy { $0 == "200" }
            if allOK { AppLog.debug(summary) } else { AppLog.log(summary, isError: true) }
            continuation.resume(returning: results)
            return
        case "ws-open":
            AppLog.debug("WebSocket接続: \(rawURL)")
        case "ws":
            AppLog.debug("WebSocket受信: \(Self.endpoint(rawURL, relativeTo: webView.url)) \(body["bytes"] as? Int ?? 0)bytes \(imageSummary)")
        case "storage":
            if let error = body["error"] as? String {
                AppLog.debug("端末内保存 \(body["store"] as? String ?? ""): 読み取り失敗 \(error)")
            } else {
                let sample = (body["sample"] as? [String] ?? []).joined(separator: ", ")
                AppLog.debug("端末内保存 \(body["store"] as? String ?? ""): キー\(body["keys"] as? Int ?? 0)個 \(body["bytes"] as? Int ?? 0)文字、画像URLを含むキー\(body["entries"] as? Int ?? 0)個 画像URL\(total)件(files:\(body["files"] as? Int ?? 0)) 例: \(sample)")
            }
        case "idb":
            if let error = body["error"] as? String {
                AppLog.debug("IndexedDB: 一覧取得失敗 \(error)")
            } else {
                AppLog.debug("IndexedDB: \((body["names"] as? [String] ?? []).joined(separator: ", "))")
            }
        case "idb-store":
            if let error = body["error"] as? String {
                AppLog.debug("IndexedDB \(body["db"] as? String ?? "")/\(body["store"] as? String ?? ""): 読み取り失敗 \(error)")
            } else {
                let fileURLs = (body["fileURLs"] as? [String] ?? []).compactMap(URL.init(string:))
                for url in fileURLs { idbFullSizeByKey[Self.fullSizeKey(url)] = url }
                if idbFullSizeByKey.count > 10000 { idbFullSizeByKey.removeAll() }
                AppLog.debug("IndexedDB \(body["db"] as? String ?? "")/\(body["store"] as? String ?? ""): レコード\(body["records"] as? Int ?? 0)件 画像URL\(total)件(files:\(body["files"] as? Int ?? 0)、対応表に\(fileURLs.count)件登録)")
            }
        default:
            if let url = URL(string: rawURL, relativeTo: webView.url)?.absoluteURL,
               let host = url.host, host.hasPrefix("api.message."), url.path.hasPrefix("/v2/") {
                let origin = "\(url.scheme ?? "https")://\(host)"
                if messageAPIOrigin != origin {
                    messageAPIOrigin = origin
                    prefetchTimelineIfNeeded()
                }
            }
            let status = body["status"] as? Int ?? 0
            let ctype = body["ctype"] as? String ?? ""
            let bytes = body["bytes"] as? Int ?? 0
            let shape = body["shape"] as? String ?? ""
            let shapeText = shape.isEmpty ? "" : " 構造:\(shape)"
            AppLog.debug("通信応答: \(Self.endpoint(rawURL, relativeTo: webView.url)) HTTP\(status) \(ctype) \(bytes)bytes \(imageSummary)\(shapeText)")
        }
    }

    /// host + path + query, with each query value cut to 24 characters --
    /// paging/filter parameters (e.g. `?before=123&count=20`) matter for
    /// figuring out how a site loads older items, but a signed URL's
    /// Signature/Policy values are hundreds of characters of noise.
    private static func endpoint(_ raw: String, relativeTo base: URL?) -> String {
        guard let url = URL(string: raw, relativeTo: base),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return raw }
        var text = "\(components.host ?? "")\(components.path)"
        if let items = components.queryItems, !items.isEmpty {
            text += "?" + items.map { item in
                let value = item.value ?? ""
                return "\(item.name)=\(value.count > 24 ? String(value.prefix(24)) + "…" : value)"
            }.joined(separator: "&")
        }
        return text
    }
}

/// Forwards to a weakly held handler -- see where it's registered in
/// WebViewController.init for why.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

extension WebViewController: UIGestureRecognizerDelegate {
    /// Touch-down on a page already known to be canvas-rendered: grabs the
    /// screen right away, before the site's own long-press handling reacts.
    /// Sakurazaka46 Message opens its own menu (favorite/reply) and dims the
    /// whole page on long press, at about the same moment ours fires -- a
    /// snapshot taken after that shows a darkened photo with a menu on top.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let host = webView.url?.host, Self.canvasHosts.contains(host) {
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            webView.takeSnapshot(with: config) { [weak self] image, _ in
                guard let image else { return }
                self?.touchDownScreen = (image, Date())
            }
        }
        return true
    }

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
