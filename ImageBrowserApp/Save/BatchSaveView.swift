import SwiftUI

/// Saves the videos and audio picked in the list, one after another, with
/// one set of options: videos as MP4 to Photos or Files, audio as MP3/M4A to
/// Files (Photos doesn't take audio). Names are each item's suggested name;
/// HLS takes the best quality. Pro+ only, like a single save. Pushed from
/// the media list, so "戻る" returns to it.
struct BatchSaveView: View {
    let items: [DetectedMedia]
    let controller: WebViewController
    @ObservedObject var store: StoreManager
    let onNeedPlan: () -> Void
    let onClose: () -> Void

    @StateObject private var saver = MediaSaver()

    @State private var destination = SaveDestination.preferred
    @State private var audioFormat = AudioOutputFormat.preferred
    @State private var exportFiles: [URL] = []
    @State private var showExporter = false

    private var videoCount: Int { items.filter { !$0.isAudio }.count }
    private var audioCount: Int { items.count - videoCount }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("選んだ件数")
                    Spacer()
                    Text(summary).foregroundColor(.secondary)
                }
            }

            Section {
                if videoCount > 0 {
                    Picker("動画の保存先", selection: $destination) {
                        ForEach(SaveDestination.allCases) { Text($0.label).tag($0) }
                    }
                }
                if audioCount > 0 {
                    Picker("音声の形式", selection: $audioFormat) {
                        ForEach(AudioOutputFormat.allCases) { Text($0.label).tag($0) }
                    }
                }
            } footer: {
                Text(optionsFooter)
            }
            .disabled(saver.isBusy)

            Section {
                progressRows
                Button(action: save) {
                    HStack {
                        Spacer()
                        Text(saver.isBusy ? "保存中…" : "\(items.count)件を保存する").font(.headline)
                        Spacer()
                    }
                }
                .disabled(saver.isBusy || saver.batch?.done == true)
                if saver.isBusy {
                    Button("中止", role: .destructive) { saver.cancel() }
                }
            } footer: {
                if !store.canSaveMedia {
                    Text("動画・音声の保存はPro+のプランで使えます。")
                } else if !saver.isBusy && saver.batch == nil {
                    Text("1件ずつ順番に保存します。終わるまでアプリを開いたままにしてください。")
                }
            }
        }
        .navigationTitle("まとめて保存")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saver.isBusy)
        .interactiveDismissDisabled(saver.isBusy)
        .onDisappear {
            if !saver.isBusy && !showExporter { saver.cleanUp() }
        }
        // The idle timer would lock the screen partway through a long batch,
        // and a locked phone stops the downloads.
        .onChange(of: saver.isBusy) { busy in
            UIApplication.shared.isIdleTimerDisabled = busy
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: saver.batch?.done) { done in
            guard done == true, let batch = saver.batch else { return }
            // Asked once for the whole batch, not after every item.
            guard !batch.files.isEmpty else {
                if batch.saved > 0 { ReviewPrompt.recordSuccess() }
                return
            }
            let files = batch.files
            exportFiles = files
            showExporter = true
        }
        .sheet(isPresented: $showExporter) {
            FilesExporter(files: exportFiles) { exported in
                AppLog.log("ファイルへの書き出し(まとめて\(exportFiles.count)件): \(exported ? "完了" : "取り消し")")
                showExporter = false
                saver.cleanUp()
                if exported {
                    for file in exportFiles {
                        UsageStats.savedMedia(page: controller.webView.url, format: file.pathExtension.lowercased(),
                                              hls: false, talk: items.first?.source == .talk)
                    }
                    ReviewPrompt.recordSuccess()
                }
            }
        }
    }

    private var summary: String {
        [videoCount > 0 ? "動画\(videoCount)件" : nil, audioCount > 0 ? "音声\(audioCount)件" : nil]
            .compactMap { $0 }.joined(separator: "・")
    }

    private var optionsFooter: String {
        var lines: [String] = []
        if videoCount > 0 { lines.append("動画はMP4で保存します(ストリーミングは最高画質)。") }
        if audioCount > 0 { lines.append("音声は写真アプリに保存できないため、「ファイル」に保存します。") }
        if (videoCount > 0 && destination == .files) || audioCount > 0 {
            lines.append("全部終わってから、保存するフォルダを1回だけ選びます。")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var progressRows: some View {
        if let batch = saver.batch {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(batch.done ? "終わりました" : "\(batch.index + 1)/\(batch.total)件目 \(stepLabel)")
                        .font(.subheadline)
                    Spacer()
                    if case .downloading(let fraction?, _) = saver.state, !batch.done {
                        Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit())
                    }
                }
                ProgressView(value: Double(batch.done ? batch.total : batch.index), total: Double(max(batch.total, 1)))
                Text("保存\(batch.saved)件" + (batch.failed > 0 ? "・失敗\(batch.failed)件" : ""))
                    .font(.caption)
                    .foregroundColor(batch.failed > 0 ? .red : .secondary)
            }
            if batch.done, case .failed(let message) = saver.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.footnote)
            } else if batch.done && batch.files.isEmpty && batch.saved > 0 {
                Label("写真に保存しました", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
    }

    private var stepLabel: String {
        switch saver.state {
        case .downloading(_, let detail): return "ダウンロード中 \(detail)"
        case .converting: return "変換中"
        case .saving: return "写真に保存中"
        default: return ""
        }
    }

    private func save() {
        guard store.canSaveMedia else {
            AppLog.log("まとめて保存: Pro+ではないため購入画面へ")
            onNeedPlan()
            return
        }
        let destination = destination
        let audioFormat = audioFormat.outputFormat
        Task {
            var requests: [MediaSaver.Request] = []
            for media in items {
                let context = await controller.requestContext(for: media.url)
                requests.append(MediaSaver.Request(media: media, name: media.suggestedName,
                                                   format: media.isAudio ? audioFormat : .mp4,
                                                   destination: media.isAudio ? .files : destination,
                                                   quality: nil, context: context))
            }
            saver.startBatch(requests) { request in
                // Files ones are counted once the export sheet writes them.
                guard request.destination == .photos else { return }
                UsageStats.savedMedia(page: controller.webView.url, format: request.format.fileExtension,
                                      hls: request.media.kind == .hls, talk: request.media.source == .talk)
            }
        }
    }
}
