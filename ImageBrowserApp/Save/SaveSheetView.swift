import SwiftUI

/// Name, format, quality and destination for one video/audio, then the
/// download's progress. Saving is Pro+ only (user decision, 2026-11-10);
/// anyone else is sent to the Pro+ paywall on the save button.
struct SaveSheetView: View {
    let media: DetectedMedia
    let controller: WebViewController
    @ObservedObject var store: StoreManager
    let onNeedPlan: () -> Void
    let onClose: () -> Void

    @StateObject private var saver = MediaSaver()

    @State private var name = ""
    @State private var format = OutputFormat.mp4
    @State private var destination = SaveDestination.preferred
    @State private var qualities: [HLSDownloader.Quality] = []
    @State private var quality: Int?
    @State private var loadingQualities = false
    @State private var exportFile: URL?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 12) {
                        PosterView(url: media.posterURL, isAudio: media.isAudio)
                            .frame(width: 96, height: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(media.typeLabel).font(.subheadline.weight(.semibold))
                            if let duration = media.duration {
                                Text(MediaListView.time(duration)).font(.caption).foregroundColor(.secondary)
                            }
                            Text(media.url.host ?? "").font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }

                Section("ファイル名") {
                    HStack {
                        TextField("ファイル名", text: $name)
                            .focused($nameFocused)
                            .disableAutocorrection(true)
                            .submitLabel(.done)
                        Text("." + format.fileExtension)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Picker("形式", selection: $format) {
                        ForEach(availableFormats) { Text($0.label).tag($0) }
                    }
                    if media.kind == .hls && format == .mp4 {
                        if loadingQualities {
                            HStack { Text("画質"); Spacer(); ProgressView() }
                        } else if qualities.count > 1 {
                            Picker("画質", selection: $quality) {
                                ForEach(qualities) { Text($0.label).tag(Optional($0.id)) }
                            }
                        }
                    }
                    Picker("保存先", selection: $destination) {
                        ForEach(SaveDestination.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .disabled(format.isAudioOnly)
                } footer: {
                    if format.isAudioOnly {
                        Text("音声は写真アプリに保存できないため、「ファイル」に保存します。")
                    } else if destination == .files {
                        Text("保存ボタンの後に、保存するフォルダ(iCloud Drive・このiPhone内など)を選びます。")
                    }
                }

                Section {
                    progressRow
                    Button(action: save) {
                        HStack {
                            Spacer()
                            Text(saver.isBusy ? "保存中…" : "保存する").font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(saver.isBusy || FileNaming.sanitized(name, fallback: "").isEmpty)
                    if saver.isBusy {
                        Button("中止", role: .destructive) { saver.cancel() }
                    }
                } footer: {
                    if !store.canSaveMedia {
                        Text("動画・音声の保存はPro+のプランで使えます。")
                    }
                }
            }
            .navigationTitle("保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        if saver.isBusy { saver.cancel() }
                        saver.cleanUp()
                        onClose()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(saver.isBusy)
        .onAppear(perform: setUp)
        .onChange(of: format) { newValue in
            if newValue.isAudioOnly { destination = .files }
        }
        .sheet(item: Binding(get: { exportFile.map(ExportItem.init) }, set: { if $0 == nil { exportFile = nil } })) { item in
            FilesExporter(files: [item.url]) { exported in
                AppLog.log("ファイルへの書き出し: \(exported ? "完了" : "取り消し")")
                exportFile = nil
                saver.cleanUp()
                if exported {
                    recordSuccess()
                    onClose()
                }
            }
        }
    }

    private var availableFormats: [OutputFormat] {
        media.isAudio ? [.mp3, .m4a] : [.mp4, .mp3, .m4a]
    }

    @ViewBuilder
    private var progressRow: some View {
        switch saver.state {
        case .idle:
            EmptyView()
        case .downloading(let fraction, let detail):
            progress("ダウンロード中", fraction: fraction, detail: detail)
        case .converting(let fraction):
            progress(format == .mp3 ? "MP3に変換中" : "変換中", fraction: fraction, detail: nil)
        case .saving:
            progress("写真に保存中", fraction: nil, detail: nil)
        case .finished(let file):
            Label(file == nil ? "写真に保存しました" : "保存先を選んでください", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.footnote)
        }
    }

    private func progress(_ title: String, fraction: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                if let fraction { Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()) }
            }
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let detail {
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func setUp() {
        name = media.suggestedName
        if media.isAudio {
            format = AudioOutputFormat.preferred.outputFormat
            destination = .files
        }
        guard media.kind == .hls else { return }
        loadingQualities = true
        Task {
            let context = await controller.requestContext(for: media.url)
            qualities = (try? await HLSDownloader(context: context).qualities(media.url)) ?? []
            quality = qualities.first?.id
            loadingQualities = false
        }
    }

    private func save() {
        nameFocused = false
        guard store.canSaveMedia else {
            AppLog.log("保存: Pro+ではないため購入画面へ")
            onNeedPlan()
            return
        }
        let chosen = (media: media, name: name, format: format,
                      destination: format.isAudioOnly ? SaveDestination.files : destination, quality: quality)
        Task {
            let context = await controller.requestContext(for: media.url)
            saver.start(MediaSaver.Request(media: chosen.media, name: chosen.name, format: chosen.format,
                                           destination: chosen.destination, quality: chosen.quality,
                                           context: context)) {
                if case .finished(let file?) = saver.state {
                    // Counted once the export sheet actually writes it.
                    exportFile = file
                } else {
                    recordSuccess()
                }
            }
        }
    }

    private func recordSuccess() {
        UsageStats.savedMedia(page: controller.webView.url, format: format.fileExtension,
                              hls: media.kind == .hls, talk: media.source == .talk)
        ReviewPrompt.recordSuccess()
    }

    private struct ExportItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }
}

/// The system "save to Files" sheet for finished files (one folder for all).
struct FilesExporter: UIViewControllerRepresentable {
    let files: [URL]
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: files, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}
