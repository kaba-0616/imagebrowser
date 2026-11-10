import SwiftUI

/// The videos and audio the open page has used, plus -- on a message app's
/// talk screen -- every video and voice message of that talk.
struct MediaListView: View {
    @ObservedObject var controller: WebViewController
    let onSelect: (DetectedMedia) -> Void
    let onClose: () -> Void

    @State private var talkMedia: [DetectedMedia] = []
    @State private var loadingTalk = false
    @State private var talkError: String?
    @State private var talkFilter = TalkFilter.all

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
                } else {
                    pageSection
                    if controller.canListTalkMedia {
                        talkSection
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("動画・音声")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await controller.rescanPage() }
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
                ForEach(filteredTalkMedia) { media in
                    row(media)
                }
            }
        } header: {
            Text("このトーク")
        } footer: {
            if !talkMedia.isEmpty {
                Text("動画\(talkMedia.filter { !$0.isAudio }.count)件・音声\(talkMedia.filter(\.isAudio).count)件(新しい順)")
            }
        }
    }

    private var filteredTalkMedia: [DetectedMedia] {
        switch talkFilter {
        case .all: return talkMedia
        case .video: return talkMedia.filter { !$0.isAudio }
        case .audio: return talkMedia.filter(\.isAudio)
        }
    }

    private func loadTalk() async {
        loadingTalk = true
        talkError = nil
        let result = await controller.talkMedia()
        talkMedia = result.media
        talkError = result.error ?? (result.media.isEmpty ? "動画・音声のメッセージがありません" : nil)
        loadingTalk = false
    }

    private func row(_ media: DetectedMedia) -> some View {
        Button {
            onSelect(media)
        } label: {
            HStack(spacing: 12) {
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
                Image(systemName: media.canDownload ? "square.and.arrow.down" : "exclamationmark.circle")
                    .foregroundColor(media.canDownload ? .accentColor : .secondary)
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
