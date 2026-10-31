import Foundation

/// (ImageSaver の同名ファイルからそのまま移植、2026-10-31)
/// 一覧に並んでいるのが小さなサムネイルで、**原寸のURLがその写真の個別
/// ページにしか書かれていない**サイト向けに、そのページを読んで `og:image`
/// を取り出す係(oricon の写真一覧は一覧が160x236、原寸1200x1800のURLは
/// /photo/N/ の og:image にしかない)。
///
/// 全画面表示と保存の**両方**から呼ばれるので、ここで一元管理する:
///
/// - **同じページは1回しか読まない**(結果を控える)。拡大して見た写真を
///   そのまま保存しても、ページを読むのは最初の1回だけ。
/// - **同時には1本だけ**、しかも間隔を空けて読む。共有した時点で全部
///   読みに行ったビルド39は、18回あたりで 429 / 503 を返され、その後
///   しばらく**普通の閲覧まで**巻き添えになった(2026-10-29 実測)。
/// - **断られたら、しばらく全部あきらめる。** 粘ると締め出しが伸びる。
actor OriginalPageResolver {

    static let shared = OriginalPageResolver()

    /// 見つかった原寸のURL、または理由を添えた nil。
    /// 呼び出し側は nil のとき**表示されていたサムネイルに落ちる**ので、
    /// 取れなくても保存も表示も通る。
    struct Outcome {
        let original: URL?
        /// ログに出す値がある場合だけ入る。成功時と、控えてあった答えを
        /// 返しただけのときは nil。
        let note: String?
    }

    /// 読み終わったページ。原寸が見つからなかったことも(nil として)覚える。
    private var resolved: [URL: URL?] = [:]
    /// いま読んでいる最中のページ。拡大表示と保存が同時に同じページを
    /// 要求したときに、2回読まないため。
    private var inFlight: [URL: Task<Fetched, Never>] = [:]
    private var lastFetch: Date?
    private var blockedUntil: Date?

    /// 続けて読むときに空ける最小の間隔。
    private let gap: TimeInterval = 0.3
    /// 断られたあと、次に試すまで待つ時間。
    private let penalty: TimeInterval = 30

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func original(forPage page: URL, thumbnail: URL) async -> Outcome {
        if let known = resolved[page] {
            return Outcome(original: known, note: nil)
        }
        if let blockedUntil, blockedUntil > Date() {
            return Outcome(original: nil, note: nil)
        }
        if let running = inFlight[page] {
            return Outcome(original: await running.value.original, note: nil)
        }

        // 間隔を空けるのは**順番待ちの外側**で。ここで待たないと、
        // 連続した要求が同時に飛び出す。
        if let lastFetch {
            let since = Date().timeIntervalSince(lastFetch)
            if since < gap {
                try? await Task.sleep(nanoseconds: UInt64((gap - since) * 1_000_000_000))
            }
        }
        lastFetch = Date()

        let task = Task<Fetched, Never> { [session] in
            await Self.fetchOriginal(from: page, thumbnail: thumbnail, session: session)
        }
        inFlight[page] = task
        let got = await task.value
        inFlight[page] = nil

        if got.refused {
            // 締め出しが解けたら読み直せるように、この回は覚えない。
            blockedUntil = Date().addingTimeInterval(penalty)
        } else {
            resolved[page] = got.original
        }
        return Outcome(original: got.original, note: got.note)
    }

    private struct Fetched {
        let original: URL?
        let note: String?
        /// 429 / 503 ——「速すぎる」の意思表示。
        let refused: Bool
    }

    private static func fetchOriginal(
        from page: URL,
        thumbnail: URL,
        session: URLSession
    ) async -> Fetched {
        do {
            let (data, response) = try await session.data(from: page)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 429 || http.statusCode == 503 {
                    return Fetched(
                        original: nil,
                        note: "サイトに断られたため原寸の取得をしばらく止めます (HTTP \(http.statusCode))",
                        refused: true)
                }
                return Fetched(original: nil,
                               note: "原寸のページを読めませんでした (HTTP \(http.statusCode))",
                               refused: false)
            }
            // 文字コードは問わない。og:image の中身は ASCII の URL なので、
            // UTF-8 として読めなくても latin1 なら必ず通る(oricon は Shift_JIS)。
            guard let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                return Fetched(original: nil,
                               note: "原寸のページを読めませんでした(文字コード不明)",
                               refused: false)
            }
            guard let found = ogImageURL(in: html),
                  let original = URL(string: found, relativeTo: page)?.absoluteURL,
                  original != thumbnail else {
                return Fetched(original: nil,
                               note: "原寸のページに og:image がありませんでした",
                               refused: false)
            }
            return Fetched(original: original, note: nil, refused: false)
        } catch {
            return Fetched(original: nil,
                           note: "原寸のページを読めませんでした: \(error.localizedDescription)",
                           refused: false)
        }
    }

    /// ページ全体を HTML として組み立てる必要は無いので、`og:image` の
    /// meta タグだけを文字列から抜く。
    private static let ogImageTag = try? NSRegularExpression(
        pattern: "<meta[^>]+?(?:property|name)\\s*=\\s*[\"']og:image[\"'][^>]*>",
        options: [.caseInsensitive])
    private static let contentAttribute = try? NSRegularExpression(
        pattern: "content\\s*=\\s*[\"']([^\"']+)[\"']",
        options: [.caseInsensitive])

    static func ogImageURL(in html: String) -> String? {
        guard let tagRegex = ogImageTag, let contentRegex = contentAttribute else { return nil }
        let full = NSRange(html.startIndex..., in: html)
        guard let tag = tagRegex.firstMatch(in: html, range: full),
              let tagRange = Range(tag.range, in: html) else { return nil }
        let tagText = String(html[tagRange])
        let tagFull = NSRange(tagText.startIndex..., in: tagText)
        guard let content = contentRegex.firstMatch(in: tagText, range: tagFull),
              let valueRange = Range(content.range(at: 1), in: tagText) else { return nil }
        return String(tagText[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
