import SwiftUI

/// The videos and audio the open page has used, plus -- on a message app's
/// talk screen -- the talk's video and voice messages. Saving one (or a
/// batch) pushes its screen onto this list's navigation, so "戻る" comes back
/// to the list as it was (user request, 2026-11-11).
struct MediaListView: View {
    @ObservedObject var controller: WebViewController
    @ObservedObject var store: StoreManager
    /// Saving needs Pro+: the caller closes the list and shows the paywall.
    let onNeedPlan: () -> Void
    let onClose: () -> Void

    @State private var talkMedia: [DetectedMedia] = []
    /// IDs of the talk media in the stretch the user scrolled through.
    @State private var talkScrolled: Set<String> = []
    /// Off: only the scrolled stretch, like the image extraction (user
    /// request, 2026-11-11). On: the whole talk.
    @State private var showWholeTalk = false
    @State private var pushedMedia: DetectedMedia?
    @State private var pushedBatch: [DetectedMedia]?
    @State private var loadingTalk = false
    @State private var talkError: String?
    @State private var talkFilter = TalkFilter.all
    @State private var selecting = false
    @State private var selected: Set<String> = []

    enum TalkFilter: String, CaseIterable, Identifiable {
        case all, video, audio
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "すべて"
            case .video: return "動画"
            case .audio: return "音声"
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                if controller.isRestrictedSite {
                    Section {
                        Label("このサイトの動画・音声は保存できません。", systemImage: "nosign")
                            .foregroundColor(.secondary)
                    } footer: {
                        Text("著作権保護(DRM)がかかった配信サービスの映像・音楽は保存できません。")
                    }
                } else if controller.canListTalkMedia {
                    // A talk draws on a canvas and plays nothing until tapped,
                    // so scrolling it finds no videos; the talk's own data has
                    // them all. Listed first and loaded right away -- the
                    // button under an empty "このページ" went unnoticed
                    // (2026-11-11, user: "スクロールしても増えない").
                    talkSection
                    if !controller.detectedMedia.isEmpty { pageSection }
                } else {
                    pageSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("動画・音声")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !selectable.isEmpty || selecting {
                        Button(selecting ? "キャンセル" : "選択") {
                            selecting.toggle()
                            selected = []
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            .background(navigationLinks)
        }
        .navigationViewStyle(.stack)
        .task {
            await controller.rescanPage()
            if controller.canListTalkMedia && talkMedia.isEmpty && !loadingTalk { await loadTalk() }
        }
    }

    @ViewBuilder
    private var pageSection: some View {
        Section {
            if controller.detectedMedia.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("このページではまだ見つかっていません")
                        .font(.subheadline.weight(.semibold))
                    Text("ページの動画を一度再生すると見つかることがあります。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(controller.detectedMedia) { media in
                    row(media)
                }
            }
        } header: {
            Text("このページ")
        }
    }

