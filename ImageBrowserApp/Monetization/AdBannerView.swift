import SwiftUI
import GoogleMobileAds

/// Standard banner, shown only while the viewer is not Pro (see StoreManager).
struct AdBannerView: UIViewRepresentable {
    let adUnitID: String

    init(_ placement: AdUnit) {
        self.adUnitID = placement.id
    }

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = adUnitID
        banner.rootViewController = context.environment.uiRootViewController
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}

enum AdUnit {
    case bottom

    /// Placeholder: Google's public test banner unit. Replace with the real
    /// AdMob-issued ID for jp.kaba.imagebrowser once the app is registered
    /// in the AdMob console (see project.yml's GADApplicationIdentifier
    /// comment -- both need to move together).
    var id: String {
        switch self {
        case .bottom: return "ca-app-pub-3940256099942544/2934735716"
        }
    }
}

private struct UIRootViewControllerKey: EnvironmentKey {
    static let defaultValue: UIViewController? = {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow }?.rootViewController
    }()
}

private extension EnvironmentValues {
    var uiRootViewController: UIViewController? {
        self[UIRootViewControllerKey.self]
    }
}
