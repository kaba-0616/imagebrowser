import StoreKit

/// Both the one-time purchase and either subscription unlock the exact same
/// "Pro" entitlement (bulk extraction + no ads) -- deliberately not split
/// into separate feature sets, so the purchase flow only ever has to ask
/// "is the user Pro or not", never "which plan are they on".
enum ProProduct: String, CaseIterable {
    case lifetime = "jp.kaba.imagebrowser.pro.lifetime"
    case monthly = "jp.kaba.imagebrowser.pro.monthly"
    case yearly = "jp.kaba.imagebrowser.pro.yearly"

    var isSubscription: Bool { self != .lifetime }
}

@MainActor
final class StoreManager: ObservableObject {

    @Published private(set) var isPro = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoadingProducts = false

    private var transactionListenerTask: Task<Void, Never>?

    init() {
        transactionListenerTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await Product.products(for: ProProduct.allCases.map(\.rawValue))
        } catch {
            products = []
        }
    }

    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            await handle(verification)
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    private func refreshEntitlements() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               ProProduct(rawValue: transaction.productID) != nil {
                found = true
            }
        }
        isPro = found
    }

    private func handle(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else { return }
        if ProProduct(rawValue: transaction.productID) != nil {
            isPro = true
        }
        await transaction.finish()
    }
}
