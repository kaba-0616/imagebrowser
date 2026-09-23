import SwiftUI

struct TabsView: View {
    @ObservedObject var tabManager: TabManager
    let onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(tabManager.tabs) { tab in
                        TabCell(
                            controller: tab.controller,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: {
                                tabManager.selectTab(tab.id)
                                onClose()
                            },
                            onClose: { tabManager.closeTab(tab.id) }
                        )
                    }
                }
                .padding(12)
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
/// cell when the controller's pageTitle/urlString change underneath it.
private struct TabCell: View {
    @ObservedObject var controller: WebViewController
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(controller.pageTitle.isEmpty ? "新しいタブ" : controller.pageTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)

            // onSelect lives on this group only, not on the whole cell --
            // the close button sits in the row above, and a tap gesture on
            // the full cell would overlap it and win over the Button's own
            // tap, so the X silently reopened the tab instead of closing it.
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let thumbnail = controller.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(Color(.secondarySystemBackground))
                        Image(systemName: "safari")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: 100)
                .clipped()

                Text(controller.urlString)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
                    .padding(8)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? Color.accentColor : Color(.separator), lineWidth: isActive ? 2 : 1)
        )
    }
}
