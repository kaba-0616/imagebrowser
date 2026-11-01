// SVG を指定ピクセル寸法の PNG に書き出す。
//
// rsvg-convert / inkscape / cairosvg のどれも入っていない環境なので WebKit で描く。
// WebKit を使うのには利点もあって、**ヒラギノがそのまま出る**(cairo 系だと日本語が
// 豆腐や代替書体になる)。
//
//   swift tools/svg2png.swift <input.svg> <output.png> <width> <height>
//
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5,
      let width = Double(args[3]), let height = Double(args[4]) else {
    FileHandle.standardError.write("usage: svg2png <in.svg> <out.png> <width> <height>\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

// 巨大な寸法(5244×2950 など)をそのまま論理ピクセルで描くとビットマップが数十MBに
// なるだけで通る。縮尺をかけると SVG 側の座標とずれるので等倍で描く。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Shot: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let out: URL
    let size: NSSize
    var logicalSize: NSSize = .zero
    init(out: URL, size: NSSize) {
        self.out = out
        self.size = size
        self.logicalSize = NSSize(width: size.width / (NSScreen.main?.backingScaleFactor ?? 2),
                                  height: size.height / (NSScreen.main?.backingScaleFactor ?? 2))
        let config = WKWebViewConfiguration()
        // Retina の Mac では snapshot が 2倍で返る。論理サイズを縮めて描き、
        // 最後に目標ピクセル数へ描き直すことで、画面の倍率に関係なく寸法を合わせる。
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let logical = NSSize(width: size.width / scale, height: size.height / scale)
        web = WKWebView(frame: NSRect(origin: .zero, size: logical), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // **書体の読み込み完了を待つ。** base64 で埋めた 4.6MB の TTF は
        // decode に時間がかかり、固定で 0.6 秒待つ作りでは間に合わず、
        // **エラーも出ないまま明朝で描かれる**(2026-11-01 実測)。
        waitForFonts(webView, tries: 0)
    }

    func waitForFonts(_ webView: WKWebView, tries: Int) {
        webView.evaluateJavaScript("document.fonts.status") { value, _ in
            if (value as? String) == "loaded" || tries > 100 {
                if tries > 100 {
                    FileHandle.standardError.write("警告: 書体の読み込みを待ちきれませんでした\n".data(using: .utf8)!)
                }
                // レイアウトが落ち着くのを待ってから撮る。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.snapshot(webView) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.waitForFonts(webView, tries: tries + 1)
                }
            }
        }
    }

    func snapshot(_ webView: WKWebView) {
        do {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(origin: .zero, size: self.logicalSize)
            webView.takeSnapshot(with: config) { image, error in
                guard let image, error == nil else {
                    FileHandle.standardError.write("snapshot failed: \(error?.localizedDescription ?? "?")\n".data(using: .utf8)!)
                    exit(1)
                }
                let target = NSRect(origin: .zero, size: self.size)
                // **アルファを持たない PNG を書く。** App Store Connect の
                // クリエイティブアセットは「アルファチャンネル・透過を含む画像は
                // 不可」で、RGBA のまま上げると処理が INVALID_ASSET_FILE_FORMAT で
                // 落ちる(2026-11-01 実測)。
                // NSBitmapImageRep に hasAlpha: false を指定すると描画自体が
                // 効かず真っ黒になるので、**不透明な CGContext(noneSkipLast)に
                // 描いてから** NSBitmapImageRep(cgImage:) にする。
                guard let ctx = CGContext(
                        data: nil,
                        width: Int(self.size.width), height: Int(self.size.height),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    FileHandle.standardError.write("bitmap alloc failed\n".data(using: .utf8)!)
                    exit(1)
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(in: target)
                NSGraphicsContext.restoreGraphicsState()
                guard let cg = ctx.makeImage() else {
                    FileHandle.standardError.write("makeImage failed\n".data(using: .utf8)!)
                    exit(1)
                }
                let rep = NSBitmapImageRep(cgImage: cg)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
                    exit(1)
                }
                if let t = tempPath { try? FileManager.default.removeItem(at: t) }
                do { try png.write(to: self.out) } catch {
                    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
                print("\(self.out.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
                exit(0)
            }
        }
    }
}

var tempPath: URL?
let size = NSSize(width: width, height: height)
let shot = Shot(out: output, size: size)
shot.web.frame = NSRect(origin: .zero, size: shot.logicalSize)

// SVG を直接読ませるとスクロールバーや余白が入るので、隙間なく貼った HTML に包む。
let svg = try String(contentsOf: input, encoding: .utf8)
let html = """
<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;padding:0;overflow:hidden;background:transparent}
svg{display:block;width:100vw;height:100vh}</style>
\(svg)
"""
// loadHTMLString はローカルファイルを読めない(SVG の中の <image> が空になる)。
// SVG と同じ階層に一時 HTML を書き、そのディレクトリへの読み取りを許して開く。
//
// **書体だけは相対パスでは読めない。** <image> は読めるのに @font-face の
// url() は file:// 越しで弾かれ、**エラーも出ないまま明朝にフォールバックする**。
// allowFileAccessFromFileURLs / allowUniversalAccessFromFileURLs を立てても
// 変わらず、CTFontManagerRegisterFontsForURL も WKWebView が別プロセスで
// 描くので効かない。**SVG に base64 で埋め込むのが唯一通る方法**
// (2026-11-01 実測。ImageKeeper のストア用 SVG も同じ作り)。
let dir = input.deletingLastPathComponent()
let temp = dir.appendingPathComponent(".svg2png-\(UUID().uuidString).html")
try html.write(to: temp, atomically: true, encoding: .utf8)
tempPath = temp
shot.web.loadFileURL(temp, allowingReadAccessTo: dir)

// 念のための打ち切り。無言で固まるより失敗したほうがいい。
DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    FileHandle.standardError.write("timed out\n".data(using: .utf8)!)
    exit(1)
}
app.run()
