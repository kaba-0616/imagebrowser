import UIKit
import GoogleMobileAds

/// "Watch one ad, run one bulk extraction" for free users (see PaywallView).
/// Kept preloaded so the ad starts right away when the button is tapped.
@MainActor
final class RewardedAdManager: NSObject, ObservableObject {
    static let shared = RewardedAdManager()

    enum Outcome {
        /// Watched to the end -- grant one extraction.
        case earned
        /// Closed before the reward point.
        case notEarned
        /// No ad could be loaded or shown (no fill, offline...).
        case unavailable
    }

    @Published private(set) var isLoading = false
    private var ad: RewardedAd?
    private var dismissed: CheckedContinuation<Void, Never>?
    private var earned = false

    func preload() async {
        guard ad == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await RewardedAd.load(with: AdUnit.rewarded.id, request: Request())
            loaded.fullScreenContentDelegate = self
            ad = loaded
            AppLog.log("リワード広告の読み込み完了")
        } catch {
            AppLog.log("リワード広告の読み込み失敗: \(error.localizedDescription)", isError: true)
        }
    }

    /// Presents over whatever is frontmost (the paywall sheet) and returns
    /// once the ad has been closed.
    func show() async -> Outcome {
        if ad == nil { await preload() }
        guard let ad, let presenter = Self.topViewController() else { return .unavailable }
        self.ad = nil
        earned = false
        await withCheckedContinuation { continuation in
            dismissed = continuation
            ad.present(from: presenter) { [weak self] in
                self?.earned = true
            }
        }
        Task { await preload() }
        return earned ? .earned : .notEarned
    }

    private func finishPresentation() {
        dismissed?.resume()
        dismissed = nil
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

extension RewardedAdManager: FullScreenContentDelegate {
    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in self.finishPresentation() }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in
            AppLog.log("リワード広告の表示失敗: \(error.localizedDescription)", isError: true)
            self.finishPresentation()
        }
    }
}
