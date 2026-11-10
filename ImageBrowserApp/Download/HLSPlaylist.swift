import Foundation

/// The parts of an HLS playlist (RFC 8216) needed to download a finished
/// stream: variants and audio renditions of a master playlist, and the
/// segments / keys / init section of a media playlist.
enum HLSPlaylist {

    struct Variant {
        let url: URL
        let bandwidth: Int
        /// "1920x1080", when the playlist says.
        let resolution: String?
        let codecs: String
        /// EXT-X-MEDIA GROUP-ID of the audio that goes with this variant.
        let audioGroup: String?

        var height: Int? {
            resolution.flatMap { $0.split(separator: "x").last }.flatMap { Int($0) }
        }
    }

    struct Rendition {
        let groupID: String
        let name: String
        let url: URL
        let isDefault: Bool
    }

    struct Master {
        let variants: [Variant]
        let audio: [Rendition]

        /// Default (or first) audio of `group`.
        func audio(for group: String?) -> Rendition? {
            guard let group else { return nil }
            let candidates = audio.filter { $0.groupID == group }
            return candidates.first(where: \.isDefault) ?? candidates.first
        }
    }

    enum Encryption: Equatable {
        case none
        case aes128(key: URL, iv: Data?)
        /// SAMPLE-AES, FairPlay and anything else this app can't open.
        case unsupported(String)
    }

    struct Segment {
        let url: URL
        let duration: Double
        let byteRange: Range<Int>?
        let encryption: Encryption
        /// Used as the IV when the key has none.
        let sequence: Int
    }

    struct Media {
        let segments: [Segment]
        /// EXT-X-MAP: the fMP4 init section.
        let initSection: (url: URL, byteRange: Range<Int>?, encryption: Encryption)?
        /// No EXT-X-ENDLIST: a live stream, still growing.
        let isLive: Bool

        var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    enum Parsed {
        case master(Master)
        case media(Media)
    }

    enum ParseError: LocalizedError {
        case notPlaylist
        var errorDescription: String? { "HLSのプレイリストではありません" }
    }

    static func parse(_ text: String, baseURL: URL) throws -> Parsed {
        let lines = text.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw ParseError.notPlaylist }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(parseMaster(lines, baseURL: baseURL))
        }
        return .media(parseMedia(lines, baseURL: baseURL))
    }

    private static func parseMaster(_ lines: [String], baseURL: URL) -> Master {
        var variants: [Variant] = []
        var audio: [Rendition] = []
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(line)
                guard a["TYPE"] == "AUDIO", let uri = a["URI"], let url = URL(string: uri, relativeTo: baseURL) else { continue }
                audio.append(Rendition(groupID: a["GROUP-ID"] ?? "", name: a["NAME"] ?? "",
                                       url: url.absoluteURL, isDefault: a["DEFAULT"] == "YES"))
            } else if !line.hasPrefix("#"), let a = pending {
                pending = nil
                guard let url = URL(string: line, relativeTo: baseURL) else { continue }
                variants.append(Variant(url: url.absoluteURL, bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
                                        resolution: a["RESOLUTION"], codecs: a["CODECS"] ?? "",
                                        audioGroup: a["AUDIO"]))
            }
        }
        return Master(variants: variants, audio: audio)
    }

    private static func parseMedia(_ lines: [String], baseURL: URL) -> Media {
        var segments: [Segment] = []
        var initSection: (url: URL, byteRange: Range<Int>?, encryption: Encryption)?
        var encryption = Encryption.none
        var sequence = 0
        var duration = 0.0
        var byteRange: Range<Int>?
        // EXT-X-BYTERANGE without an offset continues from the previous one.
        var nextOffset = 0
        var isLive = true

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                duration = Double(value) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                byteRange = parseByteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), nextOffset: &nextOffset)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                encryption = parseKey(attributes(line), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(line)
                if let uri = a["URI"], let url = URL(string: uri, relativeTo: baseURL) {
                    var offset = 0
                    let range = a["BYTERANGE"].flatMap { parseByteRange($0, nextOffset: &offset) }
                    initSection = (url.absoluteURL, range, encryption)
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                isLive = false
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD") {
                isLive = false
            } else if !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL) {
                    segments.append(Segment(url: url.absoluteURL, duration: duration, byteRange: byteRange,
                                            encryption: encryption, sequence: sequence))
                }
                sequence += 1
                duration = 0
                byteRange = nil
            }
        }
        return Media(segments: segments, initSection: initSection, isLive: isLive)
    }

    /// "<length>[@<offset>]"
    private static func parseByteRange(_ value: String, nextOffset: inout Int) -> Range<Int>? {
        let parts = value.split(separator: "@")
        guard let length = Int(parts[0]) else { return nil }
        let start = parts.count > 1 ? (Int(parts[1]) ?? nextOffset) : nextOffset
        nextOffset = start + length
        return start..<(start + length)
    }

    private static func parseKey(_ a: [String: String], baseURL: URL) -> Encryption {
        switch a["METHOD"] {
        case nil, "NONE":
            return .none
        case "AES-128":
            guard let uri = a["URI"], let url = URL(string: uri, relativeTo: baseURL) else { return .unsupported("AES-128(鍵なし)") }
            return .aes128(key: url.absoluteURL, iv: a["IV"].flatMap(hexData))
        case let method?:
            let format = a["KEYFORMAT"].map { " \($0)" } ?? ""
            return .unsupported(method + format)
        }
    }

    /// `KEY=VALUE,KEY="quoted, value"` after the tag's colon.
    static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quoted = false
        func flush() {
            if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
            key = ""; value = ""; readingKey = true
        }
        for ch in line[line.index(after: colon)...] {
            if readingKey {
                if ch == "=" { readingKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }

    /// "0x1234..." -> bytes.
    static func hexData(_ hex: String) -> Data? {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
