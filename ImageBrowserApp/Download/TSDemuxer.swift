import Foundation

/// Splits MPEG-2 transport stream segments (what most HLS streams are made
/// of) into H.264 / HEVC access units and AAC frames, so they can be written
/// to MP4 as they are -- no re-encoding, no ffmpeg. Also reads "packed
/// audio" segments (raw ADTS with an ID3 header), which audio-only HLS
/// renditions use instead of TS.
///
/// One instance per rendition, fed segment by segment: state (PMT, a PES
/// cut by a segment boundary, timestamp wrap) carries over between calls.
final class TSDemuxer {

    enum VideoCodec { case h264, hevc }

    struct VideoSample {
        /// Length-prefixed (4 bytes) NAL units, parameter sets and AUDs removed.
        let data: Data
        let pts: Int64
        let dts: Int64
        let isKeyframe: Bool
    }

    struct AudioSample {
        /// One raw AAC frame (ADTS header removed).
        let data: Data
        let pts: Int64
    }

    struct AACConfig: Equatable {
        let objectType: Int
        let sampleRateIndex: Int
        let channels: Int

        static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var sampleRate: Int { sampleRateIndex < Self.sampleRates.count ? Self.sampleRates[sampleRateIndex] : 44100 }

        /// The 2-byte AudioSpecificConfig.
        var audioSpecificConfig: Data {
            let value = UInt16(objectType << 11 | sampleRateIndex << 7 | channels << 3)
            return Data([UInt8(value >> 8), UInt8(value & 0xff)])
        }
    }

    /// 90 kHz, like the stream itself.
    static let timescale: Int32 = 90_000

    private(set) var videoCodec: VideoCodec?
    /// SPS, PPS (H.264) or VPS, SPS, PPS (HEVC) -- the first ones seen.
    private(set) var parameterSets: [Data] = []
    private(set) var aacConfig: AACConfig?

    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var pes: [Int: Data] = [:]
    private var audioRemainder = Data()
    private var audioRemainderPTS: Int64?
    private var lastTimestamp: [Int: Int64] = [:]
    /// Packed audio has no timestamps of its own past the first; frames are
    /// laid end to end.
    private var packedAudioNextPTS: Int64 = 0

    private var h264SPS: Data?, h264PPS: Data?
    private var hevcVPS: Data?, hevcSPS: Data?, hevcPPS: Data?

    private(set) var video: [VideoSample] = []
    private(set) var audio: [AudioSample] = []
    /// Stream types seen in the PMT that this demuxer skips (e.g. MP3, AC-3).
    private(set) var skippedStreamTypes: Set<Int> = []

    /// Samples completed so far; clears them.
    func take() -> (video: [VideoSample], audio: [AudioSample]) {
        defer { video.removeAll(); audio.removeAll() }
        return (video, audio)
    }

    func feed(_ data: Data) {
        let bytes = [UInt8](data)
        if bytes.first != 0x47 {
            feedPackedAudio(bytes)
            return
        }
        var offset = 0
        while offset + 188 <= bytes.count {
            if bytes[offset] != 0x47 {
                // Lost sync: look for the next packet start.
                offset += 1
                continue
            }
            packet(bytes, offset)
            offset += 188
        }
    }

    /// Emits whatever PES is still open (end of stream).
    func flush() {
        for (pid, data) in pes where !data.isEmpty {
            handlePES(pid: pid, data: [UInt8](data))
        }
        pes.removeAll()
        if let start = nalStart {
            handleNAL(Self.trimmed(es[(start - esBase)...]), at: start)
            nalStart = nil
        }
        closeAccessUnit()
    }

    // MARK: - Video elementary stream

    // Access units are cut from the elementary stream itself, not taken one
    // per PES: a PES can end mid-frame, the next one starting with the
    // previous frame's last slice (seen in Apple's bipbop: frame 1's 8th
    // slice arrived in frame 2's PES, and everything after the first
    // keyframe failed to decode). A PES's timestamps belong to the first
    // access unit that *starts* inside it (ISO 13818-1 2.4.3.7).

