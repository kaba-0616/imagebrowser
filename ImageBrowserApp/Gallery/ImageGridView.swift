import SwiftUI

enum DisplayMode: String, CaseIterable {
    case grid = "グリッド"
    case fullscreen = "フルスクリーン"
}

/// Same tiers as ImageSaver's result screen.
enum SizeFilter: Int, CaseIterable, Identifiable {
    case all = 0
    case medium = 1
    case large = 2

    var id: Int { rawValue }

    var minimumPixels: Int {
        switch self {
        case .all: return 0
        case .medium: return 300
        case .large: return 650
        }
    }

    var label: String {
        switch self {
        case .all: return "すべて表示"
        case .medium: return "小を除外 (300px未満)"
        case .large: return "中・小を除外 (650px未満)"
        }
    }
}

/// Bulk-extraction result screen. Filters work like ImageSaver's: images
/// tagged at extraction (PageImage.excluded) or measured as icons/banners
/// are hidden until switched on from the menu.
struct ImageGridView: View {
    let images: [PageImage]
    let pageTitle: String
    let pageURL: URL?
    @ObservedObject var store: StoreManager
    /// "さかのぼり抽出": every photo the page's own data lists, not just what
    /// was scrolled into view. nil where the page offers no such data.
    let loadHistory: (() async -> (images: [PageImage], complete: Bool))?
    let onClose: () -> Void

    @StateObject private var loader = ImageLoader()
    @StateObject private var photoSaver = PhotoSaver()

    @State private var selected: Set<Int> = []
    @State private var displayMode: DisplayMode = .grid
    /// The filter menu, laid out like ImageSaver's (user request): a size
    /// tier remembered between launches, then one switch per kind of image
    /// hidden by default. Each kind is something "the pictures on this page"
    /// doesn't mean -- see PageImage.excluded for where the tags come from.
    /// Every switch is remembered between launches, not only the size tier
    /// (user request: re-setting them on every extraction was a chore).
    @AppStorage("sizeFilter") private var storedSizeFilter = SizeFilter.all.rawValue
    @AppStorage("gridFilter.includeSaved") private var includeSaved = false
    @AppStorage("gridFilter.includeOtherPosts") private var includeOtherPosts = false
    @AppStorage("gridFilter.includeVideoPosters") private var includeVideoPosters = false
    @AppStorage("gridFilter.includeMetaImages") private var includeMetaImages = false
    @AppStorage("gridFilter.includeTutorials") private var includeTutorials = false
    @AppStorage("gridFilter.includeSplash") private var includeSplash = false
    /// Both the tagged UI pictures and anything measured at 200px or less.
    @AppStorage("gridFilter.includeIcons") private var includeIcons = false
    /// Four times longer than deep: a banner, a rule or a header.
    @AppStorage("gridFilter.includeBanners") private var includeBanners = false
    @AppStorage("gridFilter.includeFailed") private var includeFailed = false
    @State private var fullscreenIndex: Int = 0
    @State private var showSaveLog = false
    @State private var historyImages: [PageImage]?
    @State private var historyIncomplete = false
    @State private var isLoadingHistory = false
    @State private var historyMessage: String?
    @State private var showPaywall = false
    @State private var reportFormURL: URL?
    /// Long-press-then-drag selection (like Photos): the cell first touched,
    /// whether the drag selects or deselects, and the selection before it
    /// started -- so dragging back shrinks the range again.
    @State private var dragSelect: (anchor: Int, selecting: Bool, base: Set<Int>)?
    @State private var dragSelectEndedAt: Date?

    /// The history results replace the scrolled-in ones: they're a superset.
    private var sourceImages: [PageImage] { historyImages ?? images }

    private var sizeFilter: SizeFilter {
        SizeFilter(rawValue: storedSizeFilter) ?? .all
    }

