import StoreKit

/// Every product unlocks "Pro" (bulk extraction + no ads). The Pro+ plans
/// (2026-11-10, when VideoBrowser was folded in) add saving videos and
/// audio on top; they sit above Pro in the same subscription group, so
/// moving between them is an App Store upgrade/downgrade, never a second
/// subscription.
enum ProProduct: String, CaseIterable {
    /// 2026-11-01 に販売終了(サブスクのみにした)。既に買った人の Pro を
    /// 消さないよう、権利の判定には残している。
    case lifetime = "jp.kaba.imagebrowser.pro.lifetime"
    case monthly = "jp.kaba.imagebrowser.pro.monthly"
    case yearly = "jp.kaba.imagebrowser.pro.yearly"
    case plusMonthly = "jp.kaba.imagebrowser.plus.monthly"
    case plusYearly = "jp.kaba.imagebrowser.plus.yearly"

    /// What the paywall offers, in display order.
    static let forSale: [ProProduct] = [.monthly, .yearly, .plusMonthly, .plusYearly]

    /// Saving videos and audio comes with these only.
    var includesMedia: Bool { self == .plusMonthly || self == .plusYearly }
}

@MainActor
final class StoreManager: ObservableObject {

    @Published private(set) var isPro = false
    /// Pro+: may save videos and audio. Like `isPro`, follows `ignoreProForTesting`.
    @Published private(set) var canSaveMedia = false
    /// Owns the discontinued lifetime purchase. It never included video, so
    /// these users are still offered Pro+ (and only Pro+).
    @Published private(set) var ownsLifetime = false
    /// The real purchase state, unaffected by `ignoreProForTesting` -- the
    /// settings screen's "現在のプラン" shows this, so turning the test
    /// switch on doesn't make a purchase look gone (user request).
    @Published private(set) var hasPurchasedPro = false
    /// Which product `hasPurchasedPro` comes from -- the plan list marks it
    /// as "現在のプラン". Like `hasPurchasedPro`, ignores `ignoreProForTesting`.
    @Published private(set) var activeProductID: String?
    /// `isPro == false` alone can't tell "not Pro" from "the first
    /// entitlement check hasn't come back yet" -- the launch splash waits on
    /// this so a Pro user never sees the ad banner flash (same as ImageKeeper).
    @Published private(set) var hasCheckedEntitlements = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoadingProducts = false

    private var transactionListenerTask: Task<Void, Never>?

    /// TestFlight installs carry a sandbox receipt; App Store installs don't.
    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

    /// Local simulator runs are unsigned, so StoreKit purchases fail and the
    /// rewarded ad times out there; treat them as Pro so features can be
    /// checked. Compiled out of every device build.
    #if targetEnvironment(simulator)
    static let isSimulator = true
    #else
    static let isSimulator = false
    #endif

    /// Where the "behave as a free user" test toggle is offered.
    static var isTestBuild: Bool { isTestFlight || isSimulator }

    /// TestFlight only: behave as a free user even with a (sandbox) Pro
    /// purchase, to try free-user flows such as the rewarded ad -- sandbox
    /// purchases can't be undone. Ignored on App Store builds.
    @Published var ignoreProForTesting = UserDefaults.standard.bool(forKey: "ignoreProForTesting") {
        didSet {
            UserDefaults.standard.set(ignoreProForTesting, forKey: "ignoreProForTesting")
            Task { await refreshEntitlements() }
        }
    }

    private var proSuppressed: Bool { Self.isTestBuild && ignoreProForTesting }

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
            products = try await Product.products(for: ProProduct.forSale.map(\.rawValue))
        } catch {
            products = []
        }
    }

    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            if case .verified = verification { UsageStats.purchased(productID: product.id) }
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
        var owned: [ProProduct] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let found = ProProduct(rawValue: transaction.productID) else { continue }
            owned.append(found)
        }
        // 「現在のプラン」に出すもの: Pro+ があればそれ(いちばん多く使える)、
        // 次に買い切り(サブスクを解約しても Pro のままなので)、最後に Pro。
        let active = owned.first(where: \.includesMedia)
            ?? owned.first(where: { $0 == .lifetime })
            ?? owned.first
        activeProductID = active?.rawValue
        ownsLifetime = owned.contains(.lifetime)
        UsageStats.setPlan(active?.rawValue)
        hasPurchasedPro = active != nil || Self.isSimulator
        isPro = hasPurchasedPro && !proSuppressed
        canSaveMedia = (owned.contains(where: \.includesMedia) || Self.isSimulator) && !proSuppressed
        hasCheckedEntitlements = true
    }

    private func handle(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else { return }
        if ProProduct(rawValue: transaction.productID) != nil {
            hasPurchasedPro = true
            if !proSuppressed { isPro = true }
        }
        await transaction.finish()
        await refreshEntitlements()
    }
}