    /// Video ES bytes not yet consumed; `esBase` is the absolute offset of `es[0]`.
    private var es: [UInt8] = []
    private var esBase = 0
    private var scanFrom = 0
    /// Absolute offset of the open NAL unit's first byte (after its start code).
    private var nalStart: Int?
    private var timings: [(offset: Int, pts: Int64, dts: Int64, used: Bool)] = []
    private var auNALs: [ArraySlice<UInt8>] = []
    private var auStart: Int?
    private var auHasSlice = false
    private var lastDTS: Int64?
    private var lastFrameDuration: Int64 = 3000

    private func videoPES(_ payload: [UInt8], pts: Int64?, dts: Int64?) {
        if let pts { timings.append((esBase + es.count, pts, dts ?? pts, false)) }
        es += payload
        var i = max(0, scanFrom - esBase)
        while i + 2 < es.count {
            if es[i] == 0, es[i + 1] == 0, es[i + 2] == 1 {
                if let start = nalStart {
                    handleNAL(Self.trimmed(es[(start - esBase)..<i]), at: start)
                }
                i += 3
                nalStart = esBase + i
            } else {
                i += 1
            }
        }
        scanFrom = esBase + i
        // Keep memory bounded: everything before the open NAL is done with.
        let keepFrom = (nalStart ?? scanFrom) - esBase
        if keepFrom > 1_000_000 {
            es.removeFirst(keepFrom)
            esBase += keepFrom
        }
    }

    /// Trailing zero bytes belong to the next start code / stream padding,
    /// never to the NAL unit (it ends in its RBSP stop bit).
    private static func trimmed(_ nal: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var end = nal.endIndex
        while end > nal.startIndex, nal[end - 1] == 0 { end -= 1 }
        return nal[nal.startIndex..<end]
    }

    private func handleNAL(_ nal: ArraySlice<UInt8>, at offset: Int) {
        guard let codec = videoCodec, nal.count >= 2 else { return }
        let first = nal[nal.startIndex]
        let isSlice: Bool
        let startsUnit: Bool
        switch codec {
        case .h264:
            let type = first & 0x1f
            isSlice = type == 1 || type == 5
            // first_mb_in_slice == 0 (ue(v) "1") marks a new picture.
            startsUnit = type == 9 || (auHasSlice && ([6, 7, 8].contains(type)
                || (isSlice && nal[nal.startIndex + 1] & 0x80 != 0)))
        case .hevc:
            guard nal.count >= 3 else { return }
            let type = (first >> 1) & 0x3f
            isSlice = type < 32
            // first_slice_segment_in_pic_flag.
            startsUnit = type == 35 || (auHasSlice && ([32, 33, 34, 39].contains(type)
                || (isSlice && nal[nal.startIndex + 2] & 0x80 != 0)))
        }
        if startsUnit { closeAccessUnit() }
        if auStart == nil { auStart = offset }
        auNALs.append(nal)
        if isSlice { auHasSlice = true }
    }

    private func closeAccessUnit() {
        defer { auNALs.removeAll(); auStart = nil; auHasSlice = false }
        guard auHasSlice, let start = auStart else { return }
        var pts: Int64
        var dts: Int64
        if let index = timings.lastIndex(where: { $0.offset <= start }), !timings[index].used {
            timings[index].used = true
            pts = timings[index].pts
            dts = timings[index].dts
            timings.removeFirst(index)
        } else if let lastDTS {
            // Two frames starting in one PES: the second has no timestamp.
            dts = lastDTS + lastFrameDuration
            pts = dts
        } else {
            return
        }
        if let lastDTS, dts > lastDTS { lastFrameDuration = dts - lastDTS }
        lastDTS = dts
        videoAccessUnit(auNALs, pts: pts, dts: dts)
    }

    // MARK: - Transport packets

    private func packet(_ b: [UInt8], _ i: Int) {
        let pusi = b[i + 1] & 0x40 != 0
        let pid = Int(b[i + 1] & 0x1f) << 8 | Int(b[i + 2])
        let afc = (b[i + 3] >> 4) & 0x3
        var start = i + 4
        if afc & 0x2 != 0 { start += 1 + Int(b[i + 4]) }
        guard afc & 0x1 != 0, start < i + 188 else { return }
        let payload = b[start..<(i + 188)]

        if pid == 0 {
            parsePAT(Array(payload), pusi: pusi)
        } else if pid == pmtPID {
            parsePMT(Array(payload), pusi: pusi)
        } else if pid == videoPID || pid == audioPID {
            if pusi {
                if let previous = pes[pid], !previous.isEmpty { handlePES(pid: pid, data: [UInt8](previous)) }
                pes[pid] = Data(payload)
            } else {
                pes[pid]?.append(contentsOf: payload)
            }
        }
    }

