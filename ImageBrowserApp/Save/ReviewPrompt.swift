import StoreKit
import UIKit

/// App Store の評価をお願いするモーダル(`AppStore.requestReview`)を出す係。
/// ImageSaver の `ReviewPrompt` と同じ方針で、出す場面だけが違う。あちらは
/// 共有シートの中で出せないのでアプリを開いたときに出すが、こちらは保存が
/// アプリの中で終わるので、**保存に成功した直後**に出す。
///
/// 出すかどうかを決めるのは OS で、こちらは「お願いしてよい場面です」と
/// 伝えるだけ。**年に何回までという上限も OS 側が持っている**ので、
/// 呼んでも何も出ないことがある。だからこそ、出したつもりで数えない:
/// 記録するのは「頼んだバージョン」だけにして、同じバージョンで何度も
/// 呼ばないようにする。
@MainActor
enum ReviewPrompt {
    /// 何回か保存してもらってから頼む。**最初の保存では出さない** ——
    /// 一度使っただけで評価を求めても、低い点が付くだけ。
    private static let minimumRuns = 3
    private static let successfulRunsKey = "review.successfulRuns"
    private static let askedVersionKey = "review.askedVersion"

    /// 1枚以上保存できた回(まとめて保存した1回は1回と数える)。
    static func recordSuccess() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: successfulRunsKey) + 1, forKey: successfulRunsKey)
        Task {
            // 「保存しました」の表示と重ならないよう、少し待ってから頼む。
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            askIfEarned()
        }
    }

    private static func askIfEarned() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: successfulRunsKey) >= minimumRuns,
              defaults.string(forKey: askedVersionKey) != AppVersion.short,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        defaults.set(AppVersion.short, forKey: askedVersionKey)
        AppLog.log("評価のお願いを OS に依頼(表示するかは OS 次第)")
        if #available(iOS 16.0, *) {
            AppStore.requestReview(in: scene)
        } else {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
}
