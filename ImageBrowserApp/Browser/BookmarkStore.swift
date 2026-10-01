import Foundation

struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: URL

    init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// Persisted as a single JSON blob in UserDefaults -- a handful to a few
/// hundred bookmarks doesn't warrant a database, and this keeps the whole
/// feature to one file.
@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []

    private static let key = "bookmarks"

    init() {
        load()
        removeSeededTestingSitesIfNeeded()
    }

    /// Up to 1.0.0 (build 22), every install was seeded once with these
    /// sites -- a development aid for checking image detection on real
    /// sites, which shipped to App Store users too. Seeding was removed in
    /// 1.0.1; this takes the seeded entries back out once, on the first
    /// launch after updating, so everyone starts from an empty list. Only
    /// these exact URLs are removed -- bookmarks the user added stay (a
    /// manually added bookmark of the very same URL can't be told apart and
    /// goes too).
    private func removeSeededTestingSitesIfNeeded() {
        let flag = "testingSitesRemoved"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        guard UserDefaults.standard.bool(forKey: "testingSitesSeeded") else { return }

        let seededURLs: Set<String> = [
            "https://kaba-0616.github.io/imagebrowser-demo/demo.html",
            "https://news.yahoo.co.jp/",
            "https://news.livedoor.com/",
            "https://www.oricon.co.jp/news/",
            "https://mdpr.jp/",
            "https://natalie.mu/music",
            "https://realsound.jp/",
            "https://www.billboard-japan.com/",
            "https://www.instagram.com/",
            "https://x.com/",
            "https://www.threads.net/",
            "https://sakurazaka46.com/",
            "https://www.hinatazaka46.com/",
            "https://www.nogizaka46.com/",
            "https://www.stardust.co.jp/talent/",
            "https://www.horipro.co.jp/",
            "https://www.akb48.co.jp/",
            "https://sp.equal-love.jp/"
        ]
        let before = bookmarks.count
        bookmarks.removeAll { seededURLs.contains($0.url.absoluteString) }
        if bookmarks.count != before {
            save()
            AppLog.log("初期登録のブックマークを削除: \(before - bookmarks.count)件")
        }
    }

    func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    func toggle(title: String, url: URL) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(Bookmark(title: title.isEmpty ? url.absoluteString : title, url: url), at: 0)
        }
        save()
    }

    func remove(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return }
        bookmarks = (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
