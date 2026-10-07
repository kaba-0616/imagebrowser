import Foundation
import Combine
import WebKit

/// A single browser tab: an identity plus its own WKWebView-owning controller.
/// Each tab keeps its own navigation history and page state independently.
@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    let controller: WebViewController
    /// The last URL this tab was known to show -- what saveState() falls
    /// back to while `webView.url` is nil, instead of the home page.
    var lastKnownURL: String?
    /// So a tab whose URL stays nil is logged once, not on every save.
    var loggedMissingURL = false

    init() {
        controller = WebViewController()
    }

    /// For a tab created by promoting a `window.open()`/`target="_blank"`
    /// popup -- see `TabManager.openTab(wrapping:)`.
    init(wrapping webView: WKWebView) {
        controller = WebViewController(popupWebView: webView)
    }
}

/// Simple tab set: open/close/switch only, no thumbnails or tab-group UI.
/// Persists the open tabs' URLs across app restarts -- without this, force-
/// quitting the app (the normal way anyone closes an app) silently threw
/// away whatever the user had open and dropped them back on the home page.
@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var activeTabID: BrowserTab.ID?

    private var urlObservers: [BrowserTab.ID: AnyCancellable] = [:]
    private static let savedURLsKey = "savedTabURLs"
    private static let savedActiveIndexKey = "savedActiveTabIndex"

    var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    init() {
        restoreOrCreateInitialTabs()
    }

    /// `urlString`: what the new tab opens -- the home page when nil.
    @discardableResult
    func newTab(loading urlString: String? = nil) -> BrowserTab {
        let tab = makeTab(loading: urlString ?? BrowserDefaults.homeURL.absoluteString)
        tabs.append(tab)
        activeTabID = tab.id
        saveState()
        return tab
    }

    /// Promotes a `window.open()`/`target="_blank"` popup (already created
    /// by WebKit, wired for the calling page's `window.opener`) into an
    /// ordinary tab, and switches to it -- see WebViewController.onOpenTab
    /// for why this needs to be a real tab rather than a disposable dialog.
    @discardableResult
    func openTab(wrapping webView: WKWebView) -> BrowserTab {
        let tab = BrowserTab(wrapping: webView)
        wireTab(tab)
        tabs.append(tab)
        activeTabID = tab.id
        saveState()
        return tab
    }

    /// Closing the last tab opens a fresh one rather than leaving the
    /// browser with nothing to show -- except from the tab list
    /// (`keepAtLeastOne: false`), which stays at zero tabs until it's
    /// dismissed and then calls `ensureTab()` (user request: closing every
    /// tab there shouldn't make a new one pop up in the list).
    func closeTab(_ id: BrowserTab.ID, keepAtLeastOne: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        urlObservers[id] = nil
        if tabs.isEmpty {
            if keepAtLeastOne {
                newTab()
            } else {
                activeTabID = nil
                saveState()
            }
        } else {
            if activeTabID == id {
                activeTabID = tabs[min(index, tabs.count - 1)].id
            }
            saveState()
        }
    }

    /// Opens a fresh tab if every tab was closed from the tab list.
    func ensureTab() {
        if tabs.isEmpty { newTab() }
    }

    func selectTab(_ id: BrowserTab.ID) {
        activeTabID = id
        saveState()
    }

    private func makeTab(loading urlString: String) -> BrowserTab {
        let tab = BrowserTab()
        tab.lastKnownURL = urlString
        tab.controller.load(urlString: urlString)
        wireTab(tab)
        return tab
    }

    /// Wires up the bits every tab needs regardless of how it was created:
    /// persisting its URL as it navigates, and letting its controller open
    /// new tabs / close itself (see WebViewController.onOpenTab/onRequestClose).
    private func wireTab(_ tab: BrowserTab) {
        // Any subsequent navigation inside this tab (following a link,
        // typing a new address) should update what gets restored next
        // launch too, not just the URL it started on.
        urlObservers[tab.id] = tab.controller.$urlString
            .dropFirst()
            .sink { [weak self] _ in self?.saveState() }
        tab.controller.onOpenTab = { [weak self] popupWebView in
            self?.openTab(wrapping: popupWebView)
        }
        tab.controller.onRequestClose = { [weak self, weak tab] in
            guard let tab else { return }
            self?.closeTab(tab.id)
        }
    }

    private func restoreOrCreateInitialTabs() {
        let savedURLs = UserDefaults.standard.stringArray(forKey: Self.savedURLsKey) ?? []
        guard !savedURLs.isEmpty else {
            newTab()
            return
        }

        // Diagnostics for tabs all coming back as the home page after
        // switching between the App Store and TestFlight builds.
        let home = BrowserDefaults.homeURL.absoluteString
        let hosts = savedURLs.map { URL(string: $0)?.host ?? "?" }
        AppLog.log("タブ復元: \(savedURLs.count)件(ホーム\(savedURLs.filter { $0 == home }.count)件) \(hosts.joined(separator: ", "))")

        let restored = savedURLs.map { makeTab(loading: $0) }
        tabs = restored
        let savedIndex = UserDefaults.standard.integer(forKey: Self.savedActiveIndexKey)
        activeTabID = restored.indices.contains(savedIndex) ? restored[savedIndex].id : restored.first?.id
    }

    /// Reads `webView.url` directly rather than `controller.urlString` --
    /// `urlString` mirrors it through a KVO callback wrapped in `Task { @MainActor
    /// in ... }`, which lags webView.url by at least one runloop tick. When
    /// two tabs both start loading at once (most notably right after
    /// restoring tabs on launch), saveState() could fire from one tab's
    /// already-resolved urlString while the other tab's mirror hadn't
    /// caught up yet, and its still-empty urlString got misread as "no
    /// page loaded" and overwritten with the home URL, permanently losing
    /// that tab's real page on the next restart. webView.url has no such
    /// lag since it's read straight from WebKit, not our own mirror.
    private func saveState() {
        let urls = tabs.map { tab -> String in
            if let current = tab.controller.webView.url?.absoluteString {
                tab.lastKnownURL = current
                tab.loggedMissingURL = false
                return current
            }
            // webView.url can be nil while a tab hasn't committed its first
            // load (or its web content process is gone); saving the home
            // page then would lose the tab's real page for good.
            if !tab.loggedMissingURL {
                tab.loggedMissingURL = true
                let host = tab.lastKnownURL.flatMap { URL(string: $0)?.host } ?? "なし"
                AppLog.log("タブ保存: URL未確定のタブあり(直前のURL: \(host))")
            }
            return tab.lastKnownURL ?? BrowserDefaults.homeURL.absoluteString
        }
        UserDefaults.standard.set(urls, forKey: Self.savedURLsKey)
        let index = activeTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
        UserDefaults.standard.set(index, forKey: Self.savedActiveIndexKey)
    }
}
