import SwiftUI
import StoreKit

/// Shown when a free user taps the bulk-extract button. Offers the monthly
/// and yearly subscriptions; either one flips the same `isPro` flag.
struct PaywallView: View {
    @ObservedObject var store: StoreManager
    let onClose: () -> Void
    /// "Watch an ad for one extraction". nil hides the option (opened from
    /// Settings, or the ad SDK isn't started yet).
    var onWatchAd: (() async -> RewardedAdManager.Outcome)? = nil

    @State private var purchasing: String?
    @State private var errorMessage: String?
    @State private var watchingAd = false
    @ObservedObject private var rewardedAd = RewardedAdManager.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 44))
                            .foregroundColor(.accentColor)
                        Text("Proで一括抽出を使う")
                            .font(.title2.bold())
                        Text("ページ内の画像をまとめて抽出・選択保存できるようになり、広告も非表示になります。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    if store.isLoadingProducts {
                        ProgressView()
                    } else if store.products.isEmpty {
                        Text("購入情報を読み込めませんでした。時間をおいて再度お試しください。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(sortedProducts, id: \.id) { product in
                                Button {
                                    Task { await purchase(product) }
                                } label: {
                                    productRow(product)
                                }
                                .disabled(purchasing != nil)
                            }
                        }
                    }

                    if let onWatchAd {
                        Button {
                            Task {
                                watchingAd = true
                                errorMessage = nil
                                let outcome = await onWatchAd()
                                watchingAd = false
                                switch outcome {
                                case .earned: break
                                case .notEarned: errorMessage = "広告を最後まで見ると1回使えます。"
                                case .unavailable: errorMessage = "広告を読み込めませんでした。時間をおいて再度お試しください。"
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "play.rectangle")
                                Text("広告を見て1回だけ使う")
                                    .font(.headline)
                                Spacer()
                                if watchingAd || rewardedAd.isLoading {
                                    ProgressView()
                                }
                            }
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor))
                        }
                        .disabled(purchasing != nil || watchingAd)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }

                    Button("購入を復元") {
                        Task { await store.restorePurchases() }
                    }
                    .font(.footnote)
                    .disabled(purchasing != nil)

                    // Guideline 3.1.2(c): 期間・自動更新・利用規約・プライバシーポリシーを
                    // 購入画面そのものに出す(PlanListView と同じ内容)。
                    Text("サブスクリプションは自動更新されます。いつでも「設定」アプリの自分のApple IDからキャンセルできます。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Link("プランの変更・解約は「設定」アプリのサブスクリプションから行えます", destination: URL(string: "itms-apps://apps.apple.com/account/subscriptions")!)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 16) {
                        Link("利用規約(EULA)", destination: PlanListView.termsURL)
                        Link("プライバシーポリシー", destination: PlanListView.privacyURL)
                    }
                    .font(.caption)
                }
                .padding()
            }
            .navigationTitle("Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { onClose() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            if onWatchAd != nil { await rewardedAd.preload() }
        }
        .onChange(of: store.isPro) { isPro in
            if isPro { onClose() }
        }
    }

    /// In `ProProduct.forSale` order: monthly, then yearly.
    private var sortedProducts: [Product] {
        store.products.sorted { order(of: $0) < order(of: $1) }
    }

    private func order(of product: Product) -> Int {
        ProProduct(rawValue: product.id).flatMap { ProProduct.forSale.firstIndex(of: $0) } ?? .max
    }

    private func productRow(_ product: Product) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName)
                    .font(.headline)
                Text(product.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if purchasing == product.id {
                ProgressView()
            } else {
                Text(product.displayPrice + PlanListView.periodSuffix(product))
                    .font(.headline)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .foregroundColor(.primary)
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
