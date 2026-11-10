import Foundation
import AVFoundation
import CommonCrypto

/// HTTP headers a download needs to look like the page's own request:
/// cookies, Referer, User-Agent, and for the message apps their auth headers.
struct RequestContext {
    var headers: [String: String] = [:]

    func request(_ url: URL, range: Range<Int>? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        return request
    }
}

enum DownloadError: LocalizedError {
    case http(Int, String)
    case live
    case drm(String)
    case empty
    case cancelled

    var errorDescription: String? {
        switch self {
        case .http(let status, let what): return "サーバーが応答を拒否しました(HTTP \(status)、\(what))"
        case .live: return "ライブ配信中の映像は保存できません"
        case .drm(let method): return "著作権保護(DRM)がかかっているため保存できません(\(method))"
        case .empty: return "保存できるデータがありませんでした"
        case .cancelled: return "中止しました"
        }
    }
}

/// Downloads one HLS stream to a single MP4 / M4A file.
final class HLSDownloader {

    /// What the save sheet offers for a master playlist.
    struct Quality: Identifiable, Hashable {
        let id: Int
        let label: String
        let bandwidth: Int
        let height: Int?
    }

    struct Progress {
        var done: Int
        var total: Int
        var bytes: Int64
    }

    let context: RequestContext
    let session: URLSession
    /// Segments fetched at once.
    var concurrency = 4
    private let keyCache = KeyCache()

    init(context: RequestContext, session: URLSession = .shared) {
        self.context = context
        self.session = session
    }

    // MARK: - Playlists

