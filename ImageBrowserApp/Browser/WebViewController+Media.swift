import WebKit

/// Video and audio saving (moved in from VideoBrowser, 2026-11-10).
/// MediaSniffer.js runs in every frame from document start and reports each
/// video/audio URL the page touches; this collects them per page into
/// `detectedMedia`, which the toolbar's save button lists. Talk videos and
/// voices come from the same timeline walk the image features use.
extension WebViewController {

    var isRestrictedSite: Bool { RestrictedSites.isRestricted(webView.url) }

    /// Media elements that haven't played yet only show up in a DOM scan;
    /// run before listing so the list is complete.
    func rescanPage() async {
        _ = try? await webView.evaluateJavaScript("window.__VideoBrowserScan && window.__VideoBrowserScan()")
        // Reports from subframes arrive through the message handler shortly after.
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    /// `labeled`: the title is the element's own name (title / aria-label /
    /// figcaption), which beats the page title an earlier report used.
    private func addDetected(_ media: DetectedMedia, via: String, labeled: Bool = false) {
        if let index = detectedMedia.firstIndex(where: { $0.id == media.id }) {
            // Same URL seen again: keep what the earlier report lacked.
            var merged = detectedMedia[index]
            if merged.posterURL == nil { merged.posterURL = media.posterURL }
            if (merged.duration ?? 0) == 0 { merged.duration = media.duration }
            if merged.title.isEmpty || labeled { merged.title = media.title }
            merged.isAudio = merged.isAudio || media.isAudio
            detectedMedia[index] = merged
            return
        }
        detectedMedia.insert(media, at: 0)
        if detectedMedia.count > 200 { detectedMedia.removeLast() }
        AppLog.log("検出: \(media.typeLabel) \(Self.shortURL(media.url)) 経路:\(via)")
    }

    /// host + path, without the query -- signed URLs carry hundreds of
    /// characters of signature.
    static func shortURL(_ url: URL) -> String {
        "\(url.host ?? "")\(url.path)"
    }

    /// The headers a download sends so the server sees the same client the
    /// page is: this tab's cookies, Referer and User-Agent.
    func requestContext(for url: URL) async -> RequestContext {
        var headers: [String: String] = [:]
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let matching = cookies.filter { cookie in
            guard let host = url.host?.lowercased() else { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
        headers.merge(HTTPCookie.requestHeaderFields(with: matching)) { $1 }
        if let page = webView.url, page.scheme?.hasPrefix("http") == true {
            headers["Referer"] = page.absoluteString
        }
        if let agent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String {
            headers["User-Agent"] = agent
        }
        return RequestContext(headers: headers)
    }

    func noteNavigationResponse(_ response: URLResponse) {
        guard let url = response.url,
              let found = DetectedMedia.classify(url, mimeType: response.mimeType ?? "") else { return }
        addDetected(DetectedMedia(url: url, kind: found.kind, isAudio: found.isAudio,
                                  title: url.deletingPathExtension().lastPathComponent,
                                  pageURL: url), via: "navigation")
    }

    /// Reports from MediaSniffer.js.
    func handleMediaReport(_ body: [String: Any]) {
        guard body["kind"] as? String == "media",
              let raw = body["url"] as? String, var url = URL(string: raw) else { return }
        url = DetectedMedia.stripRangeParameters(url)
        let ctype = body["ctype"] as? String ?? ""
        guard let found = DetectedMedia.classify(url, mimeType: ctype) else { return }
        let duration = body["duration"] as? Double ?? 0
        let label = body["label"] as? String ?? ""
        addDetected(DetectedMedia(url: url, kind: found.kind,
                                  isAudio: found.isAudio || (body["audio"] as? Bool ?? false),
                                  title: label.isEmpty ? body["title"] as? String ?? pageTitle : label,
                                  posterURL: (body["poster"] as? String).flatMap(URL.init(string:)),
                                  duration: duration > 0 ? duration : nil,
                                  pageURL: webView.url),
                    via: "\(body["via"] as? String ?? "?")@\(body["frame"] as? String ?? "?")",
                    labeled: !label.isEmpty)
    }

    // MARK: - Talk (message apps)

    /// Whether the open screen is a talk whose videos and voices can be listed.
    var canListTalkMedia: Bool { canLoadHistory }

    /// Every video and voice message of the open talk, newest first. Uses
    /// the same cached timeline walk as "さかのぼり抽出".
    func talkMedia() async -> (media: [DetectedMedia], error: String?) {
        guard let origin = messageAPIOrigin, let groupID = currentTalkGroupID else { return ([], nil) }
        let started = Date()
        // As long as "さかのぼり抽出": a long talk takes a while to walk.
        let messages = await fetchTimeline(groupID: groupID, origin: origin, timeout: 190)
            .sorted { Self.deliveryOrder($1, $0) }
        let talkName = pageTitle.isEmpty ? "トーク" : pageTitle
        let media = messages.compactMap { message -> DetectedMedia? in
            guard message.isVideo || message.isVoice, let file = message.file else { return nil }
            return DetectedMedia(url: file, kind: .file, isAudio: message.isVoice,
                                 title: FileNaming.sanitized(talkName, fallback: "talk"),
                                 posterURL: message.isVideo ? message.thumbnail : nil,
                                 source: .talk, publishedAt: message.publishedAt, pageURL: webView.url)
        }
        let videos = media.filter { !$0.isAudio }.count
        let error = messages.isEmpty ? "トークを読み込めませんでした" : nil
        AppLog.log("トークの動画・音声: メッセージ\(messages.count)件中 動画\(videos)件 音声\(media.count - videos)件 \(Int(Date().timeIntervalSince(started) * 1000))ms",
                   isError: error != nil)
        return (media, error)
    }
}

extension WebViewController.TimelineMessage {
    var isVoice: Bool {
        let lower = type.lowercased()
        let ext = file?.pathExtension.lowercased() ?? ""
        return !isVideo && (lower.contains("voice") || lower.contains("audio")
            || DetectedMedia.audioExtensions.contains(ext))
    }
}