    private func section(_ p: [UInt8], pusi: Bool) -> ArraySlice<UInt8>? {
        guard pusi, !p.isEmpty else { return nil }
        let start = 1 + Int(p[0])
        guard start + 3 <= p.count else { return nil }
        let length = Int(p[start + 1] & 0x0f) << 8 | Int(p[start + 2])
        let end = min(p.count, start + 3 + length - 4)
        guard end > start else { return nil }
        return p[start..<end]
    }

    private func parsePAT(_ p: [UInt8], pusi: Bool) {
        guard let s = section(p, pusi: pusi) else { return }
        var i = s.startIndex + 8
        while i + 4 <= s.endIndex {
            let program = Int(s[i]) << 8 | Int(s[i + 1])
            if program != 0 {
                pmtPID = Int(s[i + 2] & 0x1f) << 8 | Int(s[i + 3])
                return
            }
            i += 4
        }
    }

    private func parsePMT(_ p: [UInt8], pusi: Bool) {
        guard let s = section(p, pusi: pusi), s.count >= 12 else { return }
        let base = s.startIndex
        let programInfoLength = Int(s[base + 10] & 0x0f) << 8 | Int(s[base + 11])
        var i = base + 12 + programInfoLength
        while i + 5 <= s.endIndex {
            let type = Int(s[i])
            let pid = Int(s[i + 1] & 0x1f) << 8 | Int(s[i + 2])
            let infoLength = Int(s[i + 3] & 0x0f) << 8 | Int(s[i + 4])
            switch type {
            case 0x1b where videoPID == nil:
                videoPID = pid; videoCodec = .h264
            case 0x24 where videoPID == nil:
                videoPID = pid; videoCodec = .hevc
            case 0x0f where audioPID == nil:
                audioPID = pid
            case 0x15, 0x86:
                break // ID3 timed metadata, SCTE-35
            default:
                // The PMT repeats every segment: our own streams land here
                // on the second pass.
                if pid != videoPID && pid != audioPID { skippedStreamTypes.insert(type) }
            }
            i += 5 + infoLength
        }
    }

    // MARK: - PES

    private func handlePES(pid: Int, data b: [UInt8]) {
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return }
        let flags = b[7]
        let headerLength = Int(b[8])
        let payloadStart = 9 + headerLength
        guard payloadStart <= b.count else { return }
        var pts: Int64?
        var dts: Int64?
        if flags & 0x80 != 0, b.count >= 14 { pts = unwrap(pid: pid, timestamp(b, 9)) }
        if flags & 0x40 != 0, b.count >= 19 { dts = unwrap(pid: pid, timestamp(b, 14)) }
        let payload = Array(b[payloadStart...])

