import SwiftUI

struct BrowserView: View {
    @StateObject private var controller = WebViewController()
    @StateObject private var store = StoreManager()
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
                .overlay(alignment: .bottom) {
                    if !store.isPro {
                        AdBannerView(.bottom)
                    }
                }
            toolbar
        }
        .onAppear {
            if controller.urlString.isEmpty {
                controller.load(urlString: BrowserDefaults.homeURL.absoluteString)
            }
        }
        .onChange(of: controller.urlString) { newValue in
            if !addressFieldFocused { addressText = newValue }
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
            Spacer()
            extractButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func toolbarButton(_ systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 32)
        }
        .disabled(disabled)
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
