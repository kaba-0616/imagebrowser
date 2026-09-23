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
        seedTestingSitesIfNeeded()
    }

    // TODO: 一時的な実装。画像検出ロジックの実機検証が終わったら削除する。
    // 検証対象サイト一覧をブックマークに仕込んでおき、毎回URLを手入力せずに
    // 巡回できるようにするためのもの。アプリ生涯で一度だけ(手動でブックマーク
    // 済みかどうかに関わらず)既存のブックマークに追加投入する。以降は
    // testingSitesSeededフラグだけで判定するので、後で手動削除しても
    // 再投入はされない。
    private func seedTestingSitesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "testingSitesSeeded") else { return }
        UserDefaults.standard.set(true, forKey: "testingSitesSeeded")

        let sites: [(String, String)] = [
            ("Yahoo!ニュース", "https://news.yahoo.co.jp/"),
            ("livedoor NEWS", "https://news.livedoor.com/"),
            ("ORICON NEWS", "https://www.oricon.co.jp/news/"),
            ("モデルプレス", "https://mdpr.jp/"),
            ("音楽ナタリー", "https://natalie.mu/music"),
            ("リアルサウンド", "https://realsound.jp/"),
            ("ビルボードジャパン", "https://www.billboard-japan.com/"),
            ("Instagram", "https://www.instagram.com/"),
            ("X (Twitter)", "https://x.com/"),
            ("Threads", "https://www.threads.net/"),
            ("櫻坂46", "https://sakurazaka46.com/"),
            ("日向坂46", "https://www.hinatazaka46.com/"),
            ("乃木坂46", "https://www.nogizaka46.com/"),
            ("スターダスト タレント一覧", "https://www.stardust.co.jp/talent/"),
            ("ホリプロ", "https://www.horipro.co.jp/"),
            ("AKB48", "https://www.akb48.co.jp/"),
            ("=LOVE(イコラブ)", "https://sp.equal-love.jp/")
        ]
        let seeded = sites.compactMap { title, urlString -> Bookmark? in
            guard let url = URL(string: urlString) else { return nil }
            return Bookmark(title: title, url: url)
        }
        bookmarks.append(contentsOf: seeded)
        save()
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