    @ViewBuilder
    private var talkSection: some View {
        Section {
            if loadingTalk {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("トークを読み込んでいます…(メッセージが多いと30秒以上かかります)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if talkMedia.isEmpty {
                Button {
                    Task { await loadTalk() }
                } label: {
                    Label(talkError == nil ? "このトークの動画・音声をすべて表示" : "もう一度読み込む", systemImage: "bubble.left.and.bubble.right")
                }
                if let talkError {
                    Text("読み込めませんでした: \(talkError)")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            } else {
                Picker("種類", selection: $talkFilter) {
                    ForEach(TalkFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if !showWholeTalk && talkScrolled.isEmpty {
                    Text("トークを上へスクロールすると、さかのぼった範囲の動画・音声がここに出ます。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(filteredTalkMedia) { media in
                    row(media)
                }
                Button {
                    showWholeTalk.toggle()
                    selected = []
                    AppLog.log("トークの動画・音声: \(showWholeTalk ? "トーク全体" : "スクロールした範囲")を表示")
                } label: {
                    Label(showWholeTalk ? "スクロールした範囲だけ表示" : "トーク全体を表示(全\(talkMedia.count)件)",
                          systemImage: showWholeTalk ? "arrow.up.and.down.text.horizontal" : "list.bullet")
                }
            }
        } header: {
            Text(showWholeTalk ? "このトーク(全体)" : "このトーク(スクロールした範囲)")
        } footer: {
            if !talkMedia.isEmpty {
                let shown = scopedTalkMedia
                Text("動画\(shown.filter { !$0.isAudio }.count)件・音声\(shown.filter(\.isAudio).count)件(新しい順)")
            }
        }
    }

    private var scopedTalkMedia: [DetectedMedia] {
        showWholeTalk ? talkMedia : talkMedia.filter { talkScrolled.contains($0.id) }
    }

    private var filteredTalkMedia: [DetectedMedia] {
        switch talkFilter {
        case .all: return scopedTalkMedia
        case .video: return scopedTalkMedia.filter { !$0.isAudio }
        case .audio: return scopedTalkMedia.filter(\.isAudio)
        }
    }

    private func loadTalk() async {
        loadingTalk = true
        talkError = nil
        let result = await controller.talkMedia()
        talkMedia = result.media
        talkScrolled = result.scrolled
        talkError = result.error ?? (result.media.isEmpty ? "動画・音声のメッセージがありません" : nil)
        loadingTalk = false
    }

    // MARK: - Saving

    private func open(_ media: DetectedMedia) {
        guard store.canSaveMedia else { onNeedPlan(); return }
        pushedMedia = media
    }

    @ViewBuilder
    private var navigationLinks: some View {
        NavigationLink(isActive: Binding(get: { pushedMedia != nil }, set: { if !$0 { pushedMedia = nil } })) {
            if let media = pushedMedia {
                SaveSheetView(media: media, controller: controller, store: store,
                              onNeedPlan: onNeedPlan, onClose: { pushedMedia = nil })
            }
        } label: { EmptyView() }
        NavigationLink(isActive: Binding(get: { pushedBatch != nil }, set: { if !$0 { pushedBatch = nil } })) {
            if let items = pushedBatch {
                BatchSaveView(items: items, controller: controller, store: store,
                              onNeedPlan: onNeedPlan, onClose: { pushedBatch = nil })
            }
        } label: { EmptyView() }
    }

    /// Everything on screen that can be saved, in list order: this page's,
    /// then the talk's under the current filter.
    private var selectable: [DetectedMedia] {
        guard !controller.isRestrictedSite else { return [] }
        var seen: Set<String> = []
        return (controller.detectedMedia + (controller.canListTalkMedia ? filteredTalkMedia : []))
            .filter { $0.canDownload && seen.insert($0.id).inserted }
    }

    private var selectionBar: some View {
        let all = selectable
        let picked = all.filter { selected.contains($0.id) }
        let allPicked = !all.isEmpty && picked.count == all.count
        return HStack {
            Button(allPicked ? "すべて解除" : "すべて選択") {
                selected = allPicked ? [] : Set(all.map(\.id))
            }
            Spacer()
            Button {
                AppLog.log("まとめて保存: \(picked.count)件を選択")
                guard store.canSaveMedia else { onNeedPlan(); return }
                pushedBatch = picked
            } label: {
                Text(picked.isEmpty ? "保存" : "\(picked.count)件を保存").bold()
            }
            .disabled(picked.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func row(_ media: DetectedMedia) -> some View {
        Button {
            if selecting {
                if selected.contains(media.id) { selected.remove(media.id) } else { selected.insert(media.id) }
            } else {
                open(media)
            }
        } label: {
            HStack(spacing: 12) {
                if selecting {
                    Image(systemName: selected.contains(media.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(selected.contains(media.id) ? .accentColor : .secondary)
                }
                PosterView(url: media.posterURL, isAudio: media.isAudio)
                    .frame(width: 64, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.source == .talk ? Self.talkDate(media.publishedAt) : (media.title.isEmpty ? media.url.lastPathComponent : media.title))
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Text(media.typeLabel)
                        if let duration = media.duration { Text(Self.time(duration)) }
                        if media.source == .page { Text(media.url.host ?? "").lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                if !selecting {
                    Image(systemName: media.canDownload ? "square.and.arrow.down" : "exclamationmark.circle")
                        .foregroundColor(media.canDownload ? .accentColor : .secondary)
                }
            }
        }
        .disabled(!media.canDownload)
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func talkDate(_ iso: String?) -> String {
        guard let iso, let date = isoFormatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "日時不明" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/M/d(E) H:mm"
        return f.string(from: date)
    }
}

/// The poster frame when the page gave one, else a type icon.
struct PosterView: View {
    let url: URL?
    let isAudio: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(.tertiarySystemFill))
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    icon
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                icon
            }
        }
    }

    private var icon: some View {
        Image(systemName: isAudio ? "waveform" : "film")
            .foregroundColor(.secondary)
    }
}
