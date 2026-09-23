import SwiftUI

/// Reads AppLog directly -- it is the one shared record across page loads,
/// long-press hit-tests, bulk extraction and both PhotoSaver instances (one
/// per long-press save, one inside ImageGridView), which is what "保存が
/// 出てこない" troubleshooting needs: not just what the save did, but
/// whether the page even loaded and whether extraction found anything.
struct SaveLogView: View {
    let onClose: () -> Void

    @State private var lines: [String] = AppLog.read().reversed()
    @State private var confirmingClear = false

    var body: some View {
        NavigationView {
            Group {
                if lines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("まだ記録がありません")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(line.contains("[ERR]") ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                }
            }
            .navigationTitle("ログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        lines = AppLog.read().reversed()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
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
                    AppLog.clear()
                    lines = []
                }
                Button("キャンセル", role: .cancel) {}
            }
            .refreshable {
                lines = AppLog.read().reversed()
            }
        }
        .navigationViewStyle(.stack)
    }
}
