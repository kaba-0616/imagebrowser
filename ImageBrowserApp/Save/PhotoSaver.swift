import UIKit
import Photos
import ImageIO

/// Simplified from ImageSaver's extension-target PhotoSaver: an app-body
/// process can raise the Photos permission prompt directly (only an Action
/// Extension gets killed for that on iOS 26), so there is no "go open the
/// container app first" detour here -- undetermined just asks.
@MainActor
final class PhotoSaver: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case saving(done: Int, total: Int)
        case finished(succeeded: Int, failed: Int, message: String?)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
        let isError: Bool
    }

    @Published private(set) var state: SaveState = .idle
    /// IDs that made it into the photo library; the grid hides these.
    @Published private(set) var savedImageIDs: Set<Int> = []
    /// Human-readable trace of the last save run -- when a save "does not
    /// show up", this is what tells whether it never started, failed to
    /// fetch, failed to decode, or failed to write to the library.
    @Published private(set) var log: [LogEntry] = []

    var isSaving: Bool {
        if case .saving = state { return true }
        return false
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// The page's cookies/Referer/User-Agent, applied to each fetch so a
    /// signed-cookie CDN (mi-muse) doesn't answer 403. Set before saving.
    var requestHeaders = PageRequestHeaders()

    /// `page` / `kind` are only for UsageStats (which site, which way).
    func save(_ images: [PageImage], page: URL? = nil, kind: String = "bulk") async {
        await saveImages(images)
        if case .finished(let succeeded, let failed, _) = state {
            UsageStats.saved(page: page, kind: kind, succeeded: succeeded, failed: failed)
            if succeeded > 0 { ReviewPrompt.recordSuccess() }
        }
    }

    private func saveImages(_ images: [PageImage]) async {
        log.removeAll()

        guard !images.isEmpty else {
            appendLog("保存対象が0件です", isError: true)
            state = .finished(succeeded: 0, failed: 0, message: "画像が選択されていません")
            return
        }

        state = .saving(done: 0, total: images.count)
        appendLog("保存開始: \(images.count)件")

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        appendLog("権限状態(開始時): \(status.description)")

        let authorized: Bool
        if status == .notDetermined {
            let requested = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            appendLog("権限リクエスト結果: \(requested.description)")
            authorized = (requested == .authorized || requested == .limited)
        } else {
            authorized = (status == .authorized || status == .limited)
        }

        guard authorized else {
            appendLog("写真へのアクセスが許可されていないため中止", isError: true)
            state = .finished(
                succeeded: 0,
                failed: images.count,
                message: "写真へのアクセスが許可されていません。\n「設定」→「プライバシーとセキュリティ」→「写真」→「ImageBrowser」で許可してください。"
            )
            return
        }

        var succeeded = 0
        var failed = 0
        var lastError: String?

        // Saved one at a time, in selection order.
        for image in images {
            let name = image.url.lastPathComponent

            lastDateWasFuture = false
            switch await saveOne(image) {
            case .success:
                succeeded += 1
                savedImageIDs.insert(image.id)
                appendLog("OK: \(name)" + (lastDateWasFuture ? " [日時が未来だったので保存時刻にした]" : ""))
            case .failure(let error):
                failed += 1
                lastError = error.localizedDescription
                appendLog("失敗: \(name) — \(error.localizedDescription)", isError: true)
            }

            state = .saving(done: succeeded + failed, total: images.count)
        }

        appendLog("完了: 成功\(succeeded) 失敗\(failed)")
        state = .finished(succeeded: succeeded, failed: failed, message: failed > 0 ? lastError : nil)
    }

    /// Saves a raw UIImage directly -- used for the canvas-snapshot fallback
    /// (see WebViewController.captureCrop) where there's no URL to fetch,
    /// just pixels already in hand.
    func saveRaw(_ image: UIImage) async {
        log.removeAll()
        state = .saving(done: 0, total: 1)
        appendLog("保存開始: スナップショット切り出し 1件")

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        appendLog("権限状態(開始時): \(status.description)")
        let authorized: Bool
        if status == .notDetermined {
            let requested = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            appendLog("権限リクエスト結果: \(requested.description)")
            authorized = (requested == .authorized || requested == .limited)
        } else {
            authorized = (status == .authorized || status == .limited)
        }

        guard authorized else {
            appendLog("写真へのアクセスが許可されていないため中止", isError: true)
            state = .finished(
                succeeded: 0,
                failed: 1,
                message: "写真へのアクセスが許可されていません。\n「設定」→「プライバシーとセキュリティ」→「写真」→「ImageBrowser」で許可してください。"
            )
            return
        }

        guard let data = image.normalizedOrientation().pngData() else {
            appendLog("エンコード失敗", isError: true)
            state = .finished(succeeded: 0, failed: 1, message: "画像の保存に失敗しました")
            return
        }

        do {
            try await addToLibrary(data: data, fileExtension: "png")
            appendLog("完了: 成功1 失敗0")
            state = .finished(succeeded: 1, failed: 0, message: nil)
            ReviewPrompt.recordSuccess()
        } catch {
            appendLog("失敗: \(error.localizedDescription)", isError: true)
            state = .finished(succeeded: 0, failed: 1, message: error.localizedDescription)
        }
    }

    func reset() {
        state = .idle
    }

    private func appendLog(_ text: String, isError: Bool = false) {
        log.append(LogEntry(time: Date(), text: text, isError: isError))
        // Persisted (via AppLog, shared with page-load/extraction events) so
        // a crash or force-quit mid-save still leaves a trace readable on
        // the next launch, alongside what the page was doing at the time.
        AppLog.log(text, isError: isError)
    }

    private func saveOne(_ image: PageImage) async -> Result<Void, Error> {
        do {
            let data = try await fetch(image)

            if image.isSVG {
                let rendered = try SVGRasterizer.rasterize(data: data, maxPixelSize: 2048)
                guard let pngData = rendered.pngData() else { throw SaveError.decodeFailed }
                try await addToLibrary(data: pngData, fileExtension: "png")
            } else {
                let ext = image.url.pathExtension.isEmpty ? "jpg" : image.url.pathExtension
                try await addToLibrary(data: data, fileExtension: ext)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// `url` may be a rewrite asking a resize endpoint for its stored
    /// original. Where that guess is wrong the page's own URL is still good,
    /// so it is tried rather than reporting a failure.
    private func fetch(_ image: PageImage) async throws -> Data {
        // 原寸が別ページにしか書かれていない写真は、保存するこの瞬間に
        // そのページを読む。選ばれた分しか読まないので、5枚なら5回
        // (拡大表示で既に読んだページは読み直さない)。
        if let page = image.originalPageURL {
            let outcome = await OriginalPageResolver.shared.original(forPage: page, thumbnail: image.url)
            if let note = outcome.note { appendLog(note, isError: true) }
            if let original = outcome.original {
                do {
                    return try await fetch(original, isSVG: image.isSVG)
                } catch {
                    appendLog("原寸の取得に失敗、表示されていた方を保存します: \(error.localizedDescription)",
                              isError: true)
                }
            }
        }
        do {
            return try await fetch(image.url, isSVG: image.isSVG)
        } catch {
            guard let rendered = image.renderedURL else { throw error }
            appendLog("原寸URL失敗、ページ表示分にフォールバック: \(image.url.lastPathComponent)")
            return try await fetch(rendered, isSVG: image.isSVG)
        }
    }

    private func fetch(_ url: URL, isSVG: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        for (name, value) in requestHeaders.headers(for: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        appendLog("取得: \(url.absoluteString) — HTTP \(statusCode.map(String.init) ?? "?") \(data.count)bytes")
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SaveError.httpError(http.statusCode)
        }
        if !isSVG, UIImage(data: data) == nil {
            appendLog("デコード失敗: \(url.absoluteString)", isError: true)
            throw SaveError.decodeFailed
        }
        return data
    }

    /// 写真アプリの「日時」は元画像の EXIF で決まる。ストア系サイトの JPEG には
    /// 配信元の時計がずれた未来の DateTimeDigitized が入っていることがあり
    /// (DateTimeOriginal が無いと写真アプリはこれを使う)、そのままだと写真一覧の
    /// 先頭に居座る。未来のときだけ保存した時刻に差し替え、過去の値は撮影日として
    /// 残す。スナップショット保存(自前の PNG)は EXIF が無いので何も起きない。
    private func addToLibrary(data: Data, fileExtension: String) async throws {
        let fixedDate = Self.futureDateFix(for: data)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "ImageBrowser-\(UUID().uuidString).\(fileExtension)"
            request.addResource(with: .photo, data: data, options: options)
            if let fixedDate {
                request.creationDate = fixedDate
            }
        }
        lastDateWasFuture = fixedDate != nil
    }

    private var lastDateWasFuture = false

    private static func futureDateFix(for data: Data) -> Date? {
        let now = Date()
        guard let taken = exifDate(in: data), taken > now else { return nil }
        return now
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func exifDate(in data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        // 写真アプリが見るのと同じ順。original が無ければ digitized、
        // それも無ければ TIFF の DateTime。
        let candidates = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String,
        ]
        for text in candidates.compactMap({ $0 }) {
            if let date = exifDateFormatter.date(from: text) { return date }
        }
        return nil
    }
}

enum SaveError: LocalizedError {
    case decodeFailed
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .decodeFailed: return "画像を読み込めませんでした"
        case .httpError(let code): return "ダウンロード失敗 (HTTP \(code))"
        }
    }
}

extension UIImage {
    /// Redraws into a fresh bitmap so PNG encoding can't get the orientation
    /// wrong. `WKWebView.takeSnapshot(with:)` (used for the Flutter-page
    /// long-press fallback, see WebViewController.captureCrop) can hand back
    /// an image whose `imageOrientation` isn't `.up` even for a plain 2D
    /// crop, and `pngData()` doesn't reliably bake that metadata in --
    /// confirmed on-device as a crop saved upside down. Redrawing through
    /// UIGraphicsImageRenderer always produces a canonical `.up` bitmap
    /// regardless of what the source's orientation flag claims.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private extension PHAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: return "未確認"
        case .restricted: return "制限あり"
        case .denied: return "拒否"
        case .authorized: return "許可"
        case .limited: return "一部のみ許可"
        @unknown default: return "不明"
        }
    }
}
