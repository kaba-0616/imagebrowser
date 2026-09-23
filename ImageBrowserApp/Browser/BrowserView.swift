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
        .sheet(isPresented: $showTabs) {
            TabsView(tabManager: tabManager) { showTabs = false }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store) { showSettings = false }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(
                store: bookmarkStore,
                onSelect: { url in tabManager.activeTab?.controller.load(urlString: url.absoluteString) },
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
    @State private var extractionError: String?

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            progressBar
            WebViewRepresentable(webView: controller.webView)
            // A fixed-height bar below the content, not an overlay on top of
            // it -- an overlay would sit over the bottom of every page,
            // covering whatever the site placed there.
            if !store.isPro {
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
        .sheet(isPresented: $showGrid) {
            ImageGridView(images: extractedImages, pageTitle: controller.pageTitle) {
                showGrid = false
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: store) { showPaywall = false }
        }
        .confirmationDialog(
            "この画像を保存しますか?",
            isPresented: Binding(
                get: { controller.longPressedImageURL != nil },
                set: { if !$0 { controller.longPressedImageURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("保存する") {
                if let url = controller.longPressedImageURL {
                    saveSingle(url)
                }
                controller.longPressedImageURL = nil
            }
            Button("キャンセル", role: .cancel) {
                controller.longPressedImageURL = nil
            }
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

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolbarButton("chevron.left", disabled: !controller.canGoBack) { controller.goBack() }
            toolbarButton("chevron.right", disabled: !controller.canGoForward) { controller.goForward() }
            toolbarButton(controller.isLoading ? "xmark" : "arrow.clockwise") { controller.reloadOrStop() }
            bookmarkButton
            Spacer()
            extractButton
            Spacer()
            tabsButton
            toolbarButton("gearshape") { onShowSettings() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Tap toggles the current page; long-press opens the full list -- kept
    /// on one button rather than two, since "show bookmarks" is a much
    /// rarer action than "bookmark this page".
    private var bookmarkButton: some View {
        Button {
            guard let url = controller.webView.url else { return }
            bookmarkStore.toggle(title: controller.pageTitle, url: url)
        } label: {
            Image(systemName: currentPageIsBookmarked ? "star.fill" : "star")
                .frame(width: 44, height: 32)
        }
        .disabled(controller.webView.url == nil)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in onShowBookmarks() }
        )
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
            } else {
                Label("画像を抽出", systemImage: "photo.stack")
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

    private func extractImages() async {
        isExtracting = true
        defer { isExtracting = false }
        do {
            extractedImages = try await controller.extractImages(withBackgrounds: true)
            showGrid = true
        } catch {
            extractionError = "ページから画像を読み取れませんでした。"
        }
    }

    private func saveSingle(_ url: URL) {
        let image = PageImage(id: 0, url: url, width: 0, height: 0, renderedURL: nil, origin: "dom")
        Task { await longPressSaver.save([image]) }
    }
}
