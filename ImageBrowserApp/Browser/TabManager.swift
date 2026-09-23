import Foundation

/// A single browser tab: an identity plus its own WKWebView-owning controller.
/// Each tab keeps its own navigation history and page state independently.
@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    let controller = WebViewController()
}

/// Simple tab set: open/close/switch only, no thumbnails or tab-group UI.
@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var activeTabID: BrowserTab.ID?

    var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    init() {
        newTab()
    }

    @discardableResult
    func newTab() -> BrowserTab {
        let tab = BrowserTab()
        tabs.append(tab)
        activeTabID = tab.id
        tab.controller.load(urlString: BrowserDefaults.homeURL.absoluteString)
        return tab
    }

    /// Closing the last tab opens a fresh one rather than leaving the
    /// browser with nothing to show.
    func closeTab(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab()
        } else if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func selectTab(_ id: BrowserTab.ID) {
        activeTabID = id
    }
}
