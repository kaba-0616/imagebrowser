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

    /// TestFlight installs carry a sandbox receipt; App Store installs don't.
    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

    /// TestFlight only: behave as a free user even with a (sandbox) Pro
    /// purchase, to try free-user flows such as the rewarded ad -- sandbox
    /// lifetime purchases can't be undone. Ignored on App Store builds.
    @Published var ignoreProForTesting = UserDefaults.standard.bool(forKey: "ignoreProForTesting") {
        didSet {
            UserDefaults.standard.set(ignoreProForTesting, forKey: "ignoreProForTesting")
            Task { await refreshEntitlements() }
        }
    }

    private var proSuppressed: Bool { Self.isTestFlight && ignoreProForTesting }

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
        isPro = found && !proSuppressed
    }

    private func handle(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else { return }
        if ProProduct(rawValue: transaction.productID) != nil, !proSuppressed {
            isPro = true
        }
        await transaction.finish()
    }
}
