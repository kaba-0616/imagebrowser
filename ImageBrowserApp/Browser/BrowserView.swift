import SwiftUI

struct BrowserView: View {
    @StateObject private var tabManager = TabManager()
    @StateObject private var store = StoreManager()
    @StateObject private var bookmarkStore = BookmarkStore()

    @State private var showTabs = false
    @State private var showSettings = false
    @State private var showBookmarks = false

    var body: some View {
        Group {
            if let tab = tabManager.activeTab {
                BrowserTabContentView(
                    controller: tab.controller,
                    store: store,
                    bookmarkStore: bookmarkStore,
                    tabCount: tabManager.tabs.count,
                    onShowTabs: { showTabs = true },
                    onShowSettings: { showSettings = true },
                    onShowBookmarks: { showBookmarks = true }
                )
                // Forces a fresh view identity per tab so address-bar focus
                // state etc. doesn't leak between tabs on switch.
                .id(tab.id)
            }
        }
        // Closing every tab in the list leaves zero until the list goes
        // away (however it's dismissed); only then does a new one open.
        .sheet(isPresented: $showTabs, onDismiss: { tabManager.ensureTab() }) {
            TabsView(tabManager: tabManager) { showTabs = false }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store) { showSettings = false }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(
                store: bookmarkStore,
                onSelect: { url in tabManager.activeTab?.controller.load(urlString: url.absoluteString) },
                onOpenInNewTab: { url in tabManager.newTab(loading: url.absoluteString) },
                onClose: { showBookmarks = false }
            )
        }
    }
}

private struct BrowserTabContentView: View {
    @ObservedObject var controller: WebViewController
    @ObservedObject var store: StoreManager
    @ObservedObject var bookmarkStore: BookmarkStore
    let tabCount: Int
    let onShowTabs: () -> Void
    let onShowSettings: () -> Void
    let onShowBookmarks: () -> Void

    @StateObject private var longPressSaver = PhotoSaver()

    @State private var addressText = ""
    @FocusState private var addressFieldFocused: Bool

    @State private var isExtracting = false
    @State private var extractedImages: [PageImage] = []
    @State private var showGrid = false
    @State private var showPaywall = false
    @ObservedObject private var adConsent = AdConsent.shared
    @State private var extractionError: String?
    @State private var bookmarkDraft: BookmarkDraft?
    @State private var longPressNotice: String?