        if pid == videoPID {
            videoPES(payload, pts: pts, dts: dts)
        } else if pid == audioPID {
            adts(payload, pts: pts)
        }
    }

    private func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        var v = Int64(b[i] >> 1 & 0x07) << 30
        v |= Int64(b[i + 1]) << 22
        v |= Int64(b[i + 2] >> 1) << 15
        v |= Int64(b[i + 3]) << 7
        v |= Int64(b[i + 4] >> 1)
        return v
    }

    /// The 33-bit clock wraps every ~26.5 hours; keeps timestamps increasing.
    private func unwrap(pid: Int, _ value: Int64) -> Int64 {
        let wrap: Int64 = 1 << 33
        guard let last = lastTimestamp[pid] else {
            lastTimestamp[pid] = value
            return value
        }
        var v = value + (last / wrap) * wrap
        if v < last - wrap / 2 { v += wrap } else if v > last + wrap / 2 { v -= wrap }
        lastTimestamp[pid] = v
        return v
    }

    // MARK: - Video

    private func videoAccessUnit(_ nals: [ArraySlice<UInt8>], pts: Int64, dts: Int64) {
        guard let codec = videoCodec else { return }
        var out = Data()
        var keyframe = false
        for nal in nals where !nal.isEmpty {
            switch codec {
            case .h264:
                let type = nal[nal.startIndex] & 0x1f
                switch type {
                case 7: if h264SPS == nil { h264SPS = Data(nal) }; continue
                case 8: if h264PPS == nil { h264PPS = Data(nal) }; continue
                case 9, 12: continue
                case 5: keyframe = true
                default: break
                }
            case .hevc:
                let type = (nal[nal.startIndex] >> 1) & 0x3f
                switch type {
                case 32: if hevcVPS == nil { hevcVPS = Data(nal) }; continue
                case 33: if hevcSPS == nil { hevcSPS = Data(nal) }; continue
                case 34: if hevcPPS == nil { hevcPPS = Data(nal) }; continue
                case 35, 38: continue
                case 16...23: keyframe = true
                default: break
                }
            }
            var length = UInt32(nal.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            out.append(contentsOf: nal)
        }
        if parameterSets.isEmpty {
            switch codec {
            case .h264:
                if let sps = h264SPS, let pps = h264PPS { parameterSets = [sps, pps] }
            case .hevc:
                if let vps = hevcVPS, let sps = hevcSPS, let pps = hevcPPS { parameterSets = [vps, sps, pps] }
            }
        }
        // Frames before the first parameter sets can't be decoded.
        guard !out.isEmpty, !parameterSets.isEmpty else { return }
        video.append(VideoSample(data: out, pts: pts, dts: dts, isKeyframe: keyframe))
    }

    // MARK: - Audio

    private func adts(_ payload: [UInt8], pts: Int64?) {
        let bytes = [UInt8](audioRemainder) + payload
        var framePTS: Int64
        if audioRemainder.isEmpty, let pts {
            framePTS = pts
        } else {
            framePTS = audioRemainderPTS ?? pts ?? 0
        }
        audioRemainder.removeAll()
        audioRemainderPTS = nil

        var i = 0
        while i + 7 <= bytes.count {
            guard bytes[i] == 0xff, bytes[i + 1] & 0xf6 == 0xf0 else { i += 1; continue }
            let protectionAbsent = bytes[i + 1] & 0x01 != 0
            let headerLength = protectionAbsent ? 7 : 9
            let frameLength = Int(bytes[i + 3] & 0x03) << 11 | Int(bytes[i + 4]) << 3 | Int(bytes[i + 5] >> 5)
            guard frameLength > headerLength else { i += 1; continue }
            if i + frameLength > bytes.count {
                // Frame continues in the next PES.
                audioRemainder = Data(bytes[i...])
                audioRemainderPTS = framePTS
                return
            }
            let config = AACConfig(objectType: Int(bytes[i + 2] >> 6) + 1,
                                   sampleRateIndex: Int(bytes[i + 2] >> 2 & 0x0f),
                                   channels: Int(bytes[i + 2] & 0x01) << 2 | Int(bytes[i + 3] >> 6))
            if aacConfig == nil { aacConfig = config }
            audio.append(AudioSample(data: Data(bytes[(i + headerLength)..<(i + frameLength)]), pts: framePTS))
            framePTS += Int64(1024) * Int64(Self.timescale) / Int64(config.sampleRate)
            i += frameLength
        }
        // A PES can end inside a frame's 7-byte header; dropping those few
        // bytes lost the whole frame (2.5% of bipbop's audio, which then
        // ended 44s before the video).
        if i < bytes.count {
            audioRemainder = Data(bytes[i...])
            audioRemainderPTS = framePTS
        }
    }

    private func feedPackedAudio(_ b: [UInt8]) {
        var start = 0
        // ID3v2 header: "ID3", version(2), flags(1), syncsafe size(4).
        if b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {
            let size = Int(b[6] & 0x7f) << 21 | Int(b[7] & 0x7f) << 14 | Int(b[8] & 0x7f) << 7 | Int(b[9] & 0x7f)
            start = 10 + size
        }
        guard start < b.count else { return }
        let before = audio.count
        adts(Array(b[start...]), pts: audioRemainder.isEmpty ? packedAudioNextPTS : nil)
        if let last = audio.last, audio.count > before, let config = aacConfig {
            packedAudioNextPTS = last.pts + Int64(1024) * Int64(Self.timescale) / Int64(config.sampleRate)
        }
    }
}
