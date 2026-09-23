import SwiftUI
import StoreKit

/// Shown when a free user taps the bulk-extract button. Offers the lifetime
/// purchase and either subscription; any one of them flips the same
/// `isPro` flag.
struct PaywallView: View {
    @ObservedObject var store: StoreManager
    let onClose: () -> Void

    @State private var purchasing: String?
    @State private var errorMessage: String?

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
        .onChange(of: store.isPro) { isPro in
            if isPro { onClose() }
        }
    }

    /// Lifetime first (the simplest choice for someone who just wants the
    /// feature once), then subscriptions.
    private var sortedProducts: [Product] {
        store.products.sorted { lhs, rhs in
            (ProProduct(rawValue: lhs.id)?.isSubscription ?? false ? 1 : 0)
                < (ProProduct(rawValue: rhs.id)?.isSubscription ?? false ? 1 : 0)
        }
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
                Text(product.displayPrice)
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