    struct BookmarkDraft: Identifiable {
        let id = UUID()
        let title: String
        let url: URL
    }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
                // On a different view than the extraction-error alert below:
                // two .alert modifiers on the same view can't both present.
                .alert("保存できませんでした", isPresented: Binding(
                    get: { longPressNotice != nil },
                    set: { if !$0 { longPressNotice = nil } }
                )) {
                    Button("OK") { longPressNotice = nil }
                } message: {
                    Text(longPressNotice ?? "")
                }
            progressBar
            WebViewRepresentable(webView: controller.webView)
                .overlay(alignment: .topLeading) {
                    if let point = controller.longPressLocation,
                       controller.longPressedImageURL != nil || controller.longPressedSnapshotImage != nil {
                        GeometryReader { proxy in
                            SafariStyleImageMenu(
                                // No "copy link" for the snapshot fallback --
                                // there's no URL to copy, just pixels already
                                // captured (see WebViewController.captureCrop).
                                onSave: {
                                    if let url = controller.longPressedImageURL {
                                        saveSingle(url)
                                    } else if controller.longPressedSnapshotImage != nil {
                                        saveOriginalIfFound(lookup: controller.longPressOriginalLookup, at: point)
                                    }
                                    controller.dismissLongPressMenu()
                                },
                                onCopyLink: copyLinkAction
                            )
                            .position(clampedMenuPosition(around: point, in: proxy.size))
                        }
                        .background(
                            Color.black.opacity(0.001)
                                .onTapGesture { controller.dismissLongPressMenu() }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .center)))
                        .animation(.easeOut(duration: 0.15), value: controller.longPressedImageURL)
                    }
                }
            // A fixed-height bar below the content, not an overlay on top of
            // it -- an overlay would sit over the bottom of every page,
            // covering whatever the site placed there.
            if !store.isPro && adConsent.isReady {
                AdBannerView(.bottom)
                    .frame(height: 50)
            }
            toolbar
        }
        .onChange(of: controller.urlString) { newValue in
            if !addressFieldFocused { addressText = newValue }
        }
        .onAppear {
            addressText = controller.urlString
        }
        .task { await adConsent.start() }
        // Full-screen cover, not a sheet: a sheet can be swiped down to
        // close, and that drag fought with the full-screen viewer's own
        // swipe-down-to-grid (user request: no swipe-to-close at all; the
        // grid's 閉じる button is the way out).
        .fullScreenCover(isPresented: $showGrid) {
            ImageGridView(
                images: extractedImages,
                pageTitle: controller.pageTitle,
                pageURL: URL(string: controller.urlString),
                store: store,
                loadHistory: controller.canLoadHistory ? { await controller.historyImages() } : nil
            ) {
                showGrid = false
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                store: store,
                onClose: { showPaywall = false },
                onWatchAd: adConsent.isReady ? { await watchAdForOneExtraction() } : nil
            )
        }
        .sheet(item: $bookmarkDraft) { draft in
            BookmarkNameSheet(
                heading: "ブックマークを追加",
                initialTitle: draft.title,
                url: draft.url,
                onSave: { bookmarkStore.add(title: $0, url: draft.url) },
                onClose: { bookmarkDraft = nil }
            )
        }
        .alert("抽出に失敗しました", isPresented: Binding(
            get: { extractionError != nil },
            set: { if !$0 { extractionError = nil } }
        )) {
            Button("OK") { extractionError = nil }
        } message: {
            Text(extractionError ?? "")
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("URLまたは検索ワード", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.webSearch)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .focused($addressFieldFocused)
                .onSubmit {
                    controller.load(urlString: addressText)
                    addressFieldFocused = false
                }
            // Next to the URL like Safari (user request), not in the toolbar.
            Button {
                controller.reloadOrStop()
            } label: {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 17))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(controller.isLoading ? "読み込みを中止" : "再読み込み")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var progressBar: some View {
        if controller.isLoading {
            ProgressView(value: controller.estimatedProgress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
    }

    /// Every item gets equal width instead of clustering at the ends with
    /// two Spacers between three groups -- that left uneven gaps (four
    /// icons bunched left, one centered, two bunched right).
    private var toolbar: some View {
        HStack(spacing: 0) {
            toolbarButton("chevron.left", disabled: !controller.canGoBack) { controller.goBack() }
                .frame(maxWidth: .infinity)
            toolbarButton("chevron.right", disabled: !controller.canGoForward) { controller.goForward() }
                .frame(maxWidth: .infinity)
            bookmarkButton
                .frame(maxWidth: .infinity)
            extractButton
                .frame(maxWidth: .infinity)
            tabsButton
                .frame(maxWidth: .infinity)
            toolbarButton("gearshape") { onShowSettings() }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// A menu rather than a bare toggle: "add/remove this page" and "open
    /// the full list" are both things a tap here should reach, and a menu
    /// makes both discoverable instead of hiding the list behind a
    /// long-press nobody would find on their own.
    private var bookmarkButton: some View {
        Menu {
            Button {
                guard let url = controller.webView.url else { return }
                if currentPageIsBookmarked {
                    bookmarkStore.toggle(title: controller.pageTitle, url: url)
                } else {
                    // Name it before saving -- page titles are often long or
                    // generic ("Home", site-wide suffixes...).
                    bookmarkDraft = BookmarkDraft(title: controller.pageTitle, url: url)
                }
            } label: {
                Label(
                    currentPageIsBookmarked ? "ブックマークを解除" : "このページをブックマーク",
                    systemImage: currentPageIsBookmarked ? "star.slash" : "star"
                )
            }
            Button {
                onShowBookmarks()
            } label: {
                Label("ブックマーク一覧を見る", systemImage: "list.bullet")
            }
        } label: {
            Image(systemName: currentPageIsBookmarked ? "star.fill" : "star")
                .frame(width: 44, height: 32)
        }
        .disabled(controller.webView.url == nil)
    }

    private var currentPageIsBookmarked: Bool {
        guard let url = controller.webView.url else { return false }
        return bookmarkStore.isBookmarked(url)
    }

    private func toolbarButton(_ systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 32)
        }
        .disabled(disabled)
    }

    private var tabsButton: some View {
        Button(action: onShowTabs) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "square.on.square")
                    .frame(width: 44, height: 32)
                Text("\(tabCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Circle().fill(Color.accentColor))
                    .offset(x: -6, y: 2)
            }
        }
    }

    private var extractButton: some View {
        Button {
            handleExtractTap()
        } label: {
            if isExtracting {
                ProgressView()
                    .frame(width: 44, height: 32)
            } else {
                Image(systemName: "photo.stack")
                    .frame(width: 44, height: 32)
            }
        }
        .disabled(isExtracting)
    }

    private func handleExtractTap() {
        guard store.isPro else {
            showPaywall = true
            return
        }
        Task { await extractImages() }
    }

    /// Free users: one rewarded ad buys exactly one extraction run. Nothing
    /// is stored -- the next extraction asks again.
    private func watchAdForOneExtraction() async -> RewardedAdManager.Outcome {
        let outcome = await RewardedAdManager.shared.show()
        AppLog.log("リワード広告の結果: \(outcome)")
        guard outcome == .earned else { return outcome }
        showPaywall = false
        // The grid is another sheet; it can't open until the paywall's
        // dismiss animation has finished.
        try? await Task.sleep(nanoseconds: 700_000_000)
        await extractImages()
        return outcome
    }

    private func extractImages() async {
        isExtracting = true
        defer { isExtracting = false }
        AppLog.log("一括抽出開始: \(controller.urlString)")
        do {
            extractedImages = try await controller.extractImages(withBackgrounds: true)
            AppLog.log("一括抽出結果: \(extractedImages.count)件")
            showGrid = true
        } catch {
            AppLog.log("一括抽出失敗: \(error.localizedDescription)", isError: true)
            extractionError = "ページから画像を読み取れませんでした。"
        }
    }

    private var copyLinkAction: (() -> Void)? {
        guard let url = controller.longPressedImageURL else { return nil }
        return {
            UIPasteboard.general.string = url.absoluteString
            controller.dismissLongPressMenu()
        }
    }

    /// Canvas-page long press: saves the original file when the pixel match
    /// found one (see WebViewController.findOriginal). A screen crop is
    /// never saved -- the user only wants originals, so when none is found
    /// it says so instead.
    private func saveOriginalIfFound(lookup: Task<WebViewController.LongPressLookup, Never>?, at point: CGPoint) {
        Task {
            let first = await lookup?.value
            var found = first?.original
            var nearEdge = first?.nearScreenEdge ?? false
            if found == nil {
                let retry = await controller.retryOriginalLookup(at: point)
                found = retry.original
                nearEdge = nearEdge || retry.nearScreenEdge
            }
            guard let original = found else {
                AppLog.log("長押し: 原寸画像を特定できなかったため保存せず\(nearEdge ? "(写真が画面の端にかかっている)" : "")")
                longPressNotice = nearEdge
                    ? "写真の一部が画面の外にあります。写真全体が見えるようにスクロールしてから長押ししてください。"
                    : "この写真の元の画像を特定できなかったため、保存しませんでした。"
                return
            }
            AppLog.log("長押し: 照合で見つかった原寸画像を保存 \(WebViewController.shortPath(original.url))")
            await longPressSaver.save([original])
            if case .finished(let succeeded, _, let message) = longPressSaver.state, succeeded == 0 {
                longPressNotice = "保存に失敗しました。\(message ?? "")"
            }
        }
    }

    private func saveSingle(_ url: URL) {
        let image = PageImage(id: 0, url: url, width: 0, height: 0, renderedURL: nil, origin: "dom")
        Task { await longPressSaver.save([image]) }
    }

    /// Prefers appearing above the touch point (matching Safari), flipping
    /// below when there isn't room, and clamped so the card never runs off
    /// either edge of the WebView.
    private func clampedMenuPosition(around point: CGPoint, in containerSize: CGSize) -> CGPoint {
        let menuWidth: CGFloat = SafariStyleImageMenu.width
        let menuHeight: CGFloat = SafariStyleImageMenu.estimatedHeight
        let margin: CGFloat = 12

        let x = min(max(point.x, menuWidth / 2 + margin), containerSize.width - menuWidth / 2 - margin)

        let aboveY = point.y - menuHeight / 2 - 24
        let y: CGFloat
        if aboveY - menuHeight / 2 >= margin {
            y = aboveY
        } else {
            y = min(point.y + menuHeight / 2 + 24, containerSize.height - menuHeight / 2 - margin)
        }
        return CGPoint(x: x, y: y)
    }
}

/// A floating card styled like Safari's own long-press image menu (frosted
/// background, icon + label rows, no explicit cancel -- tapping outside
/// dismisses it) rather than a generic bottom action sheet.
private struct SafariStyleImageMenu: View {
    static let width: CGFloat = 250
    static let estimatedHeight: CGFloat = 96

    let onSave: () -> Void
    // nil for the canvas-snapshot fallback (WebViewController.captureCrop) --
    // there's no URL behind those pixels to copy.
    let onCopyLink: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            row(icon: "square.and.arrow.down", title: "\"写真\"に保存", action: onSave)
            if let onCopyLink {
                Divider()
                row(icon: "doc.on.doc", title: "リンクをコピー", action: onCopyLink)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func row(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: icon)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
