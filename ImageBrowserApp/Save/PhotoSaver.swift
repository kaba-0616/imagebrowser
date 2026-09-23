import UIKit
import Photos

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

    func save(_ images: [PageImage]) async {
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

            switch await saveOne(image) {
            case .success:
                succeeded += 1
                savedImageIDs.insert(image.id)
                appendLog("OK: \(name)")
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

    func reset() {
        state = .idle
    }

    private func appendLog(_ text: String, isError: Bool = false) {
        log.append(LogEntry(time: Date(), text: text, isError: isError))
        // Persisted after every line so a crash or force-quit mid-save still
        // leaves a trace readable on the next launch.
        PersistentLog.write(log)
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
        do {
            return try await fetch(image.url, isSVG: image.isSVG)
        } catch {
            guard let rendered = image.renderedURL else { throw error }
            appendLog("原寸URL失敗、ページ表示分にフォールバック: \(image.url.lastPathComponent)")
            return try await fetch(rendered, isSVG: image.isSVG)
        }
    }

    private func fetch(_ url: URL, isSVG: Bool) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SaveError.httpError(http.statusCode)
        }
        if !isSVG, UIImage(data: data) == nil { throw SaveError.decodeFailed }
        return data
    }

    private func addToLibrary(data: Data, fileExtension: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "ImageBrowser-\(UUID().uuidString).\(fileExtension)"
            request.addResource(with: .photo, data: data, options: options)
        }
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
