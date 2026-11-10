import Foundation
import FirebaseCore
import FirebaseAnalytics

/// どのサイトで抽出・保存が使われ、どこで購入画面が出て、何が買われたかを
/// Firebase Analytics へ送る(2026-11-02、サイトごとのチューニングのため)。
///
/// 送るのはホスト名(`message.sakurazaka46.com` まで。パスとクエリは送らない
/// ――署名付き URL やログイン情報が入ることがある)と件数・種類だけ。画像や
/// ページの中身は送らない。設定の「利用状況を送信する」で止められる(既定オン)。
enum UsageStats {
    private static let enabledKey = "usageStatsEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if isConfigured { Analytics.setAnalyticsCollectionEnabled(newValue) }
        }
    }

    /// GoogleService-Info.plist は公開リポジトリに置かず、アップロード時に
    /// 署名フォルダから入れる。無いビルドでは何も送らない(configure は
    /// plist が無いと落ちるので呼ばない)。
    private static var isConfigured = false

    static func start() {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            AppLog.debug("利用状況: GoogleService-Info.plist が無いため送信しない")
            return
        }
        FirebaseApp.configure()
        isConfigured = true
        Analytics.setAnalyticsCollectionEnabled(isEnabled)
        // TestFlight・シミュレータの分を集計から外せるように。
        let build = StoreManager.isSimulator ? "simulator" : StoreManager.isTestFlight ? "testflight" : "appstore"
        Analytics.setUserProperty(build, forName: "build")
    }

    /// 購入画面を出したサイト。購入が成立したときに、どのサイトから
    /// 買われたかとして一緒に送る。
    private static var lastPaywallHost: String?

    static func host(of url: URL?) -> String {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return "(なし)" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return String(host.prefix(100))
    }

    static func extracted(page: URL?, total: Int, shown: Int) {
        log("extract_images", ["host": host(of: page), "total": total, "shown": shown])
    }

    static func extractFailed(page: URL?) {
        log("extract_failed", ["host": host(of: page)])
    }

    /// `kind`: "bulk"(一括抽出の結果から)/ "longpress"(長押し)/ "longpress_match"(Canvas の照合)
    static func saved(page: URL?, kind: String, succeeded: Int, failed: Int) {
        log("save_images", ["host": host(of: page), "kind": kind, "succeeded": succeeded, "failed": failed])
    }

    /// 動画・音声を1本保存できたとき。`format` は mp4 / mp3 / m4a。
    static func savedMedia(page: URL?, format: String, hls: Bool, talk: Bool) {
        log("save_media", ["host": host(of: page), "format": format,
                           "source": talk ? "talk" : hls ? "hls" : "file"])
    }

    /// `from`: "extract"(一括抽出ボタン)/ "history"(さかのぼり)/ "media"(動画・音声の保存)
    static func paywallShown(page: URL?, from: String) {
        let host = host(of: page)
        lastPaywallHost = host
        log("paywall_shown", ["host": host, "from": from])
    }

    static func rewardedAd(outcome: String) {
        log("rewarded_ad", ["host": lastPaywallHost ?? "(なし)", "outcome": outcome])
    }

    static func purchased(productID: String) {
        log("purchase_pro", ["product": productID, "host": lastPaywallHost ?? "(設定から)"])
    }

    static func setPlan(_ productID: String?) {
        guard isConfigured else { return }
        let plan = productID.map { $0.components(separatedBy: ".").last ?? $0 } ?? "free"
        Analytics.setUserProperty(plan, forName: "plan")
    }

    private static func log(_ name: String, _ parameters: [String: Any]) {
        guard isConfigured, isEnabled else { return }
        Analytics.logEvent(name, parameters: parameters)
        AppLog.debug("利用状況: \(name) \(parameters.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
    }
}
