import SwiftUI

/// Reads PersistentLog directly rather than taking a PhotoSaver instance --
/// there are two independent PhotoSaver instances in the app (one per
/// long-press save, one inside ImageGridView), and PersistentLog is the one
/// place that has whichever of them ran most recently, which is what "保存
/// が出てこない" troubleshooting actually needs.
struct SaveLogView: View {
    let onClose: () -> Void

    @State private var lines: [String] = PersistentLog.read()
    @State private var confirmingClear = false

    var body: some View {
        NavigationView {
            Group {
                if lines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("まだ保存の記録がありません")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(line.hasPrefix("[ERR]") ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                }
            }
            .navigationTitle("保存ログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(lines.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(lines.isEmpty)
                }
            }
            .confirmationDialog("ログを消去しますか?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("消去する", role: .destructive) {
                    PersistentLog.clear()
                    lines = []
                }
                Button("キャンセル", role: .cancel) {}
            }
            .refreshable {
                lines = PersistentLog.read()
            }
        }
        .navigationViewStyle(.stack)
    }
}
