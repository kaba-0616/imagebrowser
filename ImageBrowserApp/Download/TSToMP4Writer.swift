import Foundation
import AVFoundation
import CoreMedia

/// Writes TSDemuxer's samples into an MP4 (or M4A for audio only) with
/// AVAssetWriter in passthrough mode: the compressed frames go in as they
/// are, so a 1-hour stream is written in seconds and loses no quality.
///
/// Fed one segment at a time (`append`), so memory holds one segment, not
/// the whole video.
final class TSToMP4Writer {

    enum WriterError: LocalizedError {
        case noMedia
        case badFormat(String)
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .noMedia: return "動画・音声のデータが見つかりませんでした"
            case .badFormat(let detail): return "対応していない形式です(\(detail))"
            case .writer(let detail): return "MP4への書き出しに失敗しました(\(detail))"
            }
        }
    }

    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?
    /// Subtracted from every timestamp so the file starts at 0.
    private var base: Int64?
    /// See `start`.
    private var dtsShift: Int64 = 0
    /// Video frames are held back one: a frame's duration is only known
    /// once the next frame's DTS arrives.
    private var pendingVideo: TSDemuxer.VideoSample?
    private var lastVideoDuration: Int64 = 3000
    private var videoQueue: [CMSampleBuffer] = []
    private var audioQueue: [CMSampleBuffer] = []
    private(set) var videoFrames = 0
    private(set) var audioFrames = 0

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Samples of one segment from `demuxer`.
    func append(_ samples: (video: [TSDemuxer.VideoSample], audio: [TSDemuxer.AudioSample]), from demuxer: TSDemuxer) throws {
        if writer == nil {
            guard !samples.video.isEmpty || !samples.audio.isEmpty else { return }
            try start(demuxer: demuxer, first: samples)
        }
        guard let base else { return }
        for sample in samples.video {
            if let previous = pendingVideo {
                let duration = sample.dts - previous.dts
                if duration > 0 { lastVideoDuration = duration }
                try enqueueVideo(previous, duration: lastVideoDuration, base: base)
            }
            pendingVideo = sample
        }
        let audioDuration = audioFormat.map { Int64(1024) * Int64(TSDemuxer.timescale) / Int64(sampleRate(of: $0)) } ?? 0
        for sample in samples.audio {
            try enqueueAudio(sample, duration: audioDuration, base: base)
        }
        try drain(final: false)
    }

    func finish() async throws {
        guard let writer else { throw WriterError.noMedia }
        if let pendingVideo, let base {
            try enqueueVideo(pendingVideo, duration: lastVideoDuration, base: base)
            self.pendingVideo = nil
        }
        try drain(final: true)
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw WriterError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    /// Hands queued buffers to whichever input takes them. AVAssetWriter
    /// interleaves on its own terms: it can refuse video while audio sits
    /// slightly *ahead* of it (seen with Apple's bipbop stream: video stuck
    /// at 2.06s, audio at 2.09s), so feeding strictly in time order
    /// deadlocked. When one track's queue runs dry and the other input is
    /// held back, the rest waits for the next segment's samples.
    private func drain(final: Bool) throws {
        var stalledSince: Date?
        while !videoQueue.isEmpty || !audioQueue.isEmpty {
            if writer?.status == .failed {
                throw WriterError.writer(failure("failed"))
            }
            var progressed = false
            if let input = videoInput, !videoQueue.isEmpty, input.isReadyForMoreMediaData {
                guard input.append(videoQueue.removeFirst()) else { throw WriterError.writer(failure("append video")) }
                videoFrames += 1
                progressed = true
            }
            if let input = audioInput, !audioQueue.isEmpty, input.isReadyForMoreMediaData {
                guard input.append(audioQueue.removeFirst()) else { throw WriterError.writer(failure("append audio")) }
                audioFrames += 1
                progressed = true
            }
            if progressed { stalledSince = nil; continue }
            if final {
                // Nothing more is coming for an empty track: finishing it
                // releases the writer's wait on it.
                if videoQueue.isEmpty { videoInput?.markAsFinished() }
                if audioQueue.isEmpty { audioInput?.markAsFinished() }
            } else if videoQueue.isEmpty || audioQueue.isEmpty {
                return
            }
            let since = stalledSince ?? Date()
            stalledSince = since
            if Date().timeIntervalSince(since) > 10 {
                throw WriterError.writer("書き込み待ちのタイムアウト 映像\(videoFrames)(残り\(videoQueue.count)) 音声\(audioFrames)(残り\(audioQueue.count))")
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    func cancel() {
        writer?.cancelWriting()
    }

    // MARK: -

    private func start(demuxer: TSDemuxer, first: (video: [TSDemuxer.VideoSample], audio: [TSDemuxer.AudioSample])) throws {
        if let codec = demuxer.videoCodec, !demuxer.parameterSets.isEmpty {
            videoFormat = try Self.videoFormat(codec: codec, parameterSets: demuxer.parameterSets)
        }
        if let config = demuxer.aacConfig {
            audioFormat = try Self.audioFormat(config)
        }
        guard videoFormat != nil || audioFormat != nil else { throw WriterError.noMedia }

        try? FileManager.default.removeItem(at: outputURL)
        let fileType: AVFileType = videoFormat == nil ? .m4a : .mp4
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw WriterError.writer(error.localizedDescription)
        }
        if let videoFormat {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw WriterError.writer("映像トラックを追加できません") }
            writer.add(input)
            videoInput = input
        }
        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw WriterError.writer("音声トラックを追加できません") }
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else {
            throw WriterError.writer(writer.error?.localizedDescription ?? "startWriting")
        }
        // TS lets a B-frame's presentation time come before its decode time
        // (Apple's bipbop: PTS 903000 / DTS 906000); MP4 doesn't, and
        // AVAssetWriter fails with -16364. Decode times move earlier by the
        // largest such gap -- presentation times, and so A/V sync, stay as they are.
        dtsShift = max(0, first.video.map { $0.dts - $0.pts }.max() ?? 0)
        let starts = (videoFormat == nil ? [] : first.video.map { $0.dts - dtsShift }) + (audioFormat == nil ? [] : first.audio.map(\.pts))
        base = starts.min() ?? 0
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
    }

    /// The writer's error with its underlying cause -- localizedDescription
    /// alone is just "The operation could not be completed".
    private func failure(_ what: String) -> String {
        guard let error = writer?.error as NSError? else { return what }
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " <- \($0.domain) \($0.code)" } ?? ""
        return "\(what) \(error.domain) \(error.code)\(underlying) 映像\(videoFrames) 音声\(audioFrames)"
    }

    private func enqueueVideo(_ sample: TSDemuxer.VideoSample, duration: Int64, base: Int64) throws {
        guard let format = videoFormat else { return }
        let timing = CMSampleTimingInfo(duration: Self.time(duration),
                                        presentationTimeStamp: Self.time(max(0, sample.pts - base)),
                                        // A later, larger gap than the first segment's: clamped.
                                        decodeTimeStamp: Self.time(max(0, min(sample.dts - dtsShift, sample.pts) - base)))
        videoQueue.append(try Self.sampleBuffer(sample.data, format: format, timing: timing, keyframe: sample.isKeyframe))
    }

    private func enqueueAudio(_ sample: TSDemuxer.AudioSample, duration: Int64, base: Int64) throws {
        guard let format = audioFormat else { return }
        // Audio before the first video frame would get a negative time.
        guard sample.pts >= base else { return }
        let timing = CMSampleTimingInfo(duration: Self.time(duration),
                                        presentationTimeStamp: Self.time(sample.pts - base),
                                        decodeTimeStamp: .invalid)
        audioQueue.append(try Self.sampleBuffer(sample.data, format: format, timing: timing, keyframe: true))
    }

    private func sampleRate(of format: CMFormatDescription) -> Int {
        Int(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate ?? 44100)
    }

    static func time(_ value: Int64) -> CMTime {
        CMTime(value: value, timescale: TSDemuxer.timescale)
    }

    static func videoFormat(codec: TSDemuxer.VideoCodec, parameterSets: [Data]) throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status: OSStatus = parameterSets.withPointers { pointers, sizes in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw WriterError.badFormat("映像のパラメータ \(status)") }
        return format
    }

    static func audioFormat(_ config: TSDemuxer.AACConfig) throws -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(config.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, config.channels)), mBitsPerChannel: 0, mReserved: 0)
        let cookie = esdsCookie(config.audioSpecificConfig)
        var format: CMFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw WriterError.badFormat("音声のパラメータ \(status)") }
        return format
    }

    /// CoreAudio's AAC magic cookie is an MPEG-4 ES_Descriptor, not the
    /// bare 2-byte AudioSpecificConfig: given the latter, AVAssetWriter
    /// wrote a 14-byte esds and AVFoundation hid the audio track when
    /// reading the file back (seen on Mux's Big Buck Bunny stream).
    static func esdsCookie(_ asc: Data) -> Data {
        let decoderSpecific: [UInt8] = [0x05, UInt8(asc.count)] + asc
        // objectTypeIndication 0x40 = MPEG-4 audio, streamType 5 (audio) << 2 | 1.
        let decoderConfig: [UInt8] = [0x04, UInt8(13 + decoderSpecific.count), 0x40, 0x15,
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + decoderSpecific
        let slConfig: [UInt8] = [0x06, 0x01, 0x02]
        let body: [UInt8] = [0, 0, 0] + decoderConfig + slConfig
        return Data([0x03, UInt8(body.count)] + body)
    }

    static func sampleBuffer(_ data: Data, format: CMFormatDescription, timing: CMSampleTimingInfo, keyframe: Bool) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw WriterError.writer("block \(status)") }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw WriterError.writer("block copy \(status)") }

        var timing = timing
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw WriterError.writer("sample \(status)") }
        if !keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

private extension Array where Element == Data {
    /// Stable pointers to every element's bytes for the duration of `body`.
    func withPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = map { data -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: p, count: data.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, map(\.count))
    }
}
