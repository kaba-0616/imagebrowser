import StoreKit
import SwiftUI

/// 設定から開くプラン一覧(ImageKeeper の「プランを選ぶ」と同じ形)。月額・年額を
/// StoreKit の実際の価格で並べ、登録と切り替えをここで行う。一括抽出の入口に出す
/// `PaywallView` は広告視聴の導線も持つので別にしている。
struct PlanListView: View {
    @ObservedObject var store: StoreManager

    @State private var purchasing: String?
    @State private var errorMessage: String?

    /// Apple's standard EULA -- the same one the App Store description links.
    /// PaywallView も同じリンクを出す。
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://nova-droplet-464.notion.site/ImageBrowser-3e5296d4576e8167ba4ff8b30c4f8b99")!

    private var ownsLifetime: Bool { store.ownsLifetime }

    var body: some View {
        List {
            Section {
                if ownsLifetime {
                    lifetimeRow
                }
                ForEach(sortedProducts, id: \.id) { product in
                    planRow(product)
                }
                if store.isLoadingProducts {
                    Text("プランを読み込んでいます…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else if store.products.isEmpty {
                    Text("購入情報を読み込めませんでした。時間をおいて再度お試しください。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Pro: 広告オフ・画像の一括抽出 / Pro+: Pro の内容に加えて動画・音声の保存")
            } footer: {
                Text("サブスクリプションは自動更新されます。いつでも「設定」アプリの自分のApple IDからキャンセルできます。プランの切り替えは、次回の更新日から反映される場合があります。")
            }
            Section {
                Link("利用規約(EULA)", destination: Self.termsURL)
                Link("プライバシーポリシー", destination: Self.privacyURL)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("プランを選ぶ")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadProducts() }
    }

    /// In `ProProduct.forSale` order: monthly, then yearly.
    private var sortedProducts: [Product] {
        store.products.sorted { order(of: $0) < order(of: $1) }
    }

    private func order(of product: Product) -> Int {
        ProProduct(rawValue: product.id).flatMap { ProProduct.forSale.firstIndex(of: $0) } ?? .max
    }

    /// 販売を終えた商品は StoreKit から取れないので、名前はここで持つ。
    private var lifetimeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pro(買い切り)")
                .font(.headline)
            if store.activeProductID == ProProduct.lifetime.rawValue {
                currentPlanLabel
            }
        }
        .padding(.vertical, 4)
    }

    private var currentPlanLabel: some View {
        Label("現在のプラン", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundColor(.green)
            .padding(.top, 2)
    }

    private func planRow(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.displayName)
                    .font(.headline)
                Spacer()
                Text(product.displayPrice + Self.periodSuffix(product))
                    .font(.subheadline.weight(.semibold))
            }
            Text(product.description)
                .font(.footnote)
                .foregroundColor(.secondary)
            if store.activeProductID == product.id {
                currentPlanLabel
            } else if !ownsLifetime || ProProduct(rawValue: product.id)?.includesMedia == true {
                // 買い切りの人は Pro のままなので、動画の付く Pro+ だけを勧める。
                Button(store.hasPurchasedPro ? "このプランに切り替える" : "登録する") {
                    Task { await purchase(product) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(purchasing != nil)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    /// "/月" etc. -- the subscription length is one of the items Guideline
    /// 3.1.2(c) requires to be shown in the app, not just the price.
    static func periodSuffix(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        let unit: String
        switch period.unit {
        case .day: unit = "日"
        case .week: unit = "週"
        case .month: unit = "月"
        case .year: unit = "年"
        @unknown default: return ""
        }
        return period.value == 1 ? " / \(unit)" : " / \(period.value)\(unit == "月" ? "か月" : unit)"
    }

    private func purchase(_ product: Product) async {
        purchasing = product.id
        errorMessage = nil
        defer { purchasing = nil }
        do {
            try await store.purchase(product)
        } catch {
            errorMessage = "購入に失敗しました: \(error.localizedDescription)"
        }
    }
}
