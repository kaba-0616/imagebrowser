import Foundation
import Combine

/// A single browser tab: an identity plus its own WKWebView-owning controller.
/// Each tab keeps its own navigation history and page state independently.
@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    let controller = WebViewController()
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

    @discardableResult
    func newTab() -> BrowserTab {
        let tab = makeTab(loading: BrowserDefaults.homeURL.absoluteString)
        tabs.append(tab)
        activeTabID = tab.id
        saveState()
        return tab
    }

    /// Closing the last tab opens a fresh one rather than leaving the
    /// browser with nothing to show.
    func closeTab(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        urlObservers[id] = nil
        if tabs.isEmpty {
            newTab()
        } else {
            if activeTabID == id {
                activeTabID = tabs[min(index, tabs.count - 1)].id
            }
            saveState()
        }
    }

    func selectTab(_ id: BrowserTab.ID) {
        activeTabID = id
        saveState()
    }

    private func makeTab(loading urlString: String) -> BrowserTab {
        let tab = BrowserTab()
        tab.controller.load(urlString: urlString)
        // Any subsequent navigation inside this tab (following a link,
        // typing a new address) should update what gets restored next
        // launch too, not just the URL it started on.
        urlObservers[tab.id] = tab.controller.$urlString
            .dropFirst()
            .sink { [weak self] _ in self?.saveState() }
        return tab
    }

    private func restoreOrCreateInitialTabs() {
        let savedURLs = UserDefaults.standard.stringArray(forKey: Self.savedURLsKey) ?? []
        guard !savedURLs.isEmpty else {
            newTab()
            return
        }

        let restored = savedURLs.map { makeTab(loading: $0) }
        tabs = restored
        let savedIndex = UserDefaults.standard.integer(forKey: Self.savedActiveIndexKey)
        activeTabID = restored.indices.contains(savedIndex) ? restored[savedIndex].id : restored.first?.id
    }

    private func saveState() {
        let urls = tabs.map { $0.controller.urlString.isEmpty
            ? BrowserDefaults.homeURL.absoluteString
            : $0.controller.urlString
        }
        UserDefaults.standard.set(urls, forKey: Self.savedURLsKey)
        let index = activeTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
        UserDefaults.standard.set(index, forKey: Self.savedActiveIndexKey)
    }
}
