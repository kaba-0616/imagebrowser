// 書き出した MP4 の映像を VideoToolbox で1フレームずつ復号して失敗箇所を探す。
import Foundation
import AVFoundation
import VideoToolbox
@main struct V { static func main() async throws {
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("tracks", try await asset.load(.tracks).map { $0.mediaType.rawValue })
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(out); reader.startReading()
    var session: VTDecompressionSession?
    var n = 0, fails = 0
    while let sb = out.copyNextSampleBuffer(), n < 400 {
        guard CMSampleBufferGetNumSamples(sb) > 0, let fmt = CMSampleBufferGetFormatDescription(sb) else { continue }
        if session == nil {
            let ext = CMFormatDescriptionGetExtensions(fmt) as? [String: Any]
            print("fmt", CMFormatDescriptionGetMediaSubType(fmt), (ext?["SampleDescriptionExtensionAtoms"] as? [String: Any])?.keys as Any)
            print("create", VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session))
        }
        if n < 3, let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0; var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            let b = UnsafeRawPointer(ptr!).assumingMemoryBound(to: UInt8.self)
            var i = 0; var nals: [String] = []
            while i + 4 <= len { let l = Int(b[i])<<24|Int(b[i+1])<<16|Int(b[i+2])<<8|Int(b[i+3]); nals.append("t\(b[i+4]&0x1f):\(l)"); i += 4 + l }
            print("sample\(n) size\(len) end\(i) pts\(CMSampleBufferGetPresentationTimeStamp(sb).seconds) dts\(CMSampleBufferGetDecodeTimeStamp(sb).seconds) nals", nals)
        }
        var flags = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sb, flags: [], infoFlagsOut: &flags) { s, _, _, _, _ in if s != noErr { print("cb err", s) } }
        if st != noErr { fails += 1; if fails < 5 { print("frame \(n) decode \(st)") } }
        n += 1
    }
    print("decoded", n, "fails", fails, "reader", reader.status.rawValue, reader.error as Any)
}}
