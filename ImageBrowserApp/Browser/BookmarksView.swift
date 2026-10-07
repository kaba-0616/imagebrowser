import SwiftUI

struct BookmarksView: View {
    @ObservedObject var store: BookmarkStore
    let onSelect: (URL) -> Void
    /// Opens the bookmark in a new tab and switches to it.
    let onOpenInNewTab: (URL) -> Void
    let onClose: () -> Void

    @State private var renaming: Bookmark?

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
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.remove(bookmark.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                                Button {
                                    renaming = bookmark
                                } label: {
                                    Label("名前を変更", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    onOpenInNewTab(bookmark.url)
                                    onClose()
                                } label: {
                                    Label("新しいタブで開く", systemImage: "plus.square.on.square")
                                }
                                Button {
                                    renaming = bookmark
                                } label: {
                                    Label("名前を変更", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    store.remove(bookmark.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                        .onMove { store.move(from: $0, to: $1) }
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
                    // 「編集」で並び替え(右端のつまみをドラッグ)と削除ができる。
                    EditButton().disabled(store.bookmarks.isEmpty)
                }
            }
            .sheet(item: $renaming) { bookmark in
                BookmarkNameSheet(
                    heading: "名前を変更",
                    initialTitle: bookmark.title,
                    url: bookmark.url,
                    onSave: { store.rename(bookmark.id, to: $0) },
                    onClose: { renaming = nil }
                )
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Name entry for a bookmark -- used both when adding one from the toolbar
/// and when renaming from the list. A sheet rather than an alert with a
/// text field, which needs iOS 16.
struct BookmarkNameSheet: View {
    let heading: String
    let initialTitle: String
    let url: URL
    let onSave: (String) -> Void
    let onClose: () -> Void

    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("名前", text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text(url.absoluteString)
                        .lineLimit(2)
                }
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存", action: save)
                        .font(.body.bold())
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            title = initialTitle
            // Focusing in the same pass as presentation is ignored.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
        }
    }

    private func save() {
        onSave(title)
        onClose()
    }
}
