// ストア用スクリーンショットのデモページに置く動画・音声を作る(2026-11-04)。
// 写るものはすべてここで描いたもので、他人の著作物を含まない。
// usage: swift tools/demo/gen_demo_media.swift <出力フォルダ>
//   → sunset.mp4 / night.mp4 / sakura.mp4(各10秒 1280x720)と同名の .jpg(ポスター)、voice.m4a
import AVFoundation
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let W = 1280, H = 720, fps = 30, seconds = 10

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ c: CGContext, _ top: UInt32, _ bottom: UInt32, _ y0: CGFloat, _ y1: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    c.saveGState()
    c.clip(to: CGRect(x: 0, y: min(y0, y1), width: CGFloat(W), height: abs(y1 - y0)))
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    c.restoreGState()
}

/// Deterministic pseudo-random numbers so every frame places the stars the same.
struct Rand { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 33) / CGFloat(1 << 31) } }

// Coordinates: CoreGraphics origin is bottom-left.
let scenes: [(String, (CGContext, CGFloat) -> Void)] = [
    ("sunset", { c, t in
        gradient(c, 0x5B2A86, 0xFF8A5B, CGFloat(H), CGFloat(H) * 0.38)
        let sunY = CGFloat(H) * (0.62 - 0.18 * t)
        c.setFillColor(color(0xFFD27A)); c.fillEllipse(in: CGRect(x: 560, y: sunY - 80, width: 160, height: 160))
        gradient(c, 0x2B3A7A, 0x10173F, CGFloat(H) * 0.38, 0)
        c.setFillColor(color(0x10173F)); c.fill(CGRect(x: 0, y: 0, width: W, height: Int(Double(H) * 0.30)))
        for i in 0..<9 {
            let y = CGFloat(H) * 0.36 - CGFloat(i) * 26
            let shift = sin(t * 6.28 * 2 + CGFloat(i)) * 40
            c.setFillColor(color(0xFFD27A, 0.55 - CGFloat(i) * 0.05))
            c.fill(CGRect(x: 600 + shift - CGFloat(i) * 6, y: y, width: 80 + CGFloat(i) * 12, height: 6))
        }
    }),
    ("night", { c, t in
        gradient(c, 0x0B1033, 0x283C86, CGFloat(H), 0)
        var r = Rand(s: 7)
        for _ in 0..<160 {
            let x = r.next() * CGFloat(W), y = r.next() * CGFloat(H), s = 1.5 + r.next() * 3
            let tw = 0.5 + 0.5 * sin(t * 12 + x)
            c.setFillColor(color(0xFFFFFF, 0.4 + 0.6 * tw)); c.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
        }
        let p = (t * 2).truncatingRemainder(dividingBy: 1)
        let sx = 1100 - p * 700, sy = 650 - p * 300
        c.setStrokeColor(color(0xFFFFFF, 0.8 * (1 - p))); c.setLineWidth(4); c.setLineCap(.round)
        c.move(to: CGPoint(x: sx, y: sy)); c.addLine(to: CGPoint(x: sx + 140, y: sy + 60)); c.strokePath()
        c.setFillColor(color(0x0A0D24))
        c.move(to: CGPoint(x: 0, y: 0)); c.addLine(to: CGPoint(x: 0, y: 150)); c.addLine(to: CGPoint(x: 300, y: 230))
        c.addLine(to: CGPoint(x: 620, y: 120)); c.addLine(to: CGPoint(x: 950, y: 260)); c.addLine(to: CGPoint(x: 1280, y: 140))
        c.addLine(to: CGPoint(x: 1280, y: 0)); c.fillPath()
    }),
    ("sakura", { c, t in
        gradient(c, 0x8FD3FF, 0xE8F7FF, CGFloat(H), CGFloat(H) * 0.3)
        c.setFillColor(color(0x7BC67E)); c.fillEllipse(in: CGRect(x: -200, y: -420, width: 1700, height: 700))
        c.setFillColor(color(0x5A3A2A)); c.fill(CGRect(x: 280, y: 180, width: 40, height: 220))
        c.setFillColor(color(0xFFB7CF)); c.fillEllipse(in: CGRect(x: 120, y: 330, width: 360, height: 280))
        c.setFillColor(color(0xFFCADB)); c.fillEllipse(in: CGRect(x: 200, y: 400, width: 260, height: 220))
        var r = Rand(s: 3)
        for _ in 0..<70 {
            let x0 = r.next() * CGFloat(W), sp = 0.5 + r.next(), ph = r.next()
            let y = CGFloat(H) - ((t * sp + ph).truncatingRemainder(dividingBy: 1)) * CGFloat(H) * 1.1
            let x = x0 + sin(t * 9 + ph * 6) * 30
            c.setFillColor(color(0xFF8FB4, 0.85)); c.fillEllipse(in: CGRect(x: x, y: y, width: 14, height: 9))
        }
    }),
]

func pixelBuffer(_ pool: CVPixelBufferPool, draw: (CGContext) -> Void) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    draw(ctx)
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

for (name, draw) in scenes {
    let url = out.appendingPathComponent(name + ".mp4")
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000]])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
    writer.add(input)
    writer.startWriting(); writer.startSession(atSourceTime: .zero)
    let frames = fps * seconds
    for f in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        let t = CGFloat(f) / CGFloat(frames)
        adaptor.append(pixelBuffer(adaptor.pixelBufferPool!) { draw($0, t) }, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    print(name, writer.status == .completed ? "ok" : "FAIL \(String(describing: writer.error))")

    // Poster: the frame at 30%.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    draw(g.cgContext, 0.3)
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: out.appendingPathComponent(name + ".jpg"))
}

// voice.m4a: 20 seconds of a soft chord progression (sine tones with a slow envelope).
let audioURL = out.appendingPathComponent("voice.m4a")
try? FileManager.default.removeItem(at: audioURL)
let rate = 44100.0
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
let file = try! AVAudioFile(forWriting: audioURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                              AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
let chords: [[Double]] = [[261.6, 329.6, 392.0], [220.0, 261.6, 329.6], [174.6, 220.0, 261.6], [196.0, 246.9, 293.7]]
let total = Int(rate * 20)
let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
buf.frameLength = AVAudioFrameCount(total)
let samples = buf.floatChannelData![0]
for i in 0..<total {
    let time = Double(i) / rate
    let chord = chords[Int(time / 5) % chords.count]
    let local = time.truncatingRemainder(dividingBy: 5)
    let env = min(1, local / 0.4) * min(1, (5 - local) / 0.6)
    samples[i] = Float(chord.reduce(0) { $0 + sin(2 * .pi * $1 * time) } / 3 * 0.35 * env)
}
try! file.write(from: buf)
// Close explicitly: the process exits before a global would be released, and
// an unclosed AVAudioFile leaves an .m4a without its moov box (unplayable).
file.close()
print("voice ok")
