import UIKit
import ImageIO

/// Bounded thumbnail/full-image cache, same shape as ImageSaver's
/// ImageLoader. The app process has far more memory headroom than an
/// extension, but the lesson that project's CLAUDE.md calls out --
/// "large image galleries with no cap crash" -- is a property of loading
/// hundreds of full-res images at once, not of running inside an extension,
/// so the budget stays here rather than being dropped.
@MainActor
final class ImageLoader: ObservableObject {

    @Published private(set) var thumbnails: [Int: UIImage] = [:]
    @Published private(set) var fullImages: [Int: UIImage] = [:]
    @Published private(set) var failed: Set<Int> = []
    @Published private(set) var pixelSizes: [Int: CGSize] = [:]
    @Published private(set) var measuredFrom: [Int: URL] = [:]

    func trueSize(of image: PageImage) -> CGSize? {
        guard let size = pixelSizes[image.id] else { return nil }
        guard image.renderedURL == nil || measuredFrom[image.id] == image.url else { return nil }
        return size
    }

    private func record(_ pixelSize: CGSize?, for image: PageImage, from url: URL) {
        guard let pixelSize else { return }
        if measuredFrom[image.id] == image.url, url != image.url { return }
        measuredFrom[image.id] = url
        pixelSizes[image.id] = pixelSize
    }

    private var onScreen: Set<Int> = []
    private var thumbnailOrder: [Int] = []
    private var fullImageOrder: [Int] = []

    private let thumbnailBudget = 96 * 1024 * 1024
    private let fullImageLimit = 4

    private var tasks: [Int: Task<Void, Never>] = [:]
    private var fullImageTasks: [Int: Task<Void, Never>] = [:]
    private let semaphore = AsyncSemaphore(limit: 6)
    private let fullImageSemaphore = AsyncSemaphore(limit: 2)
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.purge() }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func markOnScreen(_ id: Int, _ visible: Bool) {
        if visible { onScreen.insert(id) } else { onScreen.remove(id) }
    }

    func purge() {
        while fullImageOrder.count > 1 {
            fullImages[fullImageOrder.removeFirst()] = nil
        }
        trimThumbnails(to: 0)
    }

    private func storeThumbnail(_ image: UIImage, for id: Int) {
        thumbnails[id] = image
        thumbnailOrder.removeAll { $0 == id }
        thumbnailOrder.append(id)
        trimThumbnails(to: thumbnailBudget)
    }

    private func storeFullImage(_ image: UIImage, for id: Int) {
        fullImages[id] = image
        fullImageOrder.removeAll { $0 == id }
        fullImageOrder.append(id)
        while fullImageOrder.count > fullImageLimit {
            fullImages[fullImageOrder.removeFirst()] = nil
        }
    }

    private func trimThumbnails(to budget: Int) {
        var total = thumbnailOrder.reduce(0) { $0 + bytes(of: thumbnails[$1]) }
        var index = 0
        while total > budget, index < thumbnailOrder.count {
            let id = thumbnailOrder[index]
            if onScreen.contains(id) {
                index += 1
                continue
            }
            total -= bytes(of: thumbnails[id])
            thumbnails[id] = nil
            thumbnailOrder.remove(at: index)
        }
    }

    private func bytes(of image: UIImage?) -> Int {
        guard let cgImage = image?.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    func requestThumbnail(for image: PageImage, maxPixelSize: CGFloat = 300) {
        guard thumbnails[image.id] == nil, !failed.contains(image.id), tasks[image.id] == nil else { return }

        tasks[image.id] = Task { [weak self] in
            guard let self else { return }
            await self.semaphore.wait()
            defer { Task { await self.semaphore.signal() } }
            if Task.isCancelled { return }

            do {
                let (thumbnail, pixelSize, from) = try await self.download(
                    image, preferring: image.renderedURL ?? image.url, maxPixelSize: maxPixelSize)
                if Task.isCancelled { return }
                self.storeThumbnail(thumbnail, for: image.id)
                self.record(pixelSize, for: image, from: from)
            } catch {
                if !Task.isCancelled { self.failed.insert(image.id) }
            }
            self.tasks[image.id] = nil
        }
    }

    func requestFullImage(for pageImage: PageImage, maxPixelSize: CGFloat = 2048) {
        let id = pageImage.id
        guard fullImages[id] == nil, fullImageTasks[id] == nil else { return }

        fullImageTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.fullImageSemaphore.wait()
            defer { Task { await self.fullImageSemaphore.signal() } }

            if !Task.isCancelled,
               let (decoded, pixelSize, from) = try? await self.download(
                   pageImage, preferring: pageImage.url, maxPixelSize: maxPixelSize) {
                self.storeFullImage(decoded, for: id)
                self.record(pixelSize, for: pageImage, from: from)
            }
            self.fullImageTasks[id] = nil
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        fullImageTasks.values.forEach { $0.cancel() }
        fullImageTasks.removeAll()
    }

    private func download(
        _ image: PageImage,
        preferring first: URL,
        maxPixelSize: CGFloat
    ) async throws -> (image: UIImage, pixelSize: CGSize?, from: URL) {
        do {
            let got = try await downloadThumbnail(url: first, maxPixelSize: maxPixelSize, isSVG: image.isSVG)
            return (got.image, got.pixelSize, first)
        } catch {
            let other = (first == image.url) ? image.renderedURL : image.url
            guard let other, other != first else { throw error }
            let got = try await downloadThumbnail(url: other, maxPixelSize: maxPixelSize, isSVG: image.isSVG)
            return (got.image, got.pixelSize, other)
        }
    }

    private func downloadThumbnail(
        url: URL, maxPixelSize: CGFloat, isSVG: Bool
    ) async throws -> (image: UIImage, pixelSize: CGSize?) {
        let (data, _) = try await session.data(from: url)

        if isSVG {
            let rendered = try SVGRasterizer.rasterize(data: data, maxPixelSize: maxPixelSize)
            return (rendered, nil)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageLoadError.decodeFailed
        }

        var pixelSize: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadError.decodeFailed
        }

        return (UIImage(cgImage: cgImage), pixelSize)
    }
}

actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.value = limit }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
