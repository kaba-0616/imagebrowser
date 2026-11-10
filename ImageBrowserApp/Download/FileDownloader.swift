import Foundation

/// Downloads one plain media file (not HLS) with progress, using the page's
/// cookies/Referer/User-Agent (see `RequestContext`).
final class FileDownloader: NSObject, URLSessionDownloadDelegate {

    struct Result {
        let file: URL
        let mimeType: String
    }

    private var session: URLSession!
    private var continuation: CheckedContinuation<Result, Error>?
    private var progress: ((Int64, Int64) -> Void)?
    private var destinationFolder: URL!
    private var task: URLSessionDownloadTask?

    func download(_ url: URL, context: RequestContext, into folder: URL,
                  progress: @escaping (_ written: Int64, _ expected: Int64) -> Void) async throws -> Result {
        destinationFolder = folder
        self.progress = progress
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: context.request(url))
                self.task = task
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let response = downloadTask.response
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(DownloadError.http(http.statusCode, "ファイル")))
            return
        }
        // The temporary file is deleted as soon as this returns.
        let mime = response?.mimeType ?? ""
        var ext = downloadTask.originalRequest?.url?.pathExtension ?? ""
        if ext.isEmpty { ext = Self.fileExtension(forMIME: mime) }
        let target = destinationFolder.appendingPathComponent("download").appendingPathExtension(ext.isEmpty ? "bin" : ext)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            finish(.success(Result(file: target, mimeType: mime)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            finish(.failure(DownloadError.cancelled))
        } else {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    static func fileExtension(forMIME mime: String) -> String {
        switch mime.lowercased() {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/aac": return "aac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/ogg": return "ogg"
        default: return ""
        }
    }
}
