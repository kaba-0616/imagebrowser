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

    /// imagebrowser用にAdMobコンソールで発行した実バナー広告ユニットID。
    var id: String {
        switch self {
        case .bottom: return "ca-app-pub-1034383442757151/9505213630"
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
