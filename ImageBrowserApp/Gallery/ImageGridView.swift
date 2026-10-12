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

    private var visibleImages: [PageImage] {
        sourceImages.filter { !photoSaver.savedImageIDs.contains($0.id) }
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
                    Button(action: openReportForm) {
                        Image(systemName: "exclamationmark.bubble")
                    }
                    .accessibilityLabel("このサイトを報告")
                }
            }
        }
        .navigationViewStyle(.stack)
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
            case .ended, .cancelled, .failed:
                onEnded?()
            default:
                break
            }
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
