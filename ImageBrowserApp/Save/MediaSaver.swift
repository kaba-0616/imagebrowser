import Foundation
import Photos
import UIKit

/// One save, start to finish: download (plain file or HLS) -> format
/// (MP4 / MP3 / M4A) -> the user's name -> Photos, or a file handed to the
/// Files export sheet.
@MainActor
final class MediaSaver: ObservableObject {

    enum State: Equatable {
        case idle
        case downloading(fraction: Double?, detail: String)
        case converting(fraction: Double?)
        case saving
        /// `file` is set for the Files destination: the caller presents the
        /// export sheet for it.
        case finished(file: URL?)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var workFolder: URL?

    var isBusy: Bool {
        if let batch, !batch.done { return true }
        switch state {
        case .downloading, .converting, .saving: return true
        default: return false
        }
    }

    struct Request {
        let media: DetectedMedia
        let name: String
        let format: OutputFormat
        let destination: SaveDestination
        /// Index of an HLS master playlist's variant; nil = best.
        let quality: Int?
        let context: RequestContext
    }

    func start(_ request: Request, onSuccess: @escaping () -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(request, onSuccess: onSuccess)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .failed(DownloadError.cancelled.localizedDescription)
        AppLog.log("保存: 中止")
    }

    /// Call once the Files export sheet is done with the file.
    func cleanUp() {
        if let workFolder { try? FileManager.default.removeItem(at: workFolder) }
        workFolder = nil
    }

    private func run(_ request: Request, onSuccess: () -> Void) async {
        cleanUp()
        let folder = Self.newWorkFolder()
        workFolder = folder
        let started = Date()
        // A save that runs past the app going to the background gets the
        // usual extra half-minute or so instead of being frozen at once.
        let background = UIApplication.shared.beginBackgroundTask(withName: "save") {}
        defer { UIApplication.shared.endBackgroundTask(background) }

        do {
            let final = try await makeFile(request, in: folder, name: request.name)
            switch request.destination {
            case .photos:
                state = .saving
                try await Self.saveToPhotos(final)
                AppLog.log("保存完了: 写真へ \(final.lastPathComponent) \(Int(Date().timeIntervalSince(started) * 1000))ms")
                state = .finished(file: nil)
                cleanUp()
            case .files:
                AppLog.log("保存: ファイルへの書き出しを表示 \(final.lastPathComponent)")
                state = .finished(file: final)
            }
            onSuccess()
        } catch is CancellationError {
            state = .failed(DownloadError.cancelled.localizedDescription)
            cleanUp()
        } catch {
            AppLog.log("保存失敗: \(error.localizedDescription) \(error)", isError: true)
            state = .failed(error.localizedDescription)
            cleanUp()
        }
    }

    // MARK: - Several at once

    /// Where a batch is: which item is running and how the earlier ones went.
    struct BatchProgress: Equatable {
        var index = 0
        var total: Int
        var saved = 0
        var failed = 0
        /// Finished files waiting for the Files export sheet.
        var files: [URL] = []
        var done = false
    }

    @Published private(set) var batch: BatchProgress?

    /// Saves `requests` one after another (the user picked them in the
    /// list). Photos ones go in as each finishes; Files ones are collected
    /// and handed over together in `batch.files` for one export sheet. A
    /// failure is logged and skipped so one dead link doesn't stop the rest.
    func startBatch(_ requests: [Request], onSaved: @escaping (Request) -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.runBatch(requests, onSaved: onSaved)
        }
    }

    private func runBatch(_ requests: [Request], onSaved: (Request) -> Void) async {
        cleanUp()
        let folder = Self.newWorkFolder()
        workFolder = folder
        let started = Date()
        let background = UIApplication.shared.beginBackgroundTask(withName: "save-batch") {}
        defer { UIApplication.shared.endBackgroundTask(background) }
        var progress = BatchProgress(total: requests.count)
        batch = progress
        AppLog.log("まとめて保存開始: \(requests.count)件")
        var usedNames: Set<String> = []

        for (index, request) in requests.enumerated() {
            if Task.isCancelled { break }
            progress.index = index
            batch = progress
            // Talk messages sent in the same minute get the same suggested name.
            var name = FileNaming.sanitized(request.name, fallback: request.media.isAudio ? "audio" : "video")
            let base = name
            var n = 2
            while usedNames.contains(name.lowercased()) { name = "\(base)_\(n)"; n += 1 }
            usedNames.insert(name.lowercased())
            do {
                let final = try await makeFile(request, in: folder.appendingPathComponent("\(index)", isDirectory: true), name: name)
                switch request.destination {
                case .photos:
                    state = .saving
                    try await Self.saveToPhotos(final)
                    try? FileManager.default.removeItem(at: final.deletingLastPathComponent())
                case .files:
                    progress.files.append(final)
                }
                progress.saved += 1
                onSaved(request)
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                AppLog.log("まとめて保存: \(index + 1)件目を飛ばした \(WebViewController.shortURL(request.media.url)) \(error.localizedDescription)", isError: true)
                progress.failed += 1
            }
            batch = progress
        }
        progress.done = true
        batch = progress
        AppLog.log("まとめて保存終了: 成功\(progress.saved) 失敗\(progress.failed) ファイルへ\(progress.files.count)件 \(Task.isCancelled ? "(中止)" : "") \(Int(Date().timeIntervalSince(started) * 1000))ms",
                   isError: progress.failed > 0)
        if Task.isCancelled {
            state = .failed(DownloadError.cancelled.localizedDescription)
        } else if progress.saved == 0 {
            state = .failed("保存できませんでした。1件ずつ保存すると理由が表示されます。")
        } else {
            state = .finished(file: progress.files.first)
        }
        if progress.files.isEmpty { cleanUp() }
    }

