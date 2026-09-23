import WebKit

/// UserDefaults-backed toggle for the in-page ad blocker. Free for every
/// user (unrelated to Pro) -- default on, matching what most people expect
/// from a browser.
enum AdBlockStore {
    static let key = "adBlockEnabled"

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

/// Compiles the bundled domain-blocklist once and hands the same
/// WKContentRuleList to every tab's WKWebView -- compilation is the
/// expensive part, so it's shared rather than repeated per tab.
@MainActor
final class AdBlockManager {
    static let shared = AdBlockManager()

    private static let identifier = "ImageBrowserAdBlockList"

    private var cachedList: WKContentRuleList?
    private var compileTask: Task<WKContentRuleList?, Never>?

    private init() {}

    func ruleList() async -> WKContentRuleList? {
        if let cachedList { return cachedList }
        if let compileTask { return await compileTask.value }

        let task = Task<WKContentRuleList?, Never> {
            guard let json = AdBlockManager.loadRulesJSON() else { return nil }
            return await AdBlockManager.compile(json: json)
        }
        compileTask = task
        let result = await task.value
        cachedList = result
        return result
    }

    private static func compile(json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                if let error {
                    AppLog.log("広告ブロックルールのコンパイル失敗: \(error.localizedDescription)", isError: true)
                }
                continuation.resume(returning: list)
            }
        }
    }

    private static func loadRulesJSON() -> String? {
        guard let url = Bundle.main.url(forResource: "AdBlockRules", withExtension: "json") else {
            assertionFailure("AdBlockRules.json is missing from the app bundle")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
