import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: StoreManager
    let onClose: () -> Void

    @AppStorage(SearchEngineStore.key) private var searchEngineRaw = SearchEngine.google.rawValue
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @State private var showSaveLog = false
    @State private var adBlockEnabled = AdBlockStore.isEnabled

    var body: some View {
        NavigationView {
            Form {
                Section("検索エンジン") {
                    Picker("デフォルト検索エンジン", selection: $searchEngineRaw) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine.rawValue)
                        }
                    }
                }

                Section("広告ブロック") {
                    Toggle("ページ内の広告をブロック", isOn: Binding(
                        get: { adBlockEnabled },
                        set: {
                            adBlockEnabled = $0
                            AdBlockStore.isEnabled = $0
                        }
                    ))
                }

                Section("Pro") {
                    HStack {
                        Text("現在のプラン")
                        Spacer()
                        Text(store.isPro ? "Pro" : "無料")
                            .foregroundColor(.secondary)
                    }
                    Button {
                        Task {
                            isRestoring = true
                            await store.restorePurchases()
                            isRestoring = false
                            restoreMessage = store.isPro ? "Proが復元されました" : "復元できる購入が見つかりませんでした"
                        }
                    } label: {
                        if isRestoring {
                            ProgressView()
                        } else {
                            Text("購入を復元")
                        }
                    }
                    .disabled(isRestoring)
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("サポート") {
                    Link("プライバシーポリシー", destination: URL(string: "https://nova-droplet-464.notion.site/ImageBrowser-3e5296d4576e8167ba4ff8b30c4f8b99")!)
                    Link("サポート", destination: URL(string: "https://nova-droplet-464.notion.site/ImageBrowser-3e5296d4576e815cb39acc3d6bc37793")!)
                    Button("保存ログを見る") { showSaveLog = true }
                }

                Section {
                    HStack {
                        Text("バージョン")
                        Spacer()
                        Text(AppVersion.displayShort)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
            }
            .sheet(isPresented: $showSaveLog) {
                SaveLogView { showSaveLog = false }
            }
        }
        .navigationViewStyle(.stack)
    }
}