    // MARK: - One file

    private static func newWorkFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaSave", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Download -> format -> the user's name, inside `folder`. Updates
    /// `state` as it goes; the destination is the caller's.
    private func makeFile(_ request: Request, in folder: URL, name rawName: String) async throws -> URL {
        let media = request.media
        let started = Date()
        AppLog.log("保存開始: \(media.typeLabel) \(WebViewController.shortURL(media.url)) 形式:\(request.format.rawValue) 保存先:\(request.destination.rawValue)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 1. Download.
        state = .downloading(fraction: nil, detail: "準備中")
        let downloaded: URL
        switch media.kind {
        case .hls:
            let downloader = HLSDownloader(context: request.context)
            downloaded = try await downloader.download(media.url, quality: request.quality,
                                                       to: folder.appendingPathComponent("stream")) { progress in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction: progress.total > 0 ? Double(progress.done) / Double(progress.total) : nil,
                                              detail: "\(progress.done)/\(progress.total) ・ \(Self.megabytes(progress.bytes))")
                }
            }
        case .file:
            let result = try await FileDownloader().download(media.url, context: request.context, into: folder) { written, expected in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction: expected > 0 ? Double(written) / Double(expected) : nil,
                                              detail: expected > 0 ? "\(Self.megabytes(written)) / \(Self.megabytes(expected))" : Self.megabytes(written))
                }
            }
            downloaded = result.file
        case .dash:
            throw DownloadError.empty
        }
        try Task.checkCancellation()
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? Int64) ?? 0
        AppLog.log("保存: ダウンロード完了 \(Self.megabytes(size)) \(Int(Date().timeIntervalSince(started) * 1000))ms")

        // 2. Format.
        let name = FileNaming.sanitized(rawName, fallback: media.isAudio ? "audio" : "video")
        let final: URL
        switch request.format {
        case .mp4:
            // Kept in its own container when it isn't MP4/MOV (WebM...).
            let ext = ["mp4", "m4v", "mov"].contains(downloaded.pathExtension.lowercased()) ? downloaded.pathExtension.lowercased() : downloaded.pathExtension
            final = folder.appendingPathComponent(name).appendingPathExtension(ext.isEmpty ? "mp4" : ext)
            try FileManager.default.moveItem(at: downloaded, to: final)
        case .m4a:
            state = .converting(fraction: nil)
            final = folder.appendingPathComponent(name).appendingPathExtension("m4a")
            if downloaded.pathExtension.lowercased() == "m4a" {
                try FileManager.default.moveItem(at: downloaded, to: final)
            } else {
                try await AudioConverter.m4a(from: downloaded, to: final)
            }
        case .mp3:
            state = .converting(fraction: 0)
            final = folder.appendingPathComponent(name).appendingPathExtension("mp3")
            if downloaded.pathExtension.lowercased() == "mp3" {
                try FileManager.default.moveItem(at: downloaded, to: final)
            } else {
                try await AudioConverter.mp3(from: downloaded, to: final) { fraction in
                    Task { @MainActor [weak self] in self?.state = .converting(fraction: fraction) }
                }
            }
        }
        try Task.checkCancellation()
        return final
    }

    enum PhotosError: LocalizedError {
        case denied
        case notVideo

        var errorDescription: String? {
            switch self {
            case .denied:
                return "写真へのアクセスが許可されていません。「設定」→「プライバシーとセキュリティ」→「写真」→「ImageBrowser」で許可してください。"
            case .notVideo:
                return "この形式は写真アプリに保存できません。保存先を「ファイル」にしてください。"
            }
        }
    }

    private static func saveToPhotos(_ file: URL) async throws {
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(file.path) else { throw PhotosError.notVideo }
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw PhotosError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            // Shown as the file name in Photos' info panel and used when the
            // video is exported again.
            options.originalFilename = file.lastPathComponent
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: options)
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}