    private var visibleImages: [PageImage] {
        sourceImages.filter { image in
            guard includeSaved || !photoSaver.savedImageIDs.contains(image.id) else { return false }
            guard includeOtherPosts || image.excluded != "other" else { return false }
            guard includeVideoPosters || image.excluded != "video" else { return false }
            guard includeMetaImages || image.excluded != "cover" else { return false }
            guard includeTutorials || image.excluded != "tutorial" else { return false }
            guard includeSplash || image.excluded != "splash" else { return false }
            guard includeIcons || !isIcon(image) else { return false }
            guard includeBanners || !isBanner(image) else { return false }
            guard includeFailed || !loader.failed.contains(image.id) else { return false }
            guard sizeFilter != .all else { return true }
            let known = longestSide(of: image)
            return known == 0 || known >= sizeFilter.minimumPixels
        }
    }

    /// Unsaved images of one kind -- the count on its menu switch.
    private func count(_ matches: (PageImage) -> Bool) -> Int {
        sourceImages.filter { matches($0) && !photoSaver.savedImageIDs.contains($0.id) }.count
    }

    private var savedCount: Int { sourceImages.filter { photoSaver.savedImageIDs.contains($0.id) }.count }
    private var otherPostCount: Int { count { $0.excluded == "other" } }
    private var videoPosterCount: Int { count { $0.excluded == "video" } }
    private var metaImageCount: Int { count { $0.excluded == "cover" } }
    private var tutorialCount: Int { count { $0.excluded == "tutorial" } }
    private var splashCount: Int { count { $0.excluded == "splash" } }
    private var iconCount: Int { count(isIcon) }
    private var bannerCount: Int { count(isBanner) }
    private var failedCount: Int { count { loader.failed.contains($0.id) } }

    private var hasHiddenImages: Bool {
        sizeFilter != .all
            || (!includeSaved && savedCount > 0)
            || (!includeOtherPosts && otherPostCount > 0)
            || (!includeVideoPosters && videoPosterCount > 0)
            || (!includeMetaImages && metaImageCount > 0)
            || (!includeTutorials && tutorialCount > 0)
            || (!includeSplash && splashCount > 0)
            || (!includeIcons && iconCount > 0)
            || (!includeBanners && bannerCount > 0)
            || (!includeFailed && failedCount > 0)
    }

    /// The real pixel size from the downloaded file where there is one: many
    /// images come from tags that carry no dimensions (ImageSaver).
    private func longestSide(of image: PageImage) -> Int {
        if let pixels = loader.trueSize(of: image) {
            return Int(max(pixels.width, pixels.height))
        }
        return max(image.width, image.height)
    }

    /// Longest side of 200px or less, by the real size where it is known. An
    /// unmeasured image (0) is never called an icon: it shows, gets measured
    /// when its tile appears, and only then drops out.
    private static let iconMaxSide = 200

    private func isIcon(_ image: PageImage) -> Bool {
        if image.excluded == "icon" { return true }
        let side = longestSide(of: image)
        return side > 0 && side <= Self.iconMaxSide
    }

    /// Read from the thumbnail where there is one: resizing keeps the shape.
    private func isBanner(_ image: PageImage) -> Bool {
        var width = Double(image.width)
        var height = Double(image.height)
        if let measured = loader.pixelSizes[image.id] {
            width = Double(measured.width)
            height = Double(measured.height)
        }
        guard width > 0, height > 0 else { return false }
        return max(width / height, height / width) >= 4
    }