    func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(for: context.request(url))
        try Self.check(response, what: "プレイリスト")
        return String(decoding: data, as: UTF8.self)
    }

    func playlist(_ url: URL) async throws -> HLSPlaylist.Parsed {
        try HLSPlaylist.parse(try await fetchText(url), baseURL: url)
    }

    /// Variants of a master playlist, best first, one per height. Empty for
    /// a media playlist (only one quality).
    func qualities(_ url: URL) async throws -> [Quality] {
        guard case .master(let master) = try await playlist(url) else { return [] }
        var seen = Set<String>()
        return master.variants.enumerated()
            .sorted { $0.element.bandwidth > $1.element.bandwidth }
            .compactMap { index, variant in
                let label = variant.height.map { "\($0)p" } ?? "\(variant.bandwidth / 1000)kbps"
                guard seen.insert(label).inserted else { return nil }
                return Quality(id: index, label: label, bandwidth: variant.bandwidth, height: variant.height)
            }
    }

    /// Downloads `url` (master or media playlist) to `output`. `quality` is
    /// the index of a master playlist's variant; nil takes the best one.
    /// Returns the file actually written -- `.m4a` when the stream has no video.
    func download(_ url: URL, quality: Int? = nil, to output: URL,
                  progress: @escaping (Progress) -> Void) async throws -> URL {
        let work = output.deletingLastPathComponent()
            .appendingPathComponent("hls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var mediaURL = url
        var audioURL: URL?
        if case .master(let master) = try await playlist(url) {
            let variants = master.variants
            guard !variants.isEmpty else { throw DownloadError.empty }
            let chosen = quality.flatMap { $0 < variants.count ? variants[$0] : nil }
                ?? variants.max { $0.bandwidth < $1.bandwidth }!
            mediaURL = chosen.url
            audioURL = master.audio(for: chosen.audioGroup)?.url
            AppLog.log("HLS: \(variants.count)種類から \(chosen.resolution ?? "?") \(chosen.bandwidth / 1000)kbps を選択\(audioURL == nil ? "" : "(音声は別)")")
        }

        guard case .media(let media) = try await playlist(mediaURL) else { throw DownloadError.empty }
        var audioMedia: HLSPlaylist.Media?
        if let audioURL, case .media(let m) = try await playlist(audioURL) { audioMedia = m }

        for m in [media, audioMedia].compactMap({ $0 }) {
            if m.isLive { throw DownloadError.live }
            for case .unsupported(let method) in m.segments.map(\.encryption) { throw DownloadError.drm(method) }
        }

        let total = media.segments.count + (audioMedia?.segments.count ?? 0)
        var state = Progress(done: 0, total: total, bytes: 0)
        let lock = NSLock()
        let report: (Int) -> Void = { bytes in
            lock.lock()
            state.done += 1
            state.bytes += Int64(bytes)
            let snapshot = state
            lock.unlock()
            progress(snapshot)
        }

        let main = try await render(media, to: work.appendingPathComponent("main"), report: report)
        guard let audioMedia else {
            return try await MediaMerger.finalize(main, to: output)
        }
        let audio = try await render(audioMedia, to: work.appendingPathComponent("audio"), report: report)
        return try await MediaMerger.merge(video: main, audio: audio, to: output)
    }

    /// One media playlist -> one file (`.mp4` / `.m4a` / fragmented `.mp4`).
    private func render(_ media: HLSPlaylist.Media, to base: URL, report: @escaping (Int) -> Void) async throws -> URL {
        guard !media.segments.isEmpty else { throw DownloadError.empty }
        if let initSection = media.initSection {
            // fMP4: init section + fragments, laid end to end, is already a
            // valid fragmented MP4.
            let url = base.appendingPathExtension("mp4")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let head = try await fetch(initSection.url, range: initSection.byteRange,
                                       encryption: initSection.encryption, sequence: 0)
            try handle.write(contentsOf: head)
            try await eachSegment(media) { data in
                try handle.write(contentsOf: data)
                report(data.count)
            }
            return url
        }

        let first = try await fetch(media.segments[0])
        if Self.isFragmentedMP4(first) {
            // fMP4 without EXT-X-MAP (each fragment carries its own moov).
            let url = base.appendingPathExtension("mp4")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try await eachSegment(media) { data in
                try handle.write(contentsOf: data)
                report(data.count)
            }
            return url
        }

        let demuxer = TSDemuxer()
        demuxer.feed(first)
        let probe = demuxer.take()
        let url = base.appendingPathExtension(demuxer.videoCodec == nil ? "m4a" : "mp4")
        let writer = TSToMP4Writer(outputURL: url)
        do {
            try writer.append(probe, from: demuxer)
            report(first.count)
            try await eachSegment(media, skipFirst: true) { data in
                demuxer.feed(data)
                try writer.append(demuxer.take(), from: demuxer)
                report(data.count)
            }
            demuxer.flush()
            try writer.append(demuxer.take(), from: demuxer)
            try await writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        if !demuxer.skippedStreamTypes.isEmpty {
            AppLog.log("HLS: 対応外のストリームを読み飛ばし type=\(demuxer.skippedStreamTypes.sorted().map { String(format: "0x%02x", $0) })")
        }
        AppLog.log("HLS: TSから書き出し 映像\(writer.videoFrames)フレーム 音声\(writer.audioFrames)フレーム")
        return url
    }

    /// Fetches segments `concurrency` at a time but hands them to `body` in
    /// playlist order.
    private func eachSegment(_ media: HLSPlaylist.Media, skipFirst: Bool = false,
                             _ body: (Data) throws -> Void) async throws {
        let segments = Array(media.segments.dropFirst(skipFirst ? 1 : 0))
        var next = 0
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var buffered: [Int: Data] = [:]
            var launched = 0
            func launch() {
                guard launched < segments.count else { return }
                let index = launched
                let segment = segments[index]
                launched += 1
                group.addTask { (index, try await self.fetch(segment)) }
            }
            for _ in 0..<min(concurrency, segments.count) { launch() }
            while let (index, data) = try await group.next() {
                try Task.checkCancellation()
                buffered[index] = data
                while let ready = buffered.removeValue(forKey: next) {
                    try body(ready)
                    next += 1
                }
                launch()
            }
        }
    }

    private func fetch(_ segment: HLSPlaylist.Segment) async throws -> Data {
        try await fetch(segment.url, range: segment.byteRange, encryption: segment.encryption, sequence: segment.sequence)
    }

    private func fetch(_ url: URL, range: Range<Int>?, encryption: HLSPlaylist.Encryption, sequence: Int) async throws -> Data {
        var lastError: Error?
        // A segment or two failing mid-way on a phone connection is normal.
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: context.request(url, range: range))
                try Self.check(response, what: "セグメント")
                switch encryption {
                case .none:
                    return data
                case .aes128(let keyURL, let iv):
                    let key = try await self.key(keyURL)
                    return try Self.decrypt(data, key: key, iv: iv ?? Self.sequenceIV(sequence))
                case .unsupported(let method):
                    throw DownloadError.drm(method)
                }
            } catch let error as DownloadError {
                throw error
            } catch {
                lastError = error
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 700_000_000)
            }
        }
        throw lastError ?? DownloadError.empty
    }

    private func key(_ url: URL) async throws -> Data {
        if let cached = await keyCache.get(url) { return cached }
        let (data, response) = try await session.data(for: context.request(url))
        try Self.check(response, what: "復号キー")
        await keyCache.set(url, data)
        return data
    }

    // MARK: - Helpers

    static func check(_ response: URLResponse, what: String) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.http(http.statusCode, what)
        }
    }

    static func isFragmentedMP4(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let type = String(decoding: data[4..<8], as: UTF8.self)
        return ["ftyp", "styp", "moof", "sidx"].contains(type)
    }

    /// RFC 8216 5.2: without an IV attribute, the media sequence number as
    /// a 128-bit big-endian integer.
    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &value) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw DownloadError.drm("AES-128の鍵の長さ \(key.count)") }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count,
                                o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DownloadError.drm("AES-128の復号に失敗 \(status)") }
        out.count = moved
        return out
    }
}

