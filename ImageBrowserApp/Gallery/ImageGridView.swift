import SwiftUI

enum DisplayMode: String, CaseIterable {
    case grid = "グリッド"
    case fullscreen = "フルスクリーン"
}

/// Bulk-extraction result screen: sourceOnly/meta/background-only images are
/// mixed in without ImageSaver's site-specific exclusion heuristics --
/// those were tuned against a handful of known sites and don't belong in a
/// general-purpose browser's MVP.
struct ImageGridView: View {
    let images: [PageImage]
    let pageTitle: String
    let onClose: () -> Void

    @StateObject private var loader = ImageLoader()
    @StateObject private var photoSaver = PhotoSaver()

    @State private var selected: Set<Int> = []
    @State private var displayMode: DisplayMode = .grid
    @State private var fullscreenIndex: Int = 0
    @State private var showSaveLog = false

    private var visibleImages: [PageImage] {
        images.filter { !photoSaver.savedImageIDs.contains($0.id) }
    }

    private var selectedVisible: [PageImage] {
        visibleImages.filter { selected.contains($0.id) }
    }

    private var allVisibleSelected: Bool {
        !visibleImages.isEmpty && visibleImages.allSatisfy { selected.contains($0.id) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 3)

    var body: some View {
        mainContent
            .overlay(savingOverlay)
            .animation(.easeInOut(duration: 0.15), value: photoSaver.isSaving)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showSaveLog) {
                SaveLogView { showSaveLog = false }
            }
    }

    @ViewBuilder
    private var savingOverlay: some View {
        if case .saving(let done, let total) = photoSaver.state {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.4).tint(.white)
                    Text("保存中 \(done)/\(total)")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.16)))
            }
            .contentShape(Rectangle())
            .onTapGesture {}
            .transition(.opacity)
        }
    }

    private var mainContent: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("表示", selection: $displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.black)

                if visibleImages.isEmpty {
                    Spacer()
                    Text(emptyMessage)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else if displayMode == .grid {
                    gridContent
                } else {
                    fullscreenContent
                }

                bottomBar
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(pageTitle.isEmpty ? "抽出結果" : pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var gridContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(Array(visibleImages.enumerated()), id: \.element.id) { index, image in
                        ThumbnailCell(
                            image: image,
                            isSelected: selected.contains(image.id),
                            onTapImage: {
                                fullscreenIndex = index
                                displayMode = .fullscreen
                            },
                            onToggleSelect: { toggleSelection(image.id) }
                        )
                        .environmentObject(loader)
                        .id(image.id)
                    }
                }
            }
            .onAppear {
                guard visibleImages.indices.contains(fullscreenIndex) else { return }
                let targetID = visibleImages[fullscreenIndex].id
                DispatchQueue.main.async {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
        }
        .background(Color.black)
    }

    private var fullscreenContent: some View {
        TabView(selection: $fullscreenIndex) {
            ForEach(Array(visibleImages.enumerated()), id: \.element.id) { index, image in
                FullscreenPreviewView(
                    image: image,
                    isSelected: selected.contains(image.id),
                    onToggleSelect: { toggleSelection(image.id) }
                )
                .environmentObject(loader)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let vertical = value.translation.height
                    let horizontal = value.translation.width
                    guard abs(vertical) > 70, abs(vertical) > abs(horizontal) * 1.5 else { return }
                    withAnimation { displayMode = .grid }
                }
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if case .finished(let succeeded, let failed, let message) = photoSaver.state {
                HStack {
                    Text(message ?? "完了: 成功\(succeeded) 失敗\(failed)")
                        .font(.system(size: 11))
                        .foregroundColor(failed > 0 ? .red : .gray)
                    Spacer()
                    Button("ログ") { showSaveLog = true }
                        .font(.system(size: 11))
                }
            }

            HStack {
                Button(allVisibleSelected ? "選択解除" : "全て選択") {
                    if allVisibleSelected {
                        selected.subtract(visibleImages.map(\.id))
                    } else {
                        selected.formUnion(visibleImages.map(\.id))
                    }
                }
                .disabled(visibleImages.isEmpty)

                Spacer()

                Button {
                    let targets = selectedVisible
                    Task {
                        await photoSaver.save(targets)
                        selected.subtract(photoSaver.savedImageIDs)
                    }
                } label: {
                    Text("保存する (\(selectedVisible.count))").bold()
                }
                .disabled(selectedVisible.isEmpty)
            }
        }
        .padding()
        .background(Color.black)
        .overlay(Divider().opacity(0.3), alignment: .top)
    }

    private var emptyMessage: String {
        if images.isEmpty { return "画像が見つかりませんでした" }
        if images.allSatisfy({ photoSaver.savedImageIDs.contains($0.id) }) { return "すべて保存しました" }
        return "画像が見つかりませんでした"
    }

    private func toggleSelection(_ id: Int) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}

private struct ThumbnailCell: View {
    let image: PageImage
    let isSelected: Bool
    let onTapImage: () -> Void
    let onToggleSelect: () -> Void

    @EnvironmentObject private var loader: ImageLoader

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(thumbnail)
            .overlay(badge, alignment: .bottomLeading)
            .overlay(selectionButton, alignment: .topTrailing)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onTapImage() }
            .onAppear {
                loader.markOnScreen(image.id, true)
                loader.requestThumbnail(for: image)
            }
            .onDisappear { loader.markOnScreen(image.id, false) }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.12))
            if let thumbnail = loader.thumbnails[image.id] {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else if loader.failed.contains(image.id) {
                Image(systemName: "exclamationmark.triangle").foregroundColor(.gray)
            } else {
                ProgressView().tint(.gray)
            }
        }
        .clipped()
    }

    private var badge: some View {
        Text(badgeText)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.65))
            .foregroundColor(.white)
            .cornerRadius(3)
            .padding(3)
    }

    private var selectionButton: some View {
        Button(action: onToggleSelect) {
            ZStack {
                Circle().fill(isSelected ? Color.accentColor : Color.black.opacity(0.55))
                    .frame(width: 24, height: 24)
                Circle().strokeBorder(Color.white, lineWidth: 1.5).frame(width: 24, height: 24)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(6)
        }
        .buttonStyle(.plain)
    }

    private var badgeText: String {
        if let size = loader.trueSize(of: image) {
            return "\(image.formatLabel) \(Int(size.width))×\(Int(size.height))"
        }
        if image.renderedURL != nil {
            return "\(image.formatLabel) 原寸"
        }
        if image.width > 0, image.height > 0 {
            return "\(image.formatLabel) \(image.width)×\(image.height)"
        }
        return image.formatLabel
    }
}