    /// Measures the images the size filter is hiding: a hidden cell never
    /// appears, so it never gets measured otherwise (ImageSaver). Delayed so
    /// it doesn't race the visible grid's own downloads.
    private func scheduleMeasureIfFiltering() {
        guard sizeFilter != .all else { return }
        let visibleIDs = Set(visibleImages.map(\.id))
        let hidden = sourceImages.filter { !visibleIDs.contains($0.id) }
        guard !hidden.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            for image in hidden { loader.requestThumbnail(for: image) }
        }
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
            .sheet(isPresented: Binding(
                get: { reportFormURL != nil },
                set: { if !$0 { reportFormURL = nil } }
            )) {
                if let url = reportFormURL {
                    ContactFormSheet(url: url) {
                        ContactStore.shared.markSubmitted()
                    } onClose: {
                        reportFormURL = nil
                    }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(store: store) { showPaywall = false }
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

    /// Covers the whole result screen while "さかのぼり抽出" walks the talk
    /// (user request) -- a big talk takes 30s or more.
    @ViewBuilder
    private var historyLoadingOverlay: some View {
        if isLoadingHistory {
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea(edges: .bottom)
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.4).tint(.white)
                    Text("さかのぼっています…")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text("メッセージの多いトークでは30秒以上かかります。\nアプリを開いたままお待ちください")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.16)))
                .padding(.horizontal, 32)
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

                // Grid only: in the full-screen viewer it just takes space
                // from the photo (user request).
                if loadHistory != nil, historyImages == nil || historyIncomplete, displayMode == .grid {
                    historyBar
                }

