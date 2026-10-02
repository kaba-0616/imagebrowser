import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: StoreManager
    let onClose: () -> Void

    @AppStorage(SearchEngineStore.key) private var searchEngineRaw = SearchEngine.google.rawValue
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @State private var showSaveLog = false
    @State private var showPaywall = false
    @State private var adBlockEnabled = AdBlockStore.isEnabled
    @State private var verboseDiagnostics = DiagnosticsStore.isVerbose

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
                    if !store.isPro {
                        Button("Proにアップグレード") { showPaywall = true }
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

                // TestFlight builds only -- never shown on App Store installs.
                if StoreManager.isTestFlight {
                    Section {
                        Toggle("Proを一時的に無効にする", isOn: $store.ignoreProForTesting)
                    } header: {
                        Text("テスト用(TestFlight版のみ)")
                    } footer: {
                        Text("無料ユーザーの動作(広告・リワード広告など)を確認するための設定です。購入は取り消されません。")
                    }
                }

                Section("サポート") {
                    Link("プライバシーポリシー", destination: URL(string: "https://nova-droplet-464.notion.site/ImageBrowser-3e5296d4576e8167ba4ff8b30c4f8b99")!)
                    Link("サポート", destination: URL(string: "https://nova-droplet-464.notion.site/ImageBrowser-3e5296d4576e815cb39acc3d6bc37793")!)
                    Button("保存ログを見る") { showSaveLog = true }
                }

                Section {
                    Toggle("詳細ログを記録", isOn: Binding(
                        get: { verboseDiagnostics },
                        set: {
                            verboseDiagnostics = $0
                            DiagnosticsStore.isVerbose = $0
                        }
                    ))
                } footer: {
                    Text("不具合の調査用です。オンにすると、ページの通信の概要なども保存ログに記録されます。普段はオフのままで問題ありません。")
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
            .sheet(isPresented: $showPaywall) {
                PaywallView(store: store) { showPaywall = false }
            }
            .sheet(isPresented: $showSaveLog) {
                SaveLogView { showSaveLog = false }
            }
        }
        .navigationViewStyle(.stack)
    }
}
