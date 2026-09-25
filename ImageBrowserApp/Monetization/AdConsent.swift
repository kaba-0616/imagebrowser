import SwiftUI
import AppTrackingTransparency
import GoogleMobileAds

/// Shows the App Tracking Transparency prompt, and only afterwards starts the
/// Mobile Ads SDK. Apple review requires the prompt to appear before any
/// ad request (= data that could be used for tracking) is made, so the banner
/// stays hidden until `isReady` flips.
@MainActor
final class AdConsent: ObservableObject {
    static let shared = AdConsent()

    @Published private(set) var isReady = false
    private var started = false

    func start() async {
        guard !started else { return }
        started = true

        // The system silently ignores the request unless the app is already
        // active, so give the launch transition a moment to finish.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let status = await ATTrackingManager.requestTrackingAuthorization()
        AppLog.log("ATT許可状態: \(status.rawValue)")

        MobileAds.shared.start(completionHandler: nil)
        isReady = true
    }
}
