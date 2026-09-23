import SwiftUI

struct TabsView: View {
    @ObservedObject var tabManager: TabManager
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(tabManager.tabs) { tab in
                    TabRow(
                        controller: tab.controller,
                        isActive: tab.id == tabManager.activeTabID,
                        onSelect: {
                            tabManager.selectTab(tab.id)
                            onClose()
                        }
                    )
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        tabManager.closeTab(tabManager.tabs[index].id)
                    }
                }
            }
            .navigationTitle("タブ (\(tabManager.tabs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        tabManager.newTab()
                        onClose()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Observes the tab's controller directly -- BrowserTab itself has no
/// @Published properties of its own, so observing it wouldn't refresh this
/// row when the controller's pageTitle/urlString change underneath it.
private struct TabRow: View {
    @ObservedObject var controller: WebViewController
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.pageTitle.isEmpty ? "新しいタブ" : controller.pageTitle)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(controller.urlString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if isActive {
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}
