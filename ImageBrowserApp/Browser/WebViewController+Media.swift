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
        if media.kind == .hls, let masterID = hlsPartMasters[Self.shortURL(media.url)] {
            absorb(media, into: masterID)
            return
        }
        detectedMedia.insert(media, at: 0)
        if detectedMedia.count > 200 { detectedMedia.removeLast() }
        AppLog.log("検出: \(media.typeLabel) \(Self.shortURL(media.url)) 経路:\(via)")
        if media.kind == .hls { checkMasterPlaylist(media) }
    }

    /// A master playlist and the playlists it lists are one video, but pages
    /// load both (mi-muse: "x.m3u8" lists only "x_hls.m3u8", and both were
    /// shown and batch-saved twice, 2026-11-13). Reads each HLS playlist once
    /// and, for a master, drops the ones it lists -- the master keeps the
    /// quality choice.
    private func checkMasterPlaylist(_ media: DetectedMedia) {
        guard checkedPlaylists.insert(Self.shortURL(media.url)).inserted else { return }
        Task { @MainActor in
            let context = await requestContext(for: media.url)
            guard case .master(let master)? = try? await HLSDownloader(context: context).playlist(media.url),
                  // The page moved on while this was loading.
                  detectedMedia.contains(where: { $0.id == media.id }) else { return }
            let parts = Set((master.variants.map(\.url) + master.audio.map(\.url)).map(Self.shortURL))
                .subtracting([Self.shortURL(media.url)])
            for path in parts { hlsPartMasters[path] = media.id }
            for part in detectedMedia where part.kind == .hls && parts.contains(Self.shortURL(part.url)) {
                absorb(part, into: media.id)
            }
        }
    }

    /// Drops `part` (a playlist the master `masterID` lists), handing the
    /// master what it knew that the master didn't.
    private func absorb(_ part: DetectedMedia, into masterID: String) {
        detectedMedia.removeAll { $0.id == part.id }
        AppLog.log("検出: \(Self.shortURL(part.url)) は別に検出した動画の画質違い・音声なので一覧から外した")
        guard let index = detectedMedia.firstIndex(where: { $0.id == masterID }) else { return }
        var master = detectedMedia[index]
        if master.posterURL == nil { master.posterURL = part.posterURL }
        if (master.duration ?? 0) == 0 { master.duration = part.duration }
        detectedMedia[index] = master
    }

    /// host + path, without the query -- signed URLs carry hundreds of
    /// characters of signature.
    static func shortURL(_ url: URL) -> String {
        "\(url.host ?? "")\(url.path)"
    }

    /// The headers a download sends so the server sees the same client the
    /// page is: this tab's cookies, Referer and User-Agent.
    func requestContext(for url: URL) async -> RequestContext {
        RequestContext(headers: await pageRequestHeaders().headers(for: url))
    }

    /// This tab's cookies, Referer and User-Agent, captured once and then
    /// applied to each image URL. The image grid and the photo save fetch
    /// through this so they look like the page's own requests: mi-muse's
    /// CDN serves only to requests carrying the page's CloudFront signed
    /// cookies, so without them every image comes back HTTP 403 and the
    /// grid shows ⚠ for all of them (2026-11-14).
    func pageRequestHeaders() async -> PageRequestHeaders {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let agent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String
        let referer = (webView.url?.scheme?.hasPrefix("http") == true) ? webView.url?.absoluteString : nil
        return PageRequestHeaders(cookies: cookies, userAgent: agent, referer: referer)
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

    /// Every video and voice message of the open talk, newest first, and
    /// which of them lie in the stretch the user has scrolled through.
    /// Uses the same cached timeline walk as "さかのぼり抽出".
    func talkMedia() async -> (media: [DetectedMedia], scrolled: Set<String>, error: String?) {
        guard let origin = messageAPIOrigin, let groupID = currentTalkGroupID else { return ([], [], nil) }
        let started = Date()
        // As long as "さかのぼり抽出": a long talk takes a while to walk.
        let messages = await fetchTimeline(groupID: groupID, origin: origin, timeout: 190)
            .sorted { Self.deliveryOrder($1, $0) }
        let talkName = talkNames[groupID] ?? (pageTitle.isEmpty ? "トーク" : pageTitle)
        let mediaMessages = messages.filter { ($0.isVideo || $0.isVoice) && $0.file != nil }
        let names = Self.talkFileNames(mediaMessages, talkName: talkName)
        let media = mediaMessages.map { message in
            DetectedMedia(url: message.file!, kind: .file, isAudio: message.isVoice,
                          title: FileNaming.sanitized(talkName, fallback: "talk"),
                          posterURL: message.isVideo ? message.thumbnail : nil,
                          source: .talk, publishedAt: message.publishedAt,
                          presetName: names[message.id], pageURL: webView.url)
        }
        let scrolled = await scrolledTalkMedia(media, messages: messages)
        let videos = media.filter { !$0.isAudio }.count
        let error = messages.isEmpty ? "トークを読み込めませんでした" : nil
        AppLog.log("トークの動画・音声: メッセージ\(messages.count)件中 動画\(videos)件 音声\(media.count - videos)件 スクロールした範囲\(scrolled.count)件 \(Int(Date().timeIntervalSince(started) * 1000))ms",
                   isError: error != nil)
        return (media, scrolled, error)
    }

    /// "メンバー名_yyyymmdd_hhmm", plus "_1", "_2"... (oldest first) when
    /// several arrived in the same minute (user spec, 2026-11-11).
    static func talkFileNames(_ messages: [TimelineMessage], talkName: String) -> [String: String] {
        let member = FileNaming.sanitized(talkName.components(separatedBy: .whitespaces).joined(), fallback: "talk")
        let minute = DateFormatter()
        minute.locale = Locale(identifier: "en_US_POSIX")
        minute.dateFormat = "yyyyMMdd_HHmm"
        var byMinute: [String: [TimelineMessage]] = [:]
        for message in messages {
            let stamp = DetectedMedia.date(message.publishedAt).map(minute.string(from:)) ?? "日時不明"
            byMinute[stamp, default: []].append(message)
        }
        var names: [String: String] = [:]
        for (stamp, group) in byMinute {
            let ordered = group.sorted(by: deliveryOrder)
            for (index, message) in ordered.enumerated() {
                names[message.id] = "\(member)_\(stamp)" + (ordered.count > 1 ? "_\(index + 1)" : "")
            }
        }
        return names
    }

    /// The talk opens at its newest message and the user scrolls up, so the
    /// stretch they've seen runs from the oldest message whose image the
    /// page loaded (photos and video thumbnails -- NetworkTap.js keeps every
    /// image loaded since the page opened) to the newest one.
    private func scrolledTalkMedia(_ media: [DetectedMedia], messages: [TimelineMessage]) async -> Set<String> {
        let raw = (try? await webView.evaluateJavaScript(
            "window.__ImageBrowserSeenImages ? window.__ImageBrowserSeenImages() : []")) as? [String] ?? []
        let seenIDs = Set(raw.compactMap(URL.init(string:)).compactMap(Self.messageID(of:)))
        let seen = messages.filter { seenIDs.contains($0.id) }
        guard let oldest = seen.min(by: Self.deliveryOrder) else {
            AppLog.log("トークの動画・音声: スクロールした範囲を特定できず(読み込んだ画像\(raw.count)件、該当メッセージなし)", isError: true)
            return []
        }
        return Set(media.filter { item in
            guard let at = item.publishedAt, !at.isEmpty, !oldest.publishedAt.isEmpty else { return false }
            return at >= oldest.publishedAt
        }.map(\.id))
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
