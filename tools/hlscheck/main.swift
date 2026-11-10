// Mac 上で HLSDownloader を実際の配信に通す検証用(アプリには入らない)。
// usage: hlscheck <m3u8 URL> <出力パス(拡張子は自動)> [variant index]
import Foundation
import AVFoundation

enum AppLog { static func log(_ s: String, isError: Bool = false) { print("[log] \(s)") } }

func verify(_ url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    print("出力: \(url.lastPathComponent) \((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) / 1024)KB 長さ \(String(format: "%.2f", duration.seconds))秒")
    for type in [AVMediaType.video, .audio] {
        for track in try await asset.loadTracks(withMediaType: type) {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = type == .video
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                : [AVFormatIDKey: kAudioFormatLinearPCM]
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(out)
            reader.startReading()
            var n = 0; var first: Double?; var last = 0.0
            while let sb = out.copyNextSampleBuffer() {
                n += CMSampleBufferGetNumSamples(sb)
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                if first == nil { first = t }; last = t
            }
            let size = try await type == .video ? "\(track.load(.naturalSize))" : ""
            print("  \(type.rawValue): デコード\(n)サンプル \(String(format: "%.2f〜%.2f秒", first ?? -1, last)) \(size) 状態\(reader.status.rawValue) \(reader.error?.localizedDescription ?? "")")
        }
    }
}

@main struct Main { static func main() async {
let args = CommandLine.arguments
let downloader = HLSDownloader(context: RequestContext())
let started = Date()
do {
    let out = try await downloader.download(URL(string: args[1])!, quality: args.count > 3 ? Int(args[3]) : nil,
                                            to: URL(fileURLWithPath: args[2])) { p in
        if p.done == p.total || p.done % 20 == 0 { print("  進捗 \(p.done)/\(p.total) \(p.bytes / 1024)KB") }
    }
    print("所要 \(Int(Date().timeIntervalSince(started) * 1000))ms")
    try await verify(out)
} catch {
    print("失敗: \(error.localizedDescription) \(error)")
}
}}
