import Foundation
import AVFoundation
import LameMP3

/// Audio-only output: M4A (the stream's AAC as is) or MP3 (re-encoded with
/// LAME -- iOS can read MP3 but has no encoder for it).
enum AudioConverter {

    enum ConvertError: LocalizedError {
        case noAudio
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "音声が入っていません"
            case .failed(let detail): return "音声の書き出しに失敗しました(\(detail))"
            }
        }
    }

    /// The audio track of `source` as M4A, without re-encoding.
    static func m4a(from source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw ConvertError.noAudio }
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        if let track = try await asset.loadTracks(withMediaType: .audio).first,
           let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        try? FileManager.default.removeItem(at: output)
        // Passthrough keeps AAC as is; anything else (e.g. MP3 inside MP4)
        // goes through Apple's AAC encoder.
        let preset = AVAssetExportSession.exportPresets(compatibleWith: composition).contains(AVAssetExportPresetPassthrough)
            ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ConvertError.failed("書き出しの準備ができません")
        }
        session.outputURL = output
        session.outputFileType = .m4a
        await session.export()
        if session.status != .completed {
            // Passthrough refuses some codecs only at export time.
            if preset == AVAssetExportPresetPassthrough,
               let retry = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) {
                retry.outputURL = output
                retry.outputFileType = .m4a
                try? FileManager.default.removeItem(at: output)
                await retry.export()
                if retry.status == .completed { return }
            }
            throw ConvertError.failed(session.error?.localizedDescription ?? "export \(session.status.rawValue)")
        }
    }

    /// The audio of `source` decoded and re-encoded as MP3. `progress` gets 0...1.
    static func mp3(from source: URL, to output: URL, bitrate: Int32 = 192,
                    progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConvertError.noAudio }
        let duration = try await asset.load(.duration).seconds
        let description = try await track.load(.formatDescriptions).first
        let sourceRate = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 44100
        // MP3 only has 32/44.1/48 kHz (and halves); the reader resamples.
        let sampleRate = [48000.0, 44100.0, 32000.0, 24000.0, 22050.0, 16000.0].min { abs($0 - sourceRate) < abs($1 - sourceRate) } ?? 44100
        let sourceChannels = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
        let channels = min(2, max(1, Int(sourceChannels)))

        let reader = try AVAssetReader(asset: asset)
        let pcmOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        reader.add(pcmOutput)
        guard reader.startReading() else { throw ConvertError.failed(reader.error?.localizedDescription ?? "reader") }

        guard let lame = lame_init() else { throw ConvertError.failed("LAMEの初期化") }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_brate(lame, bitrate)
        lame_set_quality(lame, 2)
        if channels == 1 { lame_set_mode(lame, MONO) }
        guard lame_init_params(lame) >= 0 else { throw ConvertError.failed("LAMEの設定") }

        try? FileManager.default.removeItem(at: output)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var mp3 = [UInt8](repeating: 0, count: 1 << 18)
        var framesDone = 0.0

        while let buffer = pcmOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            let frames = Int32(length / (2 * channels))
            let needed = Int(1.25 * Double(frames) + 7200)
            if mp3.count < needed { mp3 = [UInt8](repeating: 0, count: needed) }
            let written = pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { pcm -> Int32 in
                if channels == 2 {
                    return lame_encode_buffer_interleaved(lame, pcm, frames, &mp3, Int32(mp3.count))
                }
                return lame_encode_buffer(lame, pcm, pcm, frames, &mp3, Int32(mp3.count))
            }
            guard written >= 0 else { throw ConvertError.failed("LAME \(written)") }
            try handle.write(contentsOf: Data(mp3[0..<Int(written)]))
            framesDone += Double(frames)
            if duration > 0 { progress(min(1, framesDone / sampleRate / duration)) }
        }
        guard reader.status == .completed else { throw ConvertError.failed(reader.error?.localizedDescription ?? "reader \(reader.status.rawValue)") }
        let tail = lame_encode_flush(lame, &mp3, Int32(mp3.count))
        if tail > 0 { try handle.write(contentsOf: Data(mp3[0..<Int(tail)])) }
    }
}
