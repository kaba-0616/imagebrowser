import SwiftUI

struct BookmarksView: View {
    @ObservedObject var store: BookmarkStore
    let onSelect: (URL) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            Group {
                if store.bookmarks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "star")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("ブックマークはまだありません")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(store.bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark.url)
                                onClose()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(bookmark.url.absoluteString)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                }
            }
            .navigationTitle("ブックマーク")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton().disabled(store.bookmarks.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