/// AES-128 keys, shared by the segments fetched in parallel.
private actor KeyCache {
    private var keys: [URL: Data] = [:]
    func get(_ url: URL) -> Data? { keys[url] }
    func set(_ url: URL, _ data: Data) { keys[url] = data }
}

/// Turns HLSDownloader's intermediate files into the final one.
enum MediaMerger {

    /// A single rendition: written as is when it's already a plain MP4 from
    /// the TS path; a fragmented MP4 is rewritten as a regular one (the
    /// Photos library refuses some fragmented files).
    static func finalize(_ url: URL, to output: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        let target = output.deletingPathExtension().appendingPathExtension(hasVideo ? "mp4" : "m4a")
        try? FileManager.default.removeItem(at: target)
        let fragmented = try await isFragmented(asset)
        if url.pathExtension == "m4a" || !fragmented {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        try await export(asset, to: target, fileType: hasVideo ? .mp4 : .m4a)
        return target
    }

    /// Video of one rendition + audio of another -> one MP4.
    static func merge(video: URL, audio: URL, to output: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let duration = try await videoAsset.load(.duration)
        if let track = try await videoAsset.loadTracks(withMediaType: .video).first,
           let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            target.preferredTransform = try await track.load(.preferredTransform)
        }
        // Audio muxed into the video rendition too is dropped in favor of
        // the separate one the master playlist pointed to.
        if let track = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)), of: track, at: .zero)
        }
        let target = output.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: target)
        try await export(composition, to: target, fileType: .mp4)
        return target
    }

    static func export(_ asset: AVAsset, to url: URL, fileType: AVFileType) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TSToMP4Writer.WriterError.writer("書き出しの準備ができません")
        }
        session.outputURL = url
        session.outputFileType = fileType
        await session.export()
        if session.status != .completed {
            throw TSToMP4Writer.WriterError.writer(session.error?.localizedDescription ?? "export \(session.status.rawValue)")
        }
    }

    private static func isFragmented(_ asset: AVURLAsset) async throws -> Bool {
        // AVFoundation exposes no flag for this; the file's top-level boxes do.
        guard let handle = try? FileHandle(forReadingFrom: asset.url) else { return false }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        for _ in 0..<16 {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return false }
            var size = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "moof" || type == "mvex" { return true }
            if size == 1, header.count >= 16 {
                size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            }
            if type == "moov" {
                // mvex sits inside moov.
                try handle.seek(toOffset: offset + 8)
                if let body = try handle.read(upToCount: Int(min(size, 4_000_000))),
                   body.range(of: Data("mvex".utf8)) != nil { return true }
            }
            guard size >= 8 else { return false }
            offset += size
        }
        return false
    }
}
