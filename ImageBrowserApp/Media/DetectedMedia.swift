import Foundation

/// One video or audio the open page uses, found by MediaSniffer.js (or the
/// message apps' timeline API).
struct DetectedMedia: Identifiable, Hashable {
    enum Kind: String {
        /// An HLS playlist (.m3u8) -- downloaded segment by segment.
        case hls
        /// A plain file (.mp4, .m4a, .mp3, .webm...).
        case file
        /// MPEG-DASH (.mpd): detected, but not downloadable yet.
        case dash
    }

    /// Where it was found -- shown in the list and logged.
    enum Source: String {
        case page
        case talk
    }

    var id: String { url.absoluteString }
    let url: URL
    let kind: Kind
    var isAudio: Bool
    var title: String
    var posterURL: URL?
    /// Seconds, when the page's media element knew it.
    var duration: Double?
    var source: Source = .page
    /// Delivery time of a talk message (ISO 8601).
    var publishedAt: String?
    /// The file name to offer, when the source decided it (talk messages).
    var presetName: String?
    let pageURL: URL?
    var foundAt = Date()

    /// The file name offered first in the save sheet.
    var suggestedName: String {
        if let presetName { return presetName }
        if source == .talk, let publishedAt, let date = Self.date(publishedAt) {
            return "\(title)_\(Self.nameFormatter.string(from: date))"
        }
        if !title.isEmpty { return title }
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty ? (isAudio ? "audio" : "video") : last
    }

    var typeLabel: String {
        switch kind {
        case .hls: return isAudio ? "音声(ストリーミング)" : "動画(ストリーミング)"
        case .file:
            let ext = url.pathExtension.uppercased()
            return (isAudio ? "音声" : "動画") + (ext.isEmpty ? "" : "(\(ext))")
        case .dash: return "動画(DASH・未対応)"
        }
    }

    var canDownload: Bool { kind != .dash }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterPlain = ISO8601DateFormatter()

    /// A talk message's ISO 8601 delivery time, with or without fractions.
    static func date(_ iso: String) -> Date? {
        isoFormatter.date(from: iso) ?? isoFormatterPlain.date(from: iso)
    }
    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyyMMdd_HHmm"
        return f
    }()

    // MARK: - Classifying URLs

    static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "wav", "ogg", "oga", "opus", "flac"]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "3gp"]

    /// Kind of `url` / `mimeType`, or nil when it isn't a downloadable media
    /// URL at all (HLS segments, images, scripts...).
    static func classify(_ url: URL, mimeType: String = "") -> (kind: Kind, isAudio: Bool)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let ext = url.pathExtension.lowercased()
        let mime = mimeType.lowercased()
        if ext == "m3u8" || mime.contains("mpegurl") { return (.hls, false) }
        if ext == "mpd" || mime.contains("dash+xml") { return (.dash, false) }
        // HLS/DASH segments: parts of a stream, not something to save alone.
        if ["ts", "m4s", "aac"].contains(ext) && url.path.range(of: #"(seg|chunk|frag|part)[-_]?\d+|/\d+\.(ts|m4s|aac)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        if ext == "ts" || ext == "m4s" { return nil }
        if audioExtensions.contains(ext) || mime.hasPrefix("audio/") { return (.file, true) }
        if videoExtensions.contains(ext) || mime.hasPrefix("video/") { return (.file, false) }
        return nil
    }

    /// Byte-range query parameters some players add to every request of one
    /// file (Instagram/Facebook's `bytestart`/`byteend`): without them the
    /// URL is the whole file.
    static func stripRangeParameters(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return url }
        let drop: Set<String> = ["bytestart", "byteend", "range"]
        let kept = items.filter { !drop.contains($0.name.lowercased()) }
        guard kept.count != items.count else { return url }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }
}

/// Sites whose media this app doesn't offer to save: DRM-protected
/// streaming services, which no app can save anyway (their streams are
/// FairPlay/Widevine-encrypted). Decided with the user 2026-11-04: DRM only
/// for now -- the services App Review Guideline 5.2.3 names (YouTube,
/// Vimeo, SoundCloud) are left alone until review says otherwise. Add or
/// remove entries here only.
enum RestrictedSites {
    static let hosts: [String] = [
        "netflix.com", "nflxvideo.net",
        "primevideo.com",
        "disneyplus.com",
        "hulu.jp", "hulu.com",
        "unext.jp", "video.unext.jp",
        "abema.tv",
        "dazn.com",
        "music.apple.com", "tv.apple.com",
        "spotify.com",
    ]

    static func isRestricted(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