                if visibleImages.isEmpty {
                    Spacer()
                    Text(emptyMessage)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    if sourceImages.isEmpty {
                        Button(action: openReportForm) {
                            Label("このサイトを報告", systemImage: "exclamationmark.bubble")
                        }
                        .padding(.top, 16)
                        Text("うまく画像が出ないサイトを教えてください。今後の改善に使います。")
                            .font(.footnote)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.top, 4)
                    }
                    Spacer()
                } else if displayMode == .grid {
                    gridContent
                } else {
                    fullscreenContent
                }

                bottomBar
            }
            // Inside the NavigationView so "閉じる" stays usable to give up.
            .overlay(historyLoadingOverlay)
            .animation(.easeInOut(duration: 0.15), value: isLoadingHistory)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(pageTitle.isEmpty ? "抽出結果" : pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
                // For results that are there but incomplete (e.g. some
                // photos missing) -- the empty screen has its own button.
                ToolbarItem(placement: .navigationBarTrailing) {
                    filterMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: openReportForm) {
                        Image(systemName: "exclamationmark.bubble")
                    }
                    .accessibilityLabel("このサイトを報告")
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(SizeFilter.allCases) { option in
                Button {
                    storedSizeFilter = option.rawValue
                } label: {
                    if option == sizeFilter {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }

            Divider()

            // Always listed, even at zero: a missing entry would look like
            // the scan never checked for that kind.
            filterToggle("保存済みの画像", count: savedCount, isOn: $includeSaved)
            filterToggle("別の投稿の画像", count: otherPostCount, isOn: $includeOtherPosts)
            filterToggle("動画のサムネイル", count: videoPosterCount, isOn: $includeVideoPosters)
            filterToggle("ページ情報の画像", count: metaImageCount, isOn: $includeMetaImages)
            filterToggle("操作説明の画像", count: tutorialCount, isOn: $includeTutorials)
            filterToggle("起動画面のロゴ", count: splashCount, isOn: $includeSplash)
            filterToggle("横長のバナー画像", count: bannerCount, isOn: $includeBanners)
            filterToggle("小さなアイコン類", count: iconCount, isOn: $includeIcons)
            filterToggle("読み込みに失敗した画像", count: failedCount, isOn: $includeFailed)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(hasHiddenImages ? .body.bold() : .body)
        }
        .accessibilityLabel("表示する画像")
        .onChange(of: storedSizeFilter) { _ in
            fullscreenIndex = 0
            scheduleMeasureIfFiltering()
        }
        .onAppear { scheduleMeasureIfFiltering() }
    }

    @ViewBuilder
    private func filterToggle(_ name: String, count: Int, isOn: Binding<Bool>) -> some View {
        if count > 0 {
            Button {
                isOn.wrappedValue.toggle()
                fullscreenIndex = 0
            } label: {
                if isOn.wrappedValue {
                    Label("\(name)も表示 (\(count)件)", systemImage: "checkmark")
                } else {
                    Text("\(name)も表示 (\(count)件)")
                }
            }
        } else {
            Text("\(name): なし")
        }
    }

    /// Same in-app form as Settings > お問い合わせ, with this page's URL
    /// filled in; the inquiry number then shows up in that screen's list.
    private func openReportForm() {
        ContactStore.shared.prepareInquiry()
        reportFormURL = ContactStore.shared.formURL(pageURL: pageURL)
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
                                // The release of a drag selection lands as a
                                // tap too; it shouldn't open the viewer.
                                if let ended = dragSelectEndedAt, Date().timeIntervalSince(ended) < 0.4 { return }
                                fullscreenIndex = index
                                displayMode = .fullscreen
                            },
                            onToggleSelect: { toggleSelection(image.id) }
                        )
                        .environmentObject(loader)
                        .id(image.id)
                    }
                }
                .background(DragSelectRecognizer(
                    onChanged: updateDragSelect,
                    onEnded: endDragSelect
                ))
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

    /// Hold 0.3s, then slide: every cell from the first one touched to the
    /// one under the finger gets the first cell's new state (user request).
    /// `point` is in the grid's own coordinates, `width` the grid's width.
    private func updateDragSelect(at point: CGPoint, width: CGFloat) {
        guard let index = gridIndex(at: point, width: width) else { return }
        if dragSelect == nil {
            let id = visibleImages[index].id
            dragSelect = (index, !selected.contains(id), selected)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        guard let drag = dragSelect else { return }
        var next = drag.base
        for i in min(drag.anchor, index)...max(drag.anchor, index) {
            let id = visibleImages[i].id
            if drag.selecting { next.insert(id) } else { next.remove(id) }
        }
        if next != selected { selected = next }
    }

    private func endDragSelect() {
        if dragSelect != nil { dragSelectEndedAt = Date() }
        dragSelect = nil
    }

    /// The cell under a point in the grid's own coordinates (3 square
    /// columns, 1pt apart), clamped to the cells that exist.
    private func gridIndex(at point: CGPoint, width: CGFloat) -> Int? {
        guard width > 0, !visibleImages.isEmpty else { return nil }
        let pitch = (width - 2) / 3 + 1
        let column = min(2, max(0, Int(point.x / pitch)))
        let row = max(0, Int(point.y / pitch))
        return min(visibleImages.count - 1, row * 3 + column)
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
                    // Developer-only: TestFlight/simulator builds.
                    if AppVersion.isTestBuild {
                        Button("ログ") { showSaveLog = true }
                            .font(.system(size: 11))
                    }
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
        if sourceImages.isEmpty { return "画像が見つかりませんでした" }
        if sourceImages.allSatisfy({ photoSaver.savedImageIDs.contains($0.id) }) { return "すべて保存しました" }
        // Found plenty, the filters are holding it back: point at the menu.
        if hasHiddenImages { return "表示できる画像がありません\n右上のメニューで隠している画像を表示できます" }
        return "画像が見つかりませんでした"
    }

    private var historyBar: some View {
        VStack(spacing: 4) {
            Button {
                startHistoryLoad()
            } label: {
                HStack(spacing: 6) {
                    if isLoadingHistory {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: store.isPro ? "clock.arrow.circlepath" : "lock.fill")
                    }
                    Text(isLoadingHistory ? "さかのぼっています…" : "さかのぼり抽出")
                        .bold()
                    if !store.isPro {
                        Text("Pro")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16)))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .disabled(isLoadingHistory)
            Text(historyMessage ?? "スクロールしなくても、このページの過去の画像までまとめて探します")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Color.black)
    }

    private func startHistoryLoad() {
        guard store.isPro else {
            showPaywall = true
            return
        }
        guard let loadHistory else { return }
        isLoadingHistory = true
        historyMessage = nil
        Task {
            let result = await loadHistory()
            isLoadingHistory = false
            if result.images.isEmpty {
                historyMessage = result.complete
                    ? "過去の画像は見つかりませんでした"
                    : "読み込みが途中で止まりました。もう一度お試しください"
            } else {
                // A partial walk keeps the button so it can be run again
                // (it walks oldest first, so the newest are what's missing).
                historyImages = result.images
                historyIncomplete = !result.complete
                historyMessage = result.complete ? nil : "通信が途切れたため一部だけ表示しています。電波の良い場所でもう一度お試しください"
                displayMode = .grid
            }
        }
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

/// The long press behind drag selection, as a UIKit recognizer on the grid's
/// own UIScrollView rather than a SwiftUI gesture: a SwiftUI drag gesture on
/// the grid's content swallowed the scroll itself (seen on device, 0.9).
/// A UIKit long press fails as soon as the finger moves before 0.3s, so a
/// normal swipe still scrolls; once it has fired, the scroll view's pan
/// can't start, so sliding selects instead of scrolling.
private struct DragSelectRecognizer: UIViewRepresentable {
    let onChanged: (CGPoint, CGFloat) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.anchor = view
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject {
        var onChanged: ((CGPoint, CGFloat) -> Void)?
        var onEnded: (() -> Void)?
        /// Sits behind the grid with the grid's frame, so locations taken
        /// in it are grid coordinates whatever the scroll position.
        weak var anchor: UIView?
        private weak var scrollView: UIScrollView?
        private var recognizer: UILongPressGestureRecognizer?
        /// Scrolls the grid while the finger rests near its top or bottom
        /// edge, so a selection can run past what's on screen (user request).
        private var autoScrollLink: CADisplayLink?
        private var autoScrollSpeed: CGFloat = 0
        private let edgeZone: CGFloat = 70
        private let maxSpeed: CGFloat = 14

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else { return }
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.minimumPressDuration = 0.3
            scrollView.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
            self.scrollView = scrollView
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let anchor else { return }
            switch recognizer.state {
            case .began, .changed:
                onChanged?(recognizer.location(in: anchor), anchor.bounds.width)
                updateAutoScroll(for: recognizer)
            case .ended, .cancelled, .failed:
                stopAutoScroll()
                onEnded?()
            default:
                break
            }
        }

        /// Speed from how deep the finger is in the top/bottom edge zone of
        /// the visible area: 0 outside it, `maxSpeed` points per frame at
        /// the very edge.
        private func updateAutoScroll(for recognizer: UILongPressGestureRecognizer) {
            guard let scrollView else { return }
            let y = recognizer.location(in: scrollView).y - scrollView.contentOffset.y
            let height = scrollView.bounds.height
            if y < edgeZone {
                autoScrollSpeed = -maxSpeed * min(1, (edgeZone - y) / edgeZone)
            } else if y > height - edgeZone {
                autoScrollSpeed = maxSpeed * min(1, (y - (height - edgeZone)) / edgeZone)
            } else {
                autoScrollSpeed = 0
            }
            if autoScrollSpeed == 0 {
                stopAutoScroll()
            } else if autoScrollLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
                link.add(to: .main, forMode: .common)
                autoScrollLink = link
            }
        }

        @objc private func autoScrollTick() {
            guard let scrollView, let recognizer, let anchor else { stopAutoScroll(); return }
            let inset = scrollView.adjustedContentInset
            let minY = -inset.top
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            let next = min(maxY, max(minY, scrollView.contentOffset.y + autoScrollSpeed))
            guard next != scrollView.contentOffset.y else { return }
            scrollView.contentOffset.y = next
            // The finger hasn't moved but the grid has slid under it.
            onChanged?(recognizer.location(in: anchor), anchor.bounds.width)
        }

        private func stopAutoScroll() {
            autoScrollLink?.invalidate()
            autoScrollLink = nil
            autoScrollSpeed = 0
        }
    }

    /// Finds the enclosing UIScrollView once it's in the hierarchy.
    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let current = view {
                    if let scrollView = current as? UIScrollView {
                        self?.coordinator?.attach(to: scrollView)
                        return
                    }
                    view = current.superview
                }
            }
        }
    }
}
