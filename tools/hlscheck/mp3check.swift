// AudioConverter(アプリと同じソース)で、動画の音声を MP3 / M4A に書き出して確かめる。
// usage: mp3check <入力の動画/音声> <出力フォルダ>
import Foundation
import AVFoundation

enum AppLog { static func log(_ s: String, isError: Bool = false) { print("[log] \(s)") } }

@main struct Main { static func main() async {
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let folder = URL(fileURLWithPath: CommandLine.arguments[2])
    for ext in ["mp3", "m4a"] {
        let out = folder.appendingPathComponent("out.\(ext)")
        let started = Date()
        do {
            if ext == "mp3" {
                try await AudioConverter.mp3(from: input, to: out) { _ in }
            } else {
                try await AudioConverter.m4a(from: input, to: out)
            }
            let asset = AVURLAsset(url: out)
            let duration = try await asset.load(.duration).seconds
            let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0) / 1024
            print("\(ext): \(size)KB 長さ\(String(format: "%.2f", duration))秒 \(Int(Date().timeIntervalSince(started) * 1000))ms")
        } catch {
            print("\(ext) 失敗: \(error.localizedDescription)")
        }
    }
}}
